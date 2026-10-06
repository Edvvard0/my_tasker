import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/sleep/data/sleep_settings.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/sleep_env.dart';
import '../../support/study_env.dart' show seedStudyDemo;

class _Ids {
  const _Ids({
    required this.today,
    required this.overdue,
    required this.tomorrow,
    required this.inbox,
  });

  final String today;
  final String overdue;
  final String tomorrow;
  final String inbox;
}

Future<_Ids> _seed(ProviderContainer c) async => _Ids(
  today: await seedTask(c, 'Сдать отчёт', date: '2026-10-05', priority: 1),
  overdue: await seedTask(c, 'Оплатить счёт', date: '2026-10-03'),
  tomorrow: await seedTask(c, 'Завтрашнее', date: '2026-10-06'),
  inbox: await seedTask(c, 'Идея', status: TaskStatus.inbox),
);

Future<void> _event(ProviderContainer c) async {
  final repo = c.read(calendarRepositoryProvider);
  await repo.ensureSystemCalendars();
  await repo.createEvent(
    EventEntity(
      id: c.read(taskRepositoryProvider).newTaskId(),
      calendarId: systemCalendarId('personal'),
      title: 'Созвон с заказчиком',
      allDay: false,
      startAt: DateTime.utc(2026, 10, 5, 11),
      endAt: DateTime.utc(2026, 10, 5, 12),
      tz: 'Europe/Moscow',
      location: 'Zoom',
    ),
  );
  await repo.createEvent(
    EventEntity(
      id: c.read(taskRepositoryProvider).newTaskId(),
      calendarId: systemCalendarId('personal'),
      title: 'День рождения',
      allDay: true,
      startDate: parseDate('2026-10-05'),
      endDate: parseDate('2026-10-05'),
    ),
  );
}

void main() {
  group('утренний план', () {
    testWidgets('показывает сон, задачи, пары и события дня', (tester) async {
      late _Ids ids;
      await pumpSleep(
        tester,
        location: '/sleep/morning',
        seedWith: (c) async {
          ids = await _seed(c);
          await seedNight(c.read(sleepRepositoryProvider), '2026-10-05');
          await seedStudyDemo(c);
          await _event(c);
        },
      );
      expect(find.byKey(const Key('morning-plan')), findsOneWidget);
      expect(find.byKey(const Key('plan-date')), findsOneWidget);
      expect(find.text('7 ч 30 мин'), findsOneWidget);
      expect(find.byKey(const Key('plan-edit-sleep')), findsOneWidget);
      // Задачи: сегодняшняя и просроченная (просроченная первой); завтрашней и
      // «входящих» нет.
      expect(find.byKey(Key('plan-task-${ids.today}')), findsOneWidget);
      expect(find.byKey(Key('plan-task-${ids.overdue}')), findsOneWidget);
      expect(find.byKey(Key('plan-task-${ids.tomorrow}')), findsNothing);
      expect(find.byKey(Key('plan-task-${ids.inbox}')), findsNothing);
      expect(find.text('просрочено'), findsOneWidget);
      // Пары из расписания Этапа 7 и события календаря.
      await tester.ensureVisible(find.byKey(const Key('plan-lessons')));
      expect(find.byKey(const Key('plan-lessons')), findsOneWidget);
      expect(find.text('Математический анализ'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('plan-events')));
      expect(find.text('Созвон с заказчиком'), findsOneWidget);
      expect(find.text('День рождения'), findsOneWidget);
      expect(find.text('Zoom'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('выбор дел и «главного» сохраняется строкой на дату', (
      tester,
    ) async {
      late _Ids ids;
      final c = await pumpSleep(
        tester,
        location: '/sleep/morning',
        seedWith: (c) async => ids = await _seed(c),
      );
      expect(find.byKey(const Key('plan-record-sleep')), findsOneWidget);
      await tester.tap(find.byKey(Key('plan-task-${ids.today}')));
      await tester.tap(find.byKey(Key('plan-main-${ids.overdue}')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('plan-note')),
        'Без отвлечений',
      );
      await tester.ensureVisible(find.byKey(const Key('plan-save')));
      await tester.tap(find.byKey(const Key('plan-save')));
      await settleDb(tester);
      final plan = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getPlan('2026-10-05'),
      ))!;
      expect(plan.mainTaskId, ids.overdue);
      expect(plan.taskIds, [ids.overdue, ids.today]);
      expect(plan.note, 'Без отвлечений');
      // Вернулись на «Сон»: серия и пометка «План сделан».
      expect(find.byKey(const Key('sleep-overview')), findsOneWidget);
      expect(find.text('План сделан'), findsOneWidget);
    });

    testWidgets('снятие выбора, повторный тап по «главному», предел в 10 дел', (
      tester,
    ) async {
      final ids = <String>[];
      await pumpSleep(
        tester,
        location: '/sleep/morning',
        seedWith: (c) async {
          for (var i = 0; i < 11; i++) {
            ids.add(await seedTask(c, 'Дело $i', date: '2026-10-05'));
          }
        },
      );
      for (final id in ids.take(10)) {
        await tester.ensureVisible(find.byKey(Key('plan-task-$id')));
        await tester.tap(find.byKey(Key('plan-task-$id')));
      }
      await tester.pump();
      expect(find.text('в плане 10 из 10'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('plan-task-${ids[10]}')));
      await tester.tap(find.byKey(Key('plan-task-${ids[10]}')));
      await tester.pump();
      expect(find.byKey(const Key('plan-error')), findsOneWidget);
      await tester.tap(find.byKey(Key('plan-main-${ids[10]}')));
      await tester.pump();
      expect(find.text('в плане 10 из 10'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('plan-task-${ids[0]}')));
      await tester.tap(find.byKey(Key('plan-task-${ids[0]}')));
      await tester.pump();
      expect(find.text('в плане 9 из 10'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('plan-main-${ids[10]}')));
      await tester.tap(find.byKey(Key('plan-main-${ids[10]}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('plan-main-${ids[10]}')));
      await tester.pump();
      expect(find.text('в плане 10 из 10'), findsOneWidget);
    });

    testWidgets('готовый план открывается с выбранным; удалённая задача — '
        '«Задача удалена»; сделанная — в списке', (tester) async {
      late _Ids ids;
      const ghost = '01900000-0000-7000-8000-0000000000ff';
      final c = await pumpSleep(
        tester,
        location: '/sleep/morning',
        seedWith: (c) async {
          ids = await _seed(c);
          await c
              .read(taskRepositoryProvider)
              .setStatus(ids.overdue, TaskStatus.done);
          await c
              .read(sleepRepositoryProvider)
              .savePlan(
                date: '2026-10-05',
                taskIds: [ids.today, ids.overdue, ghost],
                mainTaskId: ids.today,
                note: 'заметка',
              );
        },
      );
      expect(find.byKey(const Key('plan-done-pill')), findsOneWidget);
      expect(find.text('в плане 3 из 10'), findsOneWidget);
      expect(find.byKey(const Key('plan-missing-$ghost')), findsOneWidget);
      expect(find.text('сделано'), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-missing-remove-$ghost')));
      await tester.pump();
      expect(find.text('в плане 2 из 10'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('plan-save')));
      await tester.tap(find.byKey(const Key('plan-save')));
      await settleDb(tester);
      final plan = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getPlan('2026-10-05'),
      ))!;
      expect(plan.taskIds, [ids.today, ids.overdue]);
    });

    testWidgets('нет задач и сна: пустое состояние, запись сна отсюда', (
      tester,
    ) async {
      final c = await pumpSleep(tester, location: '/sleep/morning');
      expect(find.byKey(const Key('plan-tasks-empty')), findsOneWidget);
      expect(find.byKey(const Key('plan-lessons')), findsNothing);
      expect(find.byKey(const Key('plan-events')), findsNothing);
      await tester.tap(find.byKey(const Key('plan-record-sleep')));
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await settleDb(tester);
      expect(find.byKey(const Key('plan-edit-sleep')), findsOneWidget);
      expect(
        await tester.runAsync(
          () => c.read(sleepRepositoryProvider).getEntry('2026-10-05'),
        ),
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('plan-edit-sleep')));
      await settleDb(tester);
      expect(find.byKey(const Key('sleep-wake')), findsOneWidget);
    });
  });

  group('вечерний чек-ин', () {
    testWidgets('сделано, не сделано, перенос и оценка сохраняются; задачи '
        'двигаются', (tester) async {
      late _Ids ids;
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async {
          ids = await _seed(c);
          await seedTask(
            c,
            'Уже готово',
            date: '2026-10-05',
            status: TaskStatus.done,
          );
        },
      );
      expect(find.byKey(const Key('evening-checkin')), findsOneWidget);
      expect(find.text('Уже готово'), findsOneWidget);
      expect(find.byKey(Key('checkin-task-${ids.today}')), findsOneWidget);
      // Отметить «Сдать отчёт» сделанным.
      await tester.tap(
        find.descendant(
          of: find.byKey(Key('checkin-check-${ids.today}')),
          matching: find.byType(InkResponse),
        ),
      );
      await settleDb(tester);
      expect(find.byKey(Key('checkin-keep-${ids.today}')), findsNothing);
      // Просроченную — на завтра; «Завтрашнее» не показывается вовсе.
      await tester.tap(find.byKey(Key('checkin-tomorrow-${ids.overdue}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkin-rating-4')));
      await tester.enterText(
        find.byKey(const Key('checkin-note')),
        'Хороший день',
      );
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);

      final repo = c.read(sleepRepositoryProvider);
      final checkin = (await tester.runAsync(
        () => repo.getCheckin('2026-10-05'),
      ))!;
      expect(checkin.rating, 4);
      expect(checkin.note, 'Хороший день');
      expect(checkin.doneTaskIds, hasLength(2));
      expect(checkin.doneTaskIds, contains(ids.today));
      expect(checkin.carryOver.single, CarryDecision.tomorrow(ids.overdue));
      final moved = (await tester.runAsync(
        () => c.read(taskRepositoryProvider).getTask(ids.overdue),
      ))!;
      expect(moved.due.date, DateTime.utc(2026, 10, 6));
      expect(find.byKey(const Key('sleep-overview')), findsOneWidget);
      expect(find.text('Чек-ин сделан'), findsOneWidget);
    });

    testWidgets('«Перенести всё на завтра» и «Оставить»', (tester) async {
      late _Ids ids;
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async => ids = await _seed(c),
      );
      await tester.ensureVisible(find.byKey(const Key('checkin-carry-all')));
      await tester.tap(find.byKey(const Key('checkin-carry-all')));
      await tester.pump();
      await tester.tap(find.byKey(Key('checkin-keep-${ids.today}')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);
      final checkin = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getCheckin('2026-10-05'),
      ))!;
      expect(checkin.carryOver.map((d) => d.taskId), [ids.overdue]);
      expect(checkin.rating, isNull);
    });

    testWidgets('перенос на выбранную дату', (tester) async {
      late _Ids ids;
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async => ids = await _seed(c),
      );
      await tester.ensureVisible(find.byKey(Key('checkin-date-${ids.today}')));
      await tester.tap(find.byKey(Key('checkin-date-${ids.today}')));
      await tester.pumpAndSettle();
      // Выбор даты: нажимаем «OK» в календаре — берётся предложенное завтра.
      await tester.tap(find.text('ОК'));
      await tester.pumpAndSettle();
      expect(find.text('Вт, 6 окт.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);
      final task = (await tester.runAsync(
        () => c.read(taskRepositoryProvider).getTask(ids.today),
      ))!;
      expect(task.due.date, DateTime.utc(2026, 10, 6));
    });

    testWidgets('повторяющаяся задача не переносится; чек-ин повторно '
        'открывается с прежними решениями', (tester) async {
      late String recurring;
      late String plain;
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async {
          final repo = c.read(taskRepositoryProvider);
          recurring = repo.newTaskId();
          await repo.createTask(
            TaskEntity(
              id: recurring,
              title: 'Зарядка',
              status: TaskStatus.todo,
              due: TaskDue.date(DateTime.utc(2026, 10, 5)),
              rrule: 'FREQ=DAILY',
              recurrenceMode: RecurrenceMode.schedule,
            ),
          );
          plain = await seedTask(c, 'Письмо', date: '2026-10-05');
          await c
              .read(sleepRepositoryProvider)
              .saveCheckin(
                date: '2026-10-05',
                doneTaskIds: const [],
                carryOver: [CarryDecision.onDate(plain, '2026-10-09')],
                rating: 2,
                note: 'Тяжело',
              );
        },
      );
      expect(find.text('повторяется — не переносится'), findsOneWidget);
      expect(find.byKey(Key('checkin-tomorrow-$recurring')), findsNothing);
      expect(find.byKey(const Key('checkin-done-pill')), findsOneWidget);
      expect(find.text('Пт, 9 окт.'), findsOneWidget);
      expect(find.text('Сохранить изменения'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);
      final task = (await tester.runAsync(
        () => c.read(taskRepositoryProvider).getTask(plain),
      ))!;
      expect(task.due.date, DateTime.utc(2026, 10, 9));
    });

    testWidgets('повторное сохранение чек-ина не стирает прежние решения '
        'о переносе', (tester) async {
      late _Ids ids;
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async => ids = await _seed(c),
      );
      Future<void> save() async {
        await tester.ensureVisible(find.byKey(const Key('checkin-save')));
        await tester.tap(find.byKey(const Key('checkin-save')));
        await settleDb(tester);
      }

      // Первое сохранение: просроченную — на завтра.
      await tester.tap(find.byKey(Key('checkin-tomorrow-${ids.overdue}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('checkin-keep-${ids.today}')));
      await tester.pump();
      await save();
      expect(find.byKey(const Key('sleep-overview')), findsOneWidget);
      // Вечером открыли чек-ин снова: перенесённой задачи среди открытых уже
      // нет; переносим вторую и сохраняем.
      await goTo(tester, c, '/sleep/evening');
      await settleDb(tester);
      expect(find.byKey(Key('checkin-task-${ids.overdue}')), findsNothing);
      await tester.ensureVisible(
        find.byKey(Key('checkin-tomorrow-${ids.today}')),
      );
      await tester.tap(find.byKey(Key('checkin-tomorrow-${ids.today}')));
      await tester.pump();
      await save();
      final checkin = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getCheckin('2026-10-05'),
      ))!;
      expect(
        {for (final d in checkin.carryOver) d.taskId},
        {ids.overdue, ids.today},
        reason: 'решение первого сохранения осталось в журнале',
      );
      // Третье сохранение без изменений ничего не теряет.
      await goTo(tester, c, '/sleep/evening');
      await settleDb(tester);
      await save();
      final again = (await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getCheckin('2026-10-05'),
      ))!;
      expect(again.carryOver, hasLength(2));
    });

    testWidgets('задача удалена на другом устройстве: понятная ошибка, '
        'кнопка снова доступна', (tester) async {
      late _Ids ids;
      await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
        seedWith: (c) async => ids = await _seed(c),
        overrides: [
          sleepRepositoryProvider.overrideWith(
            (ref) => _GoneTaskRepository(
              store: ref.watch(syncStoreProvider),
              tasks: ref.watch(taskRepositoryProvider),
              now: ref.watch(clockProvider),
            ),
          ),
        ],
      );
      await tester.tap(find.byKey(Key('checkin-tomorrow-${ids.overdue}')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('checkin-error')),
          matching: find.textContaining('удалена на другом устройстве'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('checkin-save')))
            .onPressed,
        isNotNull,
      );
      expect(find.byKey(const Key('evening-checkin')), findsOneWidget);
    });

    testWidgets('нечего переносить и нечего отмечать', (tester) async {
      await pumpSleep(tester, location: '/sleep/evening', now: sleepEvening);
      expect(find.byKey(const Key('checkin-done-empty')), findsOneWidget);
      expect(find.byKey(const Key('checkin-open-empty')), findsOneWidget);
      expect(find.byKey(const Key('checkin-carry-all')), findsNothing);
    });

    testWidgets('повторное нажатие на оценку снимает её', (tester) async {
      final c = await pumpSleep(
        tester,
        location: '/sleep/evening',
        now: sleepEvening,
      );
      await tester.ensureVisible(find.byKey(const Key('checkin-rating-3')));
      await tester.tap(find.byKey(const Key('checkin-rating-3')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkin-rating-3')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('checkin-save')));
      await tester.tap(find.byKey(const Key('checkin-save')));
      await settleDb(tester);
      final checkin = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getCheckin('2026-10-05'),
      );
      expect(checkin!.rating, isNull);
    });
  });

  group('блок «Сон» на «Сегодня»', () {
    testWidgets('утром без записи — «Как спал?» первым; запись двумя '
        'касаниями', (tester) async {
      final c = await pumpSleep(tester, location: '/today');
      expect(find.byKey(const Key('today-sleep-block')), findsOneWidget);
      expect(find.text('Как спал?'), findsOneWidget);
      expect(find.byKey(const Key('today-open-morning')), findsOneWidget);
      // Вечерняя кнопка до 18:00 не показывается.
      expect(find.byKey(const Key('today-open-evening')), findsNothing);
      await tester.tap(find.byKey(const Key('today-sleep-record')));
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await settleDb(tester);
      expect(find.byKey(const Key('today-sleep-summary')), findsOneWidget);
      expect(find.text('23:30 → 07:30 · 8 ч'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => c.read(sleepRepositoryProvider).getEntry('2026-10-05'),
        ),
        isNotNull,
      );
    });

    testWidgets('вечером: чек-ин предлагается, серия и карта видны', (
      tester,
    ) async {
      await pumpSleep(
        tester,
        location: '/today',
        now: sleepEvening,
        seedWith: (c) async {
          final repo = c.read(sleepRepositoryProvider);
          await seedNight(repo, '2026-10-05');
          for (final d in ['2026-10-04', '2026-10-05']) {
            await repo.savePlan(date: d, taskIds: const []);
            await repo.saveCheckin(date: d, doneTaskIds: const []);
          }
        },
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('today-sleep-block')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('today-sleep-summary')), findsOneWidget);
      expect(find.byKey(const Key('sleep-heatmap')), findsOneWidget);
      expect(find.text('Серия ритуалов: 2 дн.'), findsOneWidget);
      // Оба ритуала сегодня сделаны — кнопок нет.
      expect(find.byKey(const Key('today-open-morning')), findsNothing);
      expect(find.byKey(const Key('today-open-evening')), findsNothing);
    });

    testWidgets('вечером без чек-ина — кнопка ведёт на экран чек-ина', (
      tester,
    ) async {
      await pumpSleep(
        tester,
        location: '/today',
        now: sleepEvening,
        seedWith: (c) =>
            seedNight(c.read(sleepRepositoryProvider), '2026-10-05'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('today-open-evening')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('today-open-evening')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('evening-checkin')), findsOneWidget);
    });

    testWidgets('десктоп: блок в правой колонке', (tester) async {
      await pumpSleep(tester, location: '/today', size: desktopSize);
      expect(find.byKey(const Key('today-sleep-block')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('блок открывает раздел «Сон»', (tester) async {
      await pumpSleep(
        tester,
        location: '/today',
        seedWith: (c) =>
            seedNight(c.read(sleepRepositoryProvider), '2026-10-05'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('today-sleep-open')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('today-sleep-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sleep-overview')), findsOneWidget);
    });
  });

  group('настройки напоминаний', () {
    testWidgets('время и включение сохраняются; мусор — ошибка', (
      tester,
    ) async {
      final c = await pumpSleep(tester);
      await tester.tap(find.byKey(const Key('sleep-open-settings')));
      await settleDb(tester);
      String shown(String key) => tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text;
      expect(shown('sleep-morning-time'), '09:00');
      expect(shown('sleep-evening-time'), '21:30');
      await tester.enterText(find.byKey(const Key('sleep-morning-time')), '99');
      await tester.tap(find.byKey(const Key('sleep-settings-save')));
      await tester.pump();
      expect(find.byKey(const Key('sleep-settings-error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('sleep-morning-time')),
        '8:15',
      );
      await tester.enterText(
        find.byKey(const Key('sleep-evening-time')),
        '22.00',
      );
      await tester.tap(find.byKey(const Key('sleep-evening-switch')));
      await tester.tap(find.byKey(const Key('sleep-settings-save')));
      await settleDb(tester);
      final settings = c.read(sleepSettingsRepositoryProvider);
      final morning = await tester.runAsync(settings.readMorning);
      final evening = await tester.runAsync(settings.readEvening);
      expect(morning, const SleepReminderSetting(enabled: true, time: '08:15'));
      expect(
        evening,
        const SleepReminderSetting(enabled: false, time: '22:00'),
      );
    });
  });

  group('нажатие на уведомление', () {
    testWidgets('утреннее открывает «Как спал?», вечернее — чек-ин', (
      tester,
    ) async {
      final c = await pumpSleep(tester);
      final taps = c.read(reminderTapsProvider)
        ..add('sleep:morning|2026-10-05');
      await settleDb(tester);
      expect(find.text('Как спал?'), findsWidgets);
      expect(find.byKey(const Key('sleep-save')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-save')));
      await settleDb(tester);
      final e = await tester.runAsync(
        () => c.read(sleepRepositoryProvider).getEntry('2026-10-05'),
      );
      expect(e!.source, SleepSource.morningNotification);
      taps.add('sleep:evening|2026-10-05');
      await settleDb(tester);
      expect(find.byKey(const Key('evening-checkin')), findsOneWidget);
    });
  });
}

/// Перенос падает так, как если бы задачу удалил другой клиент.
class _GoneTaskRepository extends SleepRepository {
  _GoneTaskRepository({required SyncStore store, super.tasks, super.now})
    : super(store);

  @override
  Future<CarryOutcome> applyCarryOver(
    String checkinDate,
    List<CarryDecision> decisions,
  ) async => throw StateError('Задачи нет');
}
