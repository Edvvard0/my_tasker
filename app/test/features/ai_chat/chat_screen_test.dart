import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _agentGeneral = '01900000-0000-7000-8000-0000000000a1';
const _agentFinance = '01900000-0000-7000-8000-0000000000a2';
const _proposal = '01900000-0000-7000-8000-0000000000e1';
const _entity = '01900000-0000-7000-8000-0000000000f1';

Future<void> _seedAgents(AiRepository repo) async {
  await seedAgent(repo, AiTopic.general, id: _agentGeneral);
  await seedAgent(repo, AiTopic.finance, id: _agentFinance);
}

Future<void> _seedFavorites(AiRepository repo) async {
  await repo.addFavorite(
    const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  );
}

Future<void> _seedChat(AiRepository repo) async {
  await _seedAgents(repo);
  await _seedFavorites(repo);
  await repo.ensureConversation(
    const Conversation(
      id: _conv,
      title: 'Планы на неделю',
      topic: AiTopic.general,
      agentId: _agentGeneral,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_conv, 'Что у меня на неделе?');
  await seedAssistantMessage(
    repo,
    id: repo.newId(),
    conversationId: _conv,
    text: 'На неделе **три задачи**:\n- Смета\n- Созвон\n- Оплата домена',
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
      {
        'type': 'text',
        'text': 'На неделе **три задачи**:\n- Смета\n- Созвон\n- Оплата домена',
      },
    ],
  );
}

Future<void> _seedChatWithProposal(AiRepository repo) async {
  await _seedChat(repo);
  await repo.addUserMessage(_conv, 'Создай задачу: оплатить домен');
  final messageId = repo.newId();
  await seedAssistantMessage(
    repo,
    id: messageId,
    conversationId: _conv,
    text: 'Предлагаю такую задачу.',
    finishReason: 'awaiting_approval',
    parts: [
      {'type': 'text', 'text': 'Предлагаю такую задачу.'},
      {
        'type': 'tool_call',
        'id': 'call_2',
        'name': 'create_task',
        'arguments': {'title': 'Оплатить домен'},
      },
      {
        'type': 'proposal',
        'proposal_id': _proposal,
        'tool_call_id': 'call_2',
        'tool': 'create_task',
      },
    ],
  );
  await repoStore(repo).create('ai_tool_proposals', _proposal, {
    'message_id': messageId,
    'tool_call_id': 'call_2',
    'tool': 'create_task',
    'entity_type': 'task',
    'entity_id': _entity,
    'original_arguments': {
      'title': 'Оплатить домен',
      'due_date': '2026-10-02',
      'priority': 1,
    },
    'arguments': {
      'title': 'Оплатить домен',
      'due_date': '2026-10-02',
      'priority': 1,
    },
    'status': 'pending',
    'reject_reason': null,
    'decided_at': null,
  });
}

Future<void> _send(WidgetTester tester, String text) async {
  await typeInto(tester, 'chat-input', text);
  await tester.tap(find.byKey(const Key('chat-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Дожидается, пока сессия запросит ответ у поддельного API.
Future<void> _untilRequested(WidgetTester tester, FakeAiApi api) async {
  for (var i = 0; i < 200 && api.requests.isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(api.requests, isNotEmpty);
}

void main() {
  group('новый чат', () {
    testWidgets('тема, подсказки, пилюли шапки', (tester) async {
      await pumpAi(tester, location: '/ai/new', seed: _seedAgents);
      expect(find.text('О чём поговорим?'), findsOneWidget);
      for (final t in AiTopic.selectable) {
        expect(find.byKey(Key('topic-${t.wire}')), findsOneWidget);
      }
      // Подсказки выбранной темы подставляются в поле ввода.
      await tester.tap(find.byKey(const Key('suggestion-0')));
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('chat-input')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'Помоги спланировать неделю',
      );
      expect(find.text('Выбрать модель'), findsOneWidget);
      expect(find.text('Контекст: 0'), findsOneWidget);
      // Тема переключает агента и подсказки.
      await tester.tap(find.byKey(const Key('topic-finance')));
      await tester.pumpAndSettle();
      expect(find.text('Как распределить бюджет на месяц?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-agent-pill')),
          matching: find.text('Финансы'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('первая избранная модель подставляется по умолчанию', (
      tester,
    ) async {
      await pumpAi(tester, location: '/ai/new', seed: _seedFavorites);
      expect(find.text('GPT-4o'), findsOneWidget);
    });

    testWidgets(
      'без модели отправка открывает выбор модели; выбор из каталога',
      (tester) async {
        await pumpAi(tester, location: '/ai/new');
        await typeInto(tester, 'chat-input', 'Привет');
        await tester.tap(find.byKey(const Key('chat-send')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('model-search')), findsOneWidget);
        expect(find.byKey(const Key('model-empty')), findsOneWidget);
        await typeInto(tester, 'model-search', 'claude');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('model-cat-anthropic/claude-sonnet')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('model-cat-openai/gpt-4o')), findsNothing);
        await tester.tap(
          find.byKey(const Key('model-cat-anthropic/claude-sonnet')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Claude Sonnet'),
          findsNothing,
          reason: 'пилюля — хвост id',
        );
        expect(find.text('claude-sonnet'), findsOneWidget);
        // Текст не потерян.
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: find.byKey(const Key('chat-input')),
                  matching: find.byType(EditableText),
                ),
              )
              .controller
              .text,
          'Привет',
        );
      },
    );

    testWidgets('выбор модели: избранные и недоступная в каталоге', (
      tester,
    ) async {
      await pumpAi(
        tester,
        location: '/ai/new',
        seed: (repo) async {
          await _seedFavorites(repo);
          await repo.addFavorite(
            const ModelInfo(
              id: 'old/retired',
              name: 'Старая',
              supportsTools: false,
            ),
          );
        },
      );
      await tester.tap(find.byKey(const Key('chat-model-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-fav-openai/gpt-4o')), findsOneWidget);
      expect(find.text('Недоступна в каталоге'), findsOneWidget);
      await tester.tap(find.byKey(const Key('model-fav-old/retired')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-model-pill')),
          matching: find.text('Старая'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('каталог недоступен: понятное сообщение в выборе модели', (
      tester,
    ) async {
      final api = FakeAiApi()..modelsError = const ApiException.network('x');
      await pumpAi(tester, location: '/ai/new', api: api);
      await tester.tap(find.byKey(const Key('chat-model-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-error')), findsOneWidget);
      expect(find.textContaining('Каталог недоступен'), findsOneWidget);
    });
  });

  group('отправка и стриминг', () {
    testWidgets('дельты, «Думаю…», «Остановить», замена строкой из БД', (
      tester,
    ) async {
      final api = FakeAiApi();
      final gate = StreamController<ChatEvent>();
      late String assistantId;
      late AiUi ui;
      api.onCompletion = (req) {
        assistantId = req.assistantMessageId;
        return gate.stream;
      };
      ui = await pumpAi(
        tester,
        location: '/ai/new',
        api: api,
        seed: _seedFavorites,
      );
      await _send(tester, 'Привет');
      await _untilRequested(tester, api);

      expect(find.byKey(const Key('user-bubble')), findsOneWidget);
      expect(find.byKey(const Key('thinking')), findsOneWidget);
      expect(find.byKey(const Key('chat-stop')), findsOneWidget);
      expect(find.byKey(const Key('chat-send')), findsNothing);

      gate
        ..add(ChatStart(messageId: assistantId))
        ..add(const ChatDelta('Здравствуйте, '))
        ..add(const ChatDelta('это **ответ**'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('thinking')), findsNothing);
      expect(find.byKey(const Key('live-message')), findsOneWidget);
      expect(find.textContaining('Здравствуйте'), findsOneWidget);

      // Сервер сохранил ответ: строка «приходит» в БД (в зоне теста, чтобы не
      // блокировать движок синхронизации), живое сообщение заменяется ею.
      final store = ui.repo.storeForTests;
      final convRow = (await store.visibleRows('ai_conversations')).single;
      unawaited(
        store.create('ai_messages', assistantId, {
          'conversation_id': convRow['id'],
          'role': 'assistant',
          'text': 'Здравствуйте, это **ответ**',
          'parts': [
            {'type': 'text', 'text': 'Здравствуйте, это **ответ**'},
          ],
          'status': 'done',
          'model': 'openai/gpt-4o',
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'cost_kopecks': 12,
          'finish_reason': 'stop',
        }),
      );
      gate
        ..add(
          const ChatUsage(
            promptTokens: 100,
            completionTokens: 20,
            costKopecks: 12,
          ),
        )
        ..add(
          ChatDone(
            messageId: assistantId,
            finishReason: 'stop',
            promptTokens: 100,
            completionTokens: 20,
            costKopecks: 12,
          ),
        );
      await gate.close();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-send')), findsOneWidget);
      expect(find.byKey(const Key('chat-stop')), findsNothing);
      expect(
        find.textContaining('Здравствуйте'),
        findsOneWidget,
        reason: 'без дубля',
      );
      expect(find.byKey(const Key('message-meta')), findsOneWidget);
    });

    testWidgets(
      'остановка: подпись «Остановлено», частичный текст, cancel на сервер',
      (tester) async {
        final api = FakeAiApi();
        final gate = StreamController<ChatEvent>();
        api.onCompletion = (req) => gate.stream;
        await pumpAi(
          tester,
          location: '/ai/new',
          api: api,
          seed: _seedFavorites,
        );
        await _send(tester, 'Расскажи длинно');
        await _untilRequested(tester, api);
        gate.add(const ChatDelta('Начало длинного ответа'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.textContaining('Начало длинного'), findsOneWidget);

        await tester.tap(find.byKey(const Key('chat-stop')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Остановлено'), findsOneWidget);
        expect(find.textContaining('Начало длинного'), findsOneWidget);
        expect(find.byKey(const Key('chat-send')), findsOneWidget);
        expect(api.cancelled, hasLength(1));
        expect(gate.hasListener, isFalse);
        unawaited(gate.close());
      },
    );

    testWidgets('нет сети: сообщение и понятная причина, повтор после сети', (
      tester,
    ) async {
      final api = FakeAiApi()
        ..onCompletion = (req) =>
            Stream.fromIterable(okAnswer(req.assistantMessageId, ['Готово']));
      final ui = await pumpAi(
        tester,
        location: '/ai/new',
        api: api,
        seed: _seedFavorites,
      );
      ui.faults.offline = true;
      await _send(tester, 'Привет');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('failure-line')), findsOneWidget);
      expect(find.textContaining('Нет сети'), findsWidgets);
      expect(
        find.byKey(const Key('user-bubble')),
        findsOneWidget,
        reason: 'сообщение сохранено',
      );
      expect(api.requests, isEmpty);

      ui.faults.offline = false;
      await tester.tap(find.byKey(const Key('failure-retry')));
      await tester.pump();
      await _untilRequested(tester, api);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('failure-line')), findsNothing);
      expect(find.textContaining('Готово'), findsOneWidget);
    });

    testWidgets('лимит исчерпан: сумма в сообщении, красным, без «Повторить»', (
      tester,
    ) async {
      final api = FakeAiApi()
        ..onCompletion = (req) => Stream.error(
          httpError(
            402,
            'limit_exceeded',
            details: {'limit_kopecks': 50000, 'spent_kopecks': 50100},
          ),
        );
      await pumpAi(tester, location: '/ai/new', api: api, seed: _seedFavorites);
      await _send(tester, 'Привет');
      await _untilRequested(tester, api);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Месячный лимит расходов на ИИ исчерпан'),
        findsOneWidget,
      );
      expect(find.textContaining('501 ₽'), findsOneWidget);
      expect(find.byKey(const Key('failure-retry')), findsNothing);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('failure-line')),
          matching: find.byType(Icon),
        ),
      );
      expect(
        icon.color,
        AppColors.dark.danger,
        reason: 'красный — только критичное',
      );
    });

    testWidgets(
      'ошибка посреди ответа: текст сохранён, строка ошибки и «Повторить»',
      (tester) async {
        final api = FakeAiApi()
          ..onCompletion = (req) => Stream.fromIterable([
            ChatStart(messageId: req.assistantMessageId),
            const ChatDelta('Частичный ответ'),
            ChatError(
              code: 'upstream_error',
              message: 'x',
              retryable: true,
              messageId: req.assistantMessageId,
            ),
          ]);
        await pumpAi(
          tester,
          location: '/ai/new',
          api: api,
          seed: _seedFavorites,
        );
        await _send(tester, 'Привет');
        await _untilRequested(tester, api);
        await tester.pumpAndSettle();
        expect(find.textContaining('Частичный ответ'), findsOneWidget);
        expect(find.textContaining('Сбой у провайдера ИИ'), findsOneWidget);
        expect(find.byKey(const Key('failure-retry')), findsOneWidget);
        // Не красным: сбой провайдера не критичен.
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('failure-line')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.color, isNot(AppColors.dark.danger));
      },
    );

    testWidgets(
      'чувствительный пресет: запрос не уходит, текст остаётся в поле',
      (tester) async {
        final api = FakeAiApi();
        final ui = await pumpAi(
          tester,
          location: '/ai/chat/$_conv',
          api: api,
          seed: _seedChat,
        );
        final preset = await tester.runAsync(() async {
          final id = await ui.repo.createPreset('Личное', const [
            ContextSourceRef(source: 'tasks'),
          ], sensitive: true);
          return await ui.repo.getPreset(id);
        });
        // В листе контекста такой пресет помечен замком и не выбирается.
        await tester.tap(find.byKey(const Key('chat-context-pill')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('context-preset-${preset!.id}')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('помечен «не отправлять в облако»'),
          findsOneWidget,
        );
        expect(ui.container.read(chatContextProvider(_conv)).presetId, isNull);
        Navigator.of(tester.element(find.byKey(const Key('context-tokens'))))
            .pop();
        await tester.pumpAndSettle();

        // Чат, в котором такой пресет уже выбран (например, на другом устройстве).
        ui.container
            .read(chatContextProvider(_conv).notifier)
            .applyPreset(preset);
        ScaffoldMessenger.of(
          tester.element(find.byKey(const Key('chat-input'))),
        ).clearSnackBars();
        await tester.pumpAndSettle();
        await _send(tester, 'Привет');
        await tester.pumpAndSettle();
        expect(find.textContaining('не отправлять в облако'), findsWidgets);
        expect(api.requests, isEmpty);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: find.byKey(const Key('chat-input')),
                  matching: find.byType(EditableText),
                ),
              )
              .controller
              .text,
          'Привет',
          reason: 'сообщение не отправлено: текст остаётся',
        );
        expect(
          find.text('Привет'),
          findsOneWidget,
          reason: 'в ленту не попало',
        );
      },
    );

    testWidgets('нет сети: пилюля модели показывает «Нет сети»', (
      tester,
    ) async {
      await pumpAi(
        tester,
        location: '/ai/new',
        seed: _seedFavorites,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-model-pill')),
          matching: find.text('Нет сети'),
        ),
        findsOneWidget,
      );
    });
  });

  group('чат с историей', () {
    testWidgets('сообщения, markdown, шаг инструмента, метаданные', (
      tester,
    ) async {
      await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seedChat);
      expect(find.text('Планы на неделю'), findsOneWidget);
      expect(find.byKey(const Key('user-bubble')), findsOneWidget);
      expect(find.text('Что у меня на неделе?'), findsOneWidget);
      expect(find.textContaining('три задачи'), findsOneWidget);
      expect(find.textContaining('Смета'), findsOneWidget);
      expect(find.text('Читаю задачи · готово'), findsOneWidget);
      expect(find.byKey(const Key('message-meta')), findsOneWidget);
      // Токены и стоимость: 1 234 ток. · 0,12 ₽.
      expect(
        tester.widget<Text>(find.byKey(const Key('message-meta'))).data,
        'openai/gpt-4o · 1 234 ток. · 0,12 ₽',
      );
      expect(find.byKey(const Key('message-copy')), findsOneWidget);
      // Шапка: модель, агент, контекст.
      expect(find.byKey(const Key('chat-model-pill')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-agent-pill')),
          matching: find.text('Общий'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'отменённый и оборванный ответы помечены; повтор у последнего',
      (tester) async {
        final api = FakeAiApi()
          ..onCompletion = (req) => Stream.fromIterable(
            okAnswer(req.assistantMessageId, ['Теперь целиком']),
          );
        await pumpAi(
          tester,
          location: '/ai/chat/$_conv',
          api: api,
          seed: (repo) async {
            await _seedChat(repo);
            await repo.addUserMessage(_conv, 'Расскажи подробно');
            await seedAssistantMessage(
              repo,
              id: repo.newId(),
              conversationId: _conv,
              text: 'Начало, потом',
              status: 'cancelled',
            );
            await repo.addUserMessage(_conv, 'И ещё');
            await seedAssistantMessage(
              repo,
              id: repo.newId(),
              conversationId: _conv,
              text: '',
              status: 'error',
              errorCode: 'upstream_timeout',
              finishReason: null,
            );
          },
        );
        expect(find.text('Остановлено'), findsOneWidget);
        expect(
          find.textContaining('Провайдер ИИ не ответил вовремя'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('failure-retry')));
        await tester.pump();
        await _untilRequested(tester, api);
        await tester.pumpAndSettle();
        // В запрос не попал ответ с ошибкой; частичный отменённый — попал.
        final roles = api.requests.single.messages
            .map((m) => m['role'])
            .toList();
        expect(roles, [
          'user',
          'assistant',
          'tool',
          'user',
          'assistant',
          'user',
        ]);
      },
    );

    testWidgets('карточка предложения в ленте: одобрить -> задача создана', (
      tester,
    ) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        seed: _seedChatWithProposal,
      );
      expect(find.byKey(const Key('proposal-card')), findsOneWidget);
      expect(find.text('ИИ ПРЕДЛАГАЕТ ЗАДАЧУ'), findsOneWidget);
      await tester.tap(find.byKey(const Key('proposal-approve')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proposal-approved')), findsOneWidget);
      expect(find.byKey(const Key('proposal-card')), findsNothing);
      final task = await tester.runAsync(
        () => ui.container.read(syncStoreProvider).getRow('tasks', _entity),
      );
      expect(task, isNotNull);
      expect(task!['source'], 'ai');
    });

    testWidgets('карточка: отклонить с причиной', (tester) async {
      await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        seed: _seedChatWithProposal,
      );
      await tester.tap(find.byKey(const Key('proposal-reject')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reject-reason-Не нужна')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proposal-rejected')), findsOneWidget);
      expect(find.text('Отклонено · Не нужна'), findsOneWidget);
    });

    testWidgets('предупреждение о расходе: 80 % и исчерпан лимит', (
      tester,
    ) async {
      final api = FakeAiApi()
        ..usageValue = const UsageSummary(
          month: '2026-09',
          spentKopecks: 41000,
          requests: 3,
          promptTokens: 1,
          completionTokens: 1,
          limitKopecks: 50000,
        );
      await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        api: api,
        seed: _seedChat,
      );
      expect(find.byKey(const Key('usage-warning')), findsOneWidget);
      expect(
        find.textContaining('Расход приближается к лимиту'),
        findsOneWidget,
      );
    });

    testWidgets('нет предупреждения без лимита и при малом расходе', (
      tester,
    ) async {
      await pumpAi(tester, location: '/ai/chat/$_conv', seed: _seedChat);
      expect(find.byKey(const Key('usage-warning')), findsNothing);
    });

    testWidgets('десктоп: лента ограничена по ширине и работает', (
      tester,
    ) async {
      await pumpAi(
        tester,
        size: desktopSize,
        location: '/ai/chat/$_conv',
        seed: _seedChat,
      );
      expect(find.byKey(const Key('chat-list')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('chat-input'))).width,
        lessThan(860),
      );
    });
  });
}
