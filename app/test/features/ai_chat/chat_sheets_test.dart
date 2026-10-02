import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/ai_ui_env.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _agentGeneral = '01900000-0000-7000-8000-0000000000a1';
const _agentFinance = '01900000-0000-7000-8000-0000000000a2';

Future<void> _seed(AiRepository repo) async {
  await seedAgent(repo, AiTopic.general, id: _agentGeneral);
  await seedAgent(repo, AiTopic.finance, id: _agentFinance);
  await repo.addFavorite(
    const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  );
  await repo.ensureConversation(
    const Conversation(
      id: _conv,
      title: 'Планы',
      topic: AiTopic.general,
      agentId: _agentGeneral,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_conv, 'Привет');
}

Future<void> _seedTasksAndEvents(AiUi ui, WidgetTester tester) async {
  await tester.runAsync(() async {
    final tasks = ui.container.read(taskRepositoryProvider);
    await tasks.createTask(
      TaskEntity(
        id: tasks.newTaskId(),
        title: 'Оплатить домен',
        status: TaskStatus.todo,
        due: TaskDue.date(DateTime.utc(2026, 9, 30)),
        priority: 1,
      ),
    );
    final calendars = ui.container.read(calendarRepositoryProvider);
    await calendars.ensureSystemCalendars();
    await calendars.createEvent(
      EventEntity(
        id: calendars.newEventId(),
        calendarId: systemCalendarId('work'),
        title: 'Созвон Creora',
        allDay: false,
        startAt: DateTime.utc(2026, 9, 30, 9),
        endAt: DateTime.utc(2026, 9, 30, 10),
        tz: 'Europe/Moscow',
      ),
    );
  });
}

void main() {
  group('агент', () {
    testWidgets('выбор агента меняет агента и тему сохранённого чата', (
      tester,
    ) async {
      final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
      await tester.tap(find.byKey(const Key('chat-agent-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agent-$_agentGeneral')), findsOneWidget);
      await tester.tap(find.byKey(const Key('agent-$_agentFinance')));
      await tester.pumpAndSettle();
      final conv = await tester.runAsync(() => ui.repo.getConversation(_conv));
      expect(conv!.agentId, _agentFinance);
      expect(conv.topic, AiTopic.finance);
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-agent-pill')),
          matching: find.text('Финансы'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('агентов ещё нет: подсказка про синхронизацию', (tester) async {
      await pumpAi(tester, location: '/ai/new');
      await tester.tap(find.byKey(const Key('chat-agent-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agents-empty')), findsOneWidget);
    });
  });

  group('контекст чата', () {
    testWidgets('источники, токены, подпись под лентой и превью', (
      tester,
    ) async {
      final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
      await _seedTasksAndEvents(ui, tester);
      expect(find.text('Контекст: 0'), findsOneWidget);
      expect(find.byKey(const Key('context-caption')), findsNothing);

      await tester.tap(find.byKey(const Key('chat-context-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('context-source-tasks')), findsOneWidget);
      expect(find.byKey(const Key('context-source-events')), findsOneWidget);
      expect(find.textContaining('≈ 0'), findsOneWidget);

      await tester.tap(find.byKey(const Key('context-source-tasks')));
      await tester.pumpAndSettle();
      // Фильтр источника появляется при включении.
      await tester.tap(find.byKey(const Key('context-filter-tasks-open')));
      await tester.pumpAndSettle();
      final selection = ui.container.read(chatContextProvider(_conv));
      expect(selection.of('tasks')!.filter, {'range': 'open'});
      expect(
        find.textContaining('≈ 0'),
        findsNothing,
        reason: 'токены посчитаны',
      );

      await tester.tap(find.byKey(const Key('context-preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-text')), findsOneWidget);
      expect(find.textContaining('Оплатить домен'), findsOneWidget);
      expect(find.text('Что уйдёт в облако'), findsOneWidget);
      // Закрыть превью и лист.
      await tester.tap(find.byTooltip('Закрыть').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Закрыть').last);
      await tester.pumpAndSettle();
      expect(find.text('Контекст: 1'), findsOneWidget);
      expect(find.byKey(const Key('context-caption')), findsOneWidget);
      // Подпись под лентой открывает то же превью.
      await tester.tap(find.byKey(const Key('context-caption')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-text')), findsOneWidget);
    });

    testWidgets(
      'превью пустого контекста честно говорит, что уйдёт только переписка',
      (tester) async {
        await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
        await tester.tap(find.byKey(const Key('chat-context-pill')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('context-preview')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('preview-empty')), findsOneWidget);
      },
    );

    testWidgets('сохранить как пресет и применить; чувствительный — с замком', (
      tester,
    ) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        seed: (repo) async {
          await _seed(repo);
          await repo.createPreset('Личное', const [
            ContextSourceRef(source: 'events'),
          ], sensitive: true);
        },
      );
      await tester.tap(find.byKey(const Key('chat-context-pill')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Личное · локально'), findsOneWidget);

      await tester.tap(find.byKey(const Key('context-source-events')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('context-save-preset')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('preset-name')),
        'Расписание',
      );
      await tester.tap(find.byKey(const Key('preset-save')));
      await tester.pumpAndSettle();
      final presets = await tester.runAsync(() => ui.repo.watchPresets().first);
      final saved = presets!.firstWhere((p) => p.name == 'Расписание');
      expect(saved.sensitive, isFalse);
      expect(ui.container.read(chatContextProvider(_conv)).presetId, saved.id);

      await tester.tap(find.byKey(const Key('context-clear')));
      await tester.pumpAndSettle();
      expect(ui.container.read(chatContextProvider(_conv)).isEmpty, isTrue);
      await tester.tap(find.byKey(Key('context-preset-${saved.id}')));
      await tester.pumpAndSettle();
      expect(
        ui.container.read(chatContextProvider(_conv)).has('events'),
        isTrue,
      );
    });
  });

  group('меню чата', () {
    testWidgets('закрепить, переименовать, в архив', (tester) async {
      final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
      Future<void> pick(String key) async {
        await tester.tap(find.byKey(const Key('chat-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      await pick('chat-menu-pin');
      await pick('chat-menu-rename');
      await tester.enterText(
        find.byKey(const Key('rename-field')),
        'Новое имя',
      );
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-title'))).data,
        'Новое имя',
      );
      await pick('chat-menu-archive');
      final conv = await tester.runAsync(() => ui.repo.getConversation(_conv));
      expect(conv!.pinned, isTrue);
      expect(conv.archived, isTrue);
      expect(conv.title, 'Новое имя');
    });

    testWidgets('удаление: подтверждение, корзина, возврат в список', (
      tester,
    ) async {
      final ui = await pumpAi(tester, seed: _seed);
      await tester.tap(find.byKey(const Key('chat-row-$_conv')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-search')), findsOneWidget);
      expect(find.byKey(const Key('chat-row-$_conv')), findsNothing);
      final trash = await tester.runAsync(
        () => ui.container.read(syncStoreProvider).trashItems(),
      );
      expect(trash!.map((t) => t.table), contains('ai_conversations'));
    });
  });
}
