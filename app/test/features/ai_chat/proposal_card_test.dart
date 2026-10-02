import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/proposal_card.dart';

import '../../support/ai_ui_env.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _message = '01900000-0000-7000-8000-0000000000d1';
const _proposal = '01900000-0000-7000-8000-0000000000e1';
const _entity = '01900000-0000-7000-8000-0000000000f1';

const Map<String, Object> _args = {
  'title': 'Подготовить смету',
  'notes': 'Для Елены, до обеда',
  'priority': 2,
  'due_date': '2026-10-01',
  'due_time': '15:00',
  'duration_minutes': 60,
  'project': 'Creora',
  'tags': ['работа'],
};

Future<void> _seed(AiRepository repo) async {
  await repo.ensureConversation(
    const Conversation(
      id: _conv,
      title: 'Смета',
      topic: AiTopic.work,
      model: 'm',
    ),
  );
  await seedAssistantMessage(
    repo,
    id: _message,
    conversationId: _conv,
    text: 'Предлагаю задачу',
    finishReason: 'awaiting_approval',
    parts: [
      {
        'type': 'proposal',
        'proposal_id': _proposal,
        'tool_call_id': 'call_2',
        'tool': 'create_task',
      },
    ],
  );
  await repoStore(repo).create('ai_tool_proposals', _proposal, {
    'message_id': _message,
    'tool_call_id': 'call_2',
    'tool': 'create_task',
    'entity_type': 'task',
    'entity_id': _entity,
    'original_arguments': _args,
    'arguments': _args,
    'status': 'pending',
    'reject_reason': null,
    'decided_at': null,
  });
}

Future<void> _open(WidgetTester tester) async {
  await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
}

void main() {
  test('срок предложенной задачи словами', () {
    expect(
      proposalDueText({'due_date': '2026-10-01', 'due_time': '15:00'}),
      'Чт, 1 окт. · 15:00',
    );
    expect(proposalDueText({'due_date': '2026-10-01'}), 'Чт, 1 окт.');
    expect(proposalDueText({}), 'Без срока');
    expect(proposalDueText({'due_date': 'мусор'}), 'Без срока');
  });

  testWidgets(
    'поля предложения: название, срок, длительность, приоритет, проект, теги',
    (tester) async {
      await _open(tester);
      expect(find.byKey(const Key('proposal-card')), findsOneWidget);
      expect(find.text('ИИ ПРЕДЛАГАЕТ ЗАДАЧУ'), findsOneWidget);
      expect(find.text('Подготовить смету'), findsOneWidget);
      expect(find.text('Чт, 1 окт. · 15:00'), findsOneWidget);
      expect(find.text('1 ч'), findsOneWidget);
      expect(find.text('P2'), findsOneWidget);
      expect(find.text('Creora'), findsOneWidget);
      expect(find.text('работа'), findsOneWidget);
      expect(find.text('Для Елены, до обеда'), findsOneWidget);
      expect(find.byKey(const Key('proposal-edited')), findsNothing);
    },
  );

  testWidgets('правка полей: «изменено вами», новые значения в карточке', (
    tester,
  ) async {
    final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
    await tester.tap(find.byKey(const Key('proposal-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('proposal-title')),
      'Смета для Елены',
    );
    await tester.tap(find.byKey(const Key('proposal-priority-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('proposal-save')));
    await tester.pumpAndSettle();
    expect(find.text('Смета для Елены'), findsOneWidget);
    expect(find.text('P1'), findsOneWidget);
    expect(find.byKey(const Key('proposal-edited')), findsOneWidget);
    expect(find.text('изменено вами'), findsOneWidget);
    // Оригинал неизменяем, правка легла в arguments.
    final row = await tester.runAsync(
      () => ui.container
          .read(syncStoreProvider)
          .getRow('ai_tool_proposals', _proposal),
    );
    expect((row!['arguments']! as Map)['title'], 'Смета для Елены');
    expect((row['original_arguments']! as Map)['title'], 'Подготовить смету');
    expect(row['status'], 'pending');
  });

  testWidgets('правка: можно убрать срок и поправить поля', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('proposal-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proposal-date-clear')));
    await tester.pump();
    expect(find.byKey(const Key('proposal-time')), findsNothing);
    await tester.enterText(find.byKey(const Key('proposal-project')), 'Бот');
    await tester.enterText(find.byKey(const Key('proposal-tags')), 'а, б');
    await tester.enterText(find.byKey(const Key('proposal-duration')), '90');
    await tester.enterText(find.byKey(const Key('proposal-notes')), 'Коротко');
    await tester.tap(find.byKey(const Key('proposal-save')));
    await tester.pumpAndSettle();
    expect(find.text('Без срока'), findsOneWidget);
    expect(find.text('Бот'), findsOneWidget);
    expect(find.text('1 ч 30 мин'), findsOneWidget);
    expect(find.text('Коротко'), findsOneWidget);
  });

  testWidgets(
    'правка: пустое название — ошибка в форме, карточка не меняется',
    (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('proposal-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('proposal-title')), '   ');
      await tester.tap(find.byKey(const Key('proposal-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proposal-error')), findsOneWidget);
      expect(find.text('Введите название задачи'), findsOneWidget);
    },
  );

  testWidgets('одобрить: строка «Задача создана», снэкбар, один раз', (
    tester,
  ) async {
    final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
    await tester.tap(find.byKey(const Key('proposal-approve')));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proposal-approved')), findsOneWidget);
    expect(find.text('Задача создана · Чт, 1 окт. · 15:00'), findsOneWidget);
    expect(find.text('Задача добавлена'), findsOneWidget);
    expect(find.byKey(const Key('proposal-approve')), findsNothing);
    final tasks = await tester.runAsync(
      () => ui.container.read(syncStoreProvider).visibleRows('tasks'),
    );
    expect(tasks!.where((t) => t['id'] == _entity), hasLength(1));
  });

  testWidgets('двойное нажатие «Одобрить»: ровно одна задача', (tester) async {
    final ui = await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seed);
    final button = find.byKey(const Key('proposal-approve'));
    await tester.tap(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();
    final tasks = await tester.runAsync(
      () => ui.container.read(syncStoreProvider).visibleRows('tasks'),
    );
    expect(tasks!.where((t) => t['id'] == _entity), hasLength(1));
    final outbox = await tester.runAsync(
      () => ui.container.read(syncStoreProvider).outbox(),
    );
    expect(
      outbox!.where((o) => o.table == 'tasks' && o.rowId == _entity),
      hasLength(1),
    );
  });

  testWidgets('отклонить: причина — быстрый чип или без причины', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('proposal-reject')));
    await tester.pumpAndSettle();
    expect(find.text('Почему отклонить?'), findsOneWidget);
    for (final r in rejectReasons) {
      expect(find.byKey(Key('reject-reason-$r')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('reject-none')));
    await tester.pumpAndSettle();
    expect(find.text('Отклонено'), findsOneWidget);
    expect(find.byKey(const Key('proposal-approve')), findsNothing);
  });

  testWidgets('отклонить со своей причиной', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('proposal-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('reject-own')),
      'Сделаю завтра',
    );
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Отклонено · Сделаю завтра'), findsOneWidget);
  });

  testWidgets(
    'закрыть лист причины без выбора: предложение остаётся ожидающим',
    (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('proposal-reject')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proposal-card')), findsOneWidget);
    },
  );

  testWidgets('«Открыть» после одобрения ведёт к задачам', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('proposal-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proposal-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tasks-empty')), findsNothing);
    expect(find.byKey(const Key('chat-input')), findsNothing);
  });
}
