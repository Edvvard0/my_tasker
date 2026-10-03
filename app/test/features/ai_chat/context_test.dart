import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/ai_env.dart';
import '../../support/manual_clock.dart';

/// Источник «только локально»: данные нельзя отправлять в облако.
class _SensitiveSource extends ContextSource {
  const _SensitiveSource();

  @override
  String get id => 'finance';

  @override
  String get label => 'Финансы';

  @override
  String get description => 'Счета';

  @override
  bool get sensitive => true;

  @override
  List<ContextFilterField> get filters => const [];

  @override
  Map<String, Object?> get defaultFilter => const {};

  @override
  String summary(Map<String, Object?> filter) => 'все счета';

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async => ['- Основной счёт · 100 000 ₽'];
}

DateTime _utc(String iso) => DateTime.parse('${iso}Z');

void main() {
  late AiDevice device;
  late TaskRepository tasks;
  late CalendarRepository calendars;
  late ContextEnv env;
  const builder = ContextBuilder([
    TasksContextSource(),
    EventsContextSource(),
    _SensitiveSource(),
  ]);

  setUp(() async {
    ensureTimeZones();
    // Понедельник, 5 октября 2026, 12:00 по Москве.
    final clock = ManualClock(
      DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch,
    );
    device = await AiDevice.create(aiServer(clock), clock: clock);
    tasks = device.container.read(taskRepositoryProvider);
    calendars = device.container.read(calendarRepositoryProvider);
    await calendars.ensureSystemCalendars();
    env = device.container.read(contextEnvProvider)();
  });
  tearDown(() => device.dispose());

  Future<String> task(
    String title, {
    TaskDue due = const TaskDue.none(),
    int? priority,
    TaskStatus? status,
    String? projectId,
    String? rrule,
    DateTime? archivedAt,
  }) async {
    final id = tasks.newTaskId();
    await tasks.createTask(
      TaskEntity(
        id: id,
        title: title,
        status: status ?? (due.isNone ? TaskStatus.inbox : TaskStatus.todo),
        due: due,
        priority: priority,
        projectId: projectId,
        rrule: rrule,
        recurrenceMode: rrule == null ? null : RecurrenceMode.schedule,
        archivedAt: archivedAt,
      ),
    );
    return id;
  }

  Future<void> seedTasks() async {
    final project = await tasks.createProject('Creora');
    await task(
      'Оплатить домен',
      due: TaskDue.date(DateTime.utc(2026, 10)),
      priority: 1,
    );
    await task(
      'Смета',
      due: TaskDue.date(DateTime.utc(2026, 10, 5)),
      projectId: project,
    );
    await task(
      'Созвон',
      due: TaskDue.at(_utc('2026-10-06T12:00:00'), 'Europe/Moscow'),
      priority: 3,
      status: TaskStatus.inProgress,
    );
    await task('Через неделю', due: TaskDue.date(DateTime.utc(2026, 10, 12)));
    await task('Позже', due: TaskDue.date(DateTime.utc(2026, 10, 20)));
    await task('Идея без срока');
    await task(
      'Сделано',
      due: TaskDue.date(DateTime.utc(2026, 10, 5)),
      status: TaskStatus.done,
    );
    await task(
      'Отменено',
      due: TaskDue.date(DateTime.utc(2026, 10, 5)),
      status: TaskStatus.cancelled,
    );
    await task(
      'В архиве',
      due: TaskDue.date(DateTime.utc(2026, 10, 5)),
      archivedAt: DateTime.utc(2026, 9),
    );
  }

  group('источник «Задачи»', () {
    test(
      'неделя: просроченные и ближайшие 7 дней, по сроку и приоритету',
      () async {
        await seedTasks();
        final lines = await const TasksContextSource().lines(env, {
          'range': 'week',
        });
        expect(lines, [
          '- Оплатить домен · срок 2026-10-01 (просрочено) · P1 · к выполнению',
          '- Смета · срок 2026-10-05 · к выполнению · проект «Creora»',
          '- Созвон · срок 2026-10-06 15:00 · P3 · в работе',
        ]);
      },
    );

    test('месяц, все открытые и без срока', () async {
      await seedTasks();
      const source = TasksContextSource();
      final month = await source.lines(env, {'range': 'month'});
      expect(month.map((l) => l.split(' · ').first), [
        '- Оплатить домен',
        '- Смета',
        '- Созвон',
        '- Через неделю',
        '- Позже',
      ]);
      final open = await source.lines(env, {'range': 'open'});
      expect(open, hasLength(6));
      expect(open.last, startsWith('- Идея без срока'));
      final noDate = await source.lines(env, {'range': 'no_date'});
      expect(noDate, ['- Идея без срока · входящие']);
    });

    test(
      'закрытые, отменённые и архивные не попадают; повтор помечен',
      () async {
        await task(
          'Зарядка',
          due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          rrule: 'FREQ=DAILY',
        );
        await task(
          'Готово',
          due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          status: TaskStatus.done,
        );
        final lines = await const TasksContextSource().lines(env, const {});
        expect(lines, [
          '- Зарядка · срок 2026-10-05 · к выполнению · повторяется',
        ]);
      },
    );

    test('подписи источника', () {
      const s = TasksContextSource();
      expect(s.summary({'range': 'month'}), 'на 30 дней и просроченные');
      expect(s.summary({'range': 'open'}), 'все открытые');
      expect(s.summary({'range': 'no_date'}), 'без срока');
      expect(s.summary(const {}), 'на 7 дней и просроченные');
      expect(s.filters.single.options.keys, [
        'week',
        'month',
        'open',
        'no_date',
      ]);
    });
  });

  group('источник «Расписание»', () {
    Future<void> seedEvents() async {
      final work = systemCalendarId('work');
      Future<void> timed(
        String title,
        String start,
        String end, {
        String? rrule,
        String? location,
      }) => calendars.createEvent(
        EventEntity(
          id: calendars.newEventId(),
          calendarId: work,
          title: title,
          allDay: false,
          startAt: _utc(start),
          endAt: _utc(end),
          tz: 'Europe/Moscow',
          rrule: rrule,
          location: location,
        ),
      );
      await timed(
        'Созвон Creora',
        '2026-10-06T09:00:00',
        '2026-10-06T10:00:00',
        location: 'Zoom',
      );
      await timed(
        'Планёрка',
        '2026-10-05T07:00:00',
        '2026-10-05T07:30:00',
        rrule: 'FREQ=WEEKLY',
      );
      await timed('Далеко', '2026-11-20T09:00:00', '2026-11-20T10:00:00');
      await calendars.createEvent(
        EventEntity(
          id: calendars.newEventId(),
          calendarId: systemCalendarId('personal'),
          title: 'День рождения',
          allDay: true,
          startDate: DateTime.utc(2026, 10, 8),
          endDate: DateTime.utc(2026, 10, 8),
        ),
      );
    }

    test('7 дней с повторениями, весь день и местом', () async {
      await seedEvents();
      final lines = await const EventsContextSource().lines(env, {'days': '7'});
      expect(lines, [
        '- 2026-10-05 10:00–10:30 · Планёрка (Работа)',
        '- 2026-10-06 12:00–13:00 · Созвон Creora (Работа, Zoom)',
        '- 2026-10-08 весь день · День рождения (Личное)',
        // Недельная серия: следующий понедельник уже за пределами 7 дней.
      ]);
    });

    test('«сегодня» и 14 дней: период по фильтру', () async {
      await seedEvents();
      const source = EventsContextSource();
      expect(await source.lines(env, {'days': '1'}), [
        '- 2026-10-05 10:00–10:30 · Планёрка (Работа)',
      ]);
      final fortnight = await source.lines(env, {'days': '14'});
      expect(fortnight.where((l) => l.contains('Планёрка')), hasLength(2));
      expect(source.summary({'days': '1'}), 'сегодня');
      expect(source.summary({'days': '14'}), 'на 14 дн.');
      expect(source.summary({'days': 'oops'}), 'на 7 дн.');
    });
  });

  group('сборка контекста', () {
    test('разделы, заголовок, оценка токенов и текст запроса', () async {
      await seedTasks();
      final p = await builder.build(const [
        ContextSourceRef(source: 'tasks', filter: {'range': 'week'}),
      ], env);
      expect(p.sections, hasLength(1));
      expect(p.sections.single.label, 'Задачи');
      expect(p.text, startsWith(contextHeader));
      expect(p.text, contains('## Задачи (на 7 дней и просроченные)'));
      expect(p.text, contains('- Смета · срок 2026-10-05'));
      expect(p.tokens, estimateTokens(p.text));
      expect(p.containsSensitive, isFalse);
      expect(p.sections.single.tokens, lessThanOrEqualTo(p.tokens));
    });

    test('пустой выбор: пустой контекст; нет данных — помечено', () async {
      final none = await builder.build(const [], env);
      expect(none.text, isEmpty);
      expect(none.tokens, 0);
      expect(none.sections, isEmpty);
      final empty = await builder.build(const [
        ContextSourceRef(source: 'tasks'),
      ], env);
      expect(empty.text, contains('(нет данных)'));
    });

    test(
      'лимит токенов источника обрезает строки и сообщает об остатке',
      () async {
        for (var i = 0; i < 30; i++) {
          await task(
            'Задача номер $i',
            due: TaskDue.date(DateTime.utc(2026, 10, 5)),
          );
        }
        final p = await builder.build(const [
          ContextSourceRef(source: 'tasks', tokenLimit: 60),
        ], env);
        final s = p.sections.single;
        expect(s.omittedLines, greaterThan(0));
        expect(s.text, contains('… ещё ${s.omittedLines} стр. не поместилось'));
        final shown = '\n- '.allMatches(s.text).length;
        expect(shown + s.omittedLines, 30);
      },
    );

    test('неизвестный источник пропускается и сообщается', () async {
      final p = await builder.build(const [
        ContextSourceRef(source: 'sleep'),
        ContextSourceRef(source: 'tasks'),
      ], env);
      expect(p.unknownSources, ['sleep']);
      expect(p.sections.map((s) => s.source), ['tasks']);
    });

    test('чувствительный источник помечает весь контекст', () async {
      expect(
        builder.isSensitive(const [ContextSourceRef(source: 'finance')]),
        isTrue,
      );
      expect(
        builder.isSensitive(const [ContextSourceRef(source: 'tasks')]),
        isFalse,
      );
      expect(
        builder.isSensitive(const [ContextSourceRef(source: '?')]),
        isFalse,
      );
      final p = await builder.build(const [
        ContextSourceRef(source: 'tasks'),
        ContextSourceRef(source: 'finance'),
      ], env);
      expect(p.containsSensitive, isTrue);
      expect(p.text, contains('Основной счёт'));
    });

    test('оценка токенов: ceil(символов / 3)', () {
      expect(estimateTokens(''), 0);
      expect(estimateTokens('ab'), 1);
      expect(estimateTokens('abc'), 1);
      expect(estimateTokens('abcd'), 2);
    });

    test('реестр по умолчанию: задачи, расписание и (локально) финансы', () {
      final sources = device.container.read(contextSourcesProvider);
      expect(sources.map((s) => s.id), ['tasks', 'events', 'finance']);
      expect(sources.where((s) => s.sensitive).map((s) => s.id), ['finance']);
    });
  });

  group('выбор контекста чата', () {
    test(
      'включение, фильтр, пресет, очистка сохраняются на устройстве',
      () async {
        final c = device.container;
        const id = 'chat-1';
        final notifier = c.read(chatContextProvider(id).notifier);
        await notifier.ready;
        expect(c.read(chatContextProvider(id)).isEmpty, isTrue);

        notifier
          ..toggle(
            'tasks',
            const ContextSourceRef(source: 'tasks', filter: {'range': 'week'}),
          )
          ..setFilter('tasks', {'range': 'month'});
        var state = c.read(chatContextProvider(id));
        expect(state.has('tasks'), isTrue);
        expect(state.of('tasks')!.filter, {'range': 'month'});
        expect(state.presetId, isNull);

        // Перечитывание с диска (новый Notifier) возвращает тот же выбор.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        c.invalidate(chatContextProvider(id));
        await c.read(chatContextProvider(id).notifier).ready;
        state = c.read(chatContextProvider(id));
        expect(state.of('tasks')!.filter, {'range': 'month'});

        const preset = ContextPreset(
          id: 'p1',
          name: 'Неделя',
          sources: [ContextSourceRef(source: 'events')],
          sensitive: false,
        );
        c.read(chatContextProvider(id).notifier).applyPreset(preset);
        state = c.read(chatContextProvider(id));
        expect(state.presetId, 'p1');
        expect(state.has('events'), isTrue);
        expect(state.has('tasks'), isFalse);

        // Ручная правка отвязывает пресет.
        c
            .read(chatContextProvider(id).notifier)
            .toggle('tasks', const ContextSourceRef(source: 'tasks'));
        expect(c.read(chatContextProvider(id)).presetId, isNull);
        c.read(chatContextProvider(id).notifier).clear();
        expect(c.read(chatContextProvider(id)).isEmpty, isTrue);
      },
    );

    test('seed подставляет пресет агента только в пустой выбор', () async {
      final c = device.container;
      final notifier = c.read(chatContextProvider('chat-2').notifier);
      await notifier.ready;
      const preset = ContextPreset(
        id: 'p1',
        name: 'Неделя',
        sources: [ContextSourceRef(source: 'tasks')],
        sensitive: false,
      );
      notifier.seed(preset);
      expect(c.read(chatContextProvider('chat-2')).presetId, 'p1');
      notifier
        ..seed(null)
        ..seed(
          const ContextPreset(
            id: 'p2',
            name: 'Другой',
            sources: [],
            sensitive: false,
          ),
        );
      expect(c.read(chatContextProvider('chat-2')).presetId, 'p1');
    });

    test('превью: собирается по выбору и обновляется вместе с ним', () async {
      await seedTasks();
      final c = device.container;
      const id = 'chat-3';
      final notifier = c.read(chatContextProvider(id).notifier);
      await notifier.ready;
      expect((await c.read(contextPreviewProvider(id).future)).tokens, 0);
      notifier.toggle('tasks', const ContextSourceRef(source: 'tasks'));
      final p = await c.read(contextPreviewProvider(id).future);
      expect(p.text, contains('Оплатить домен'));
      expect(p.tokens, greaterThan(0));
    });
  });

  test('реестр синхронизации знает таблицы ИИ и «Задачи» читаются из БД', () {
    final registry = device.container.read(syncRegistryProvider);
    expect(registry.contains('ai_conversations'), isTrue);
    expect(registry.contains('tasks'), isTrue);
  });
}
