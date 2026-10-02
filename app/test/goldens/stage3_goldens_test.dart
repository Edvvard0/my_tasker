import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

import '../support/ai_ui_env.dart';
import '../support/pump_app.dart';

/// Golden-тесты Этапа 3: экран чата (телефон и десктоп) и карточка
/// предложения задачи. Эталоны — `files/*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
const _conv = '01900000-0000-7000-8000-0000000000c1';
const _agent = '01900000-0000-7000-8000-0000000000a1';
const _proposal = '01900000-0000-7000-8000-0000000000e1';
const _entity = '01900000-0000-7000-8000-0000000000f1';

Future<void> _seedChat(AiRepository repo) async {
  await seedAgent(
    repo,
    AiTopic.calendarTasks,
    id: _agent,
    seedKey: 'calendar_tasks',
  );
  await repo.addFavorite(
    const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  );
  await repo.ensureConversation(
    const Conversation(
      id: _conv,
      title: 'Планы на неделю',
      topic: AiTopic.calendarTasks,
      agentId: _agent,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_conv, 'Какие у меня задачи на этой неделе?');
  await seedAssistantMessage(
    repo,
    id: repo.newId(),
    conversationId: _conv,
    text:
        'На этой неделе **три задачи**:\n- Подготовить смету — до четверга\n'
        '- Созвон с Ромой — в пятницу\n- Оплатить домен — просрочено',
    parts: [
      {
        'type': 'tool_call',
        'id': 'call_1',
        'name': 'get_tasks',
        'arguments': {
          'status': ['todo'],
        },
      },
      {
        'type': 'tool_result',
        'tool_call_id': 'call_1',
        'name': 'get_tasks',
        'content': '{"count":3}',
        'is_error': false,
      },
      {'type': 'text', 'text': 'На этой неделе три задачи'},
    ],
  );
  await repo.addUserMessage(_conv, 'Создай задачу: оплатить домен до пятницы');
  final messageId = repo.newId();
  await seedAssistantMessage(
    repo,
    id: messageId,
    conversationId: _conv,
    text: 'Предлагаю такую задачу.',
    finishReason: 'awaiting_approval',
    promptTokens: 2100,
    completionTokens: 90,
    costKopecks: 18,
    parts: [
      {'type': 'text', 'text': 'Предлагаю такую задачу.'},
      {
        'type': 'proposal',
        'proposal_id': _proposal,
        'tool_call_id': 'call_2',
        'tool': 'create_task',
      },
    ],
  );
  const args = {
    'title': 'Оплатить домен',
    'due_date': '2026-10-02',
    'due_time': '12:00',
    'priority': 1,
    'duration_minutes': 15,
    'project': 'Creora',
    'tags': ['счета'],
  };
  await repoStore(repo).create('ai_tool_proposals', _proposal, {
    'message_id': messageId,
    'tool_call_id': 'call_2',
    'tool': 'create_task',
    'entity_type': 'task',
    'entity_id': _entity,
    'original_arguments': args,
    'arguments': args,
    'status': 'pending',
    'reject_reason': null,
    'decided_at': null,
  });
}

Future<void> _shot(WidgetTester tester, String name, {Finder? of}) =>
    expectLater(
      of ?? find.byType(MaterialApp),
      matchesGoldenFile('files/$name.png'),
    );

void main() {
  group('Чат ИИ', () {
    testWidgets('телефон', (tester) async {
      await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seedChat);
      await _shot(tester, 'ai_chat_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpAi(
        tester,
        size: desktopSize,
        location: '/ai/chat/$_conv',
        seed: _seedChat,
      );
      await _shot(tester, 'ai_chat_desktop');
    });
  });

  group('Карточка предложения задачи', () {
    testWidgets('ожидает решения (телефон)', (tester) async {
      await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seedChat);
      await _shot(
        tester,
        'ai_proposal_card_phone',
        of: find.byKey(const Key('proposal-card')),
      );
    });
  });
}
