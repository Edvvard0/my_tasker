import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/application/chat_session.dart';
import 'package:my_tasker/features/ai_chat/application/sensitive_consent.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/domain/history_builder.dart';
import 'package:my_tasker/features/ai_chat/domain/sensitive_tools.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_context_source.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _agentGeneral = '01900000-0000-7000-8000-0000000000a1';
const _agentFinance = '01900000-0000-7000-8000-0000000000a2';

Future<void> _seed(AiRepository repo) async {
  await seedAgent(repo, AiTopic.general, id: _agentGeneral);
  await seedAgent(repo, AiTopic.finance, id: _agentFinance);
  await repo.addFavorite(
    const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  );
}

Future<void> _seedChat(AiRepository repo, {required String agentId}) async {
  await _seed(repo);
  await repo.ensureConversation(
    Conversation(
      id: _conv,
      title: 'Деньги',
      topic: agentId == _agentFinance ? AiTopic.finance : AiTopic.general,
      agentId: agentId,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_conv, 'Привет');
}

ChatMessage _msg(String id, MessageRole role, String text, {String? model}) =>
    ChatMessage(
      id: id,
      conversationId: 'c',
      role: role,
      text: text,
      parts: [TextPart(text)],
      status: MessageStatus.done,
      model: model,
    );

/// Ждёт, пока интерфейс отправит запрос поддельному API.
Future<void> _untilRequests(
  WidgetTester tester,
  FakeAiApi api,
  int count,
) async {
  for (var i = 0; i < 300 && api.requests.length < count; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(api.requests.length, count);
}

/// Ждёт, пока завершится идущий ответ (кнопка «Отправить» вернулась).
Future<void> _untilIdle(WidgetTester tester) async {
  for (var i = 0; i < 300; i++) {
    if (find.byKey(const Key('chat-send')).evaluate().isNotEmpty) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Future<void> _send(WidgetTester tester, String text) async {
  await typeInto(tester, 'chat-input', text);
  await tester.tap(find.byKey(const Key('chat-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('история для облака (M4): ответы локальной модели не уходят', () {
    final messages = [
      _msg('1', MessageRole.user, 'Сколько у меня денег?'),
      _msg(
        '2',
        MessageRole.assistant,
        'На счетах 361 000 ₽',
        model: 'local/gemma-4-e2b-it',
      ),
      _msg('3', MessageRole.user, 'А долги?'),
      _msg(
        '4',
        MessageRole.assistant,
        'Облачный ответ',
        model: 'openai/gpt-4o',
      ),
      _msg('5', MessageRole.user, 'Спасибо'),
    ];

    test('forCloud опускает ответы local/…, остальное остаётся', () {
      final history = buildHistory(messages, const {}, forCloud: true);
      expect(history, [
        {'role': 'user', 'content': 'Сколько у меня денег?'},
        {'role': 'user', 'content': 'А долги?'},
        {'role': 'assistant', 'content': 'Облачный ответ'},
        {'role': 'user', 'content': 'Спасибо'},
      ]);
      expect(history.toString(), isNot(contains('361')));
    });

    test('для локальной модели история прежняя (флаг выключен)', () {
      final history = buildHistory(messages, const {});
      expect(history, hasLength(5));
      expect(history[1]['content'], 'На счетах 361 000 ₽');
    });

    test('isLocalReply различает роли и модели', () {
      expect(
        isLocalReply(_msg('a', MessageRole.assistant, 'x', model: 'local/m')),
        isTrue,
      );
      expect(
        isLocalReply(_msg('a', MessageRole.user, 'x', model: 'local/m')),
        isFalse,
      );
      expect(isLocalReply(_msg('a', MessageRole.assistant, 'x')), isFalse);
    });
  });

  group('запрос completion: согласие на финансовые инструменты', () {
    CompletionRequest request({bool consent = false}) => CompletionRequest(
      conversationId: 'c',
      assistantMessageId: 'm',
      model: 'openai/gpt-4o',
      messages: const [
        {'role': 'user', 'content': 'x'},
      ],
      contextText: '',
      timezone: 'UTC',
      sensitiveToolsConsent: consent,
    );

    test('без согласия поле не отправляется', () {
      expect(
        request().toJson().containsKey('sensitive_tools_consent'),
        isFalse,
      );
    });

    test('с согласием поле true', () {
      expect(
        request(consent: true).toJson()['sensitive_tools_consent'],
        isTrue,
      );
    });

    test('агенты с чувствительными инструментами', () {
      AgentProfile agent({String? seed, List<String> tools = const []}) =>
          AgentProfile(
            id: 'a',
            seedKey: seed,
            name: 'A',
            topic: AiTopic.custom,
            systemPrompt: 'p',
            promptVersion: 1,
            position: 0,
            enabledTools: tools,
          );
      expect(agentUsesSensitiveTools(null), isFalse);
      expect(agentUsesSensitiveTools(agent(seed: 'finance')), isTrue);
      expect(agentUsesSensitiveTools(agent(seed: 'work')), isFalse);
      expect(agentUsesSensitiveTools(agent(tools: ['get_goals'])), isTrue);
      expect(agentUsesSensitiveTools(agent(tools: ['get_tasks'])), isFalse);
    });
  });

  group('сессия: история и согласие уходят в запрос', () {
    late ManualClock clock;
    late FakeSyncServer server;
    late AiDevice device;
    late FakeAiApi api;

    setUp(() async {
      clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
      server = aiServer(clock);
      api = FakeAiApi();
      device = await AiDevice.create(server, clock: clock, api: api);
    });
    tearDown(() async {
      device.dispose();
      await server.dispose();
    });

    test('локальные ответы беседы не попадают в облачный запрос; согласие '
        'передаётся', () async {
      const draft = Conversation(
        id: _conv,
        title: '',
        topic: AiTopic.finance,
        model: 'openai/gpt-4o',
      );
      final repo = device.container.read(aiRepositoryProvider);
      await repo.ensureConversation(draft);
      await repo.addUserMessage(_conv, 'Сколько у меня денег?');
      await device.container.read(syncStoreProvider).create(
        'ai_messages',
        repo.newId(),
        {
          'conversation_id': _conv,
          'role': 'assistant',
          'text': 'На счетах 361 000 ₽',
          'parts': [
            {'type': 'text', 'text': 'На счетах 361 000 ₽'},
          ],
          'status': 'done',
          'model': 'local/gemma-4-e2b-it',
          'cost_kopecks': 0,
        },
      );
      api.onCompletion = (req) =>
          eventsStream(okAnswer(req.assistantMessageId, ['ок']));
      final session = device.container.read(
        chatSessionProvider(_conv).notifier,
      );
      final accepted = await session.send(
        'А теперь в облаке',
        conversation: draft,
        sensitiveToolsConsent: true,
      );
      expect(accepted, isTrue);
      await session.whenSettled();

      final request = api.requests.single;
      expect(request.sensitiveToolsConsent, isTrue);
      expect([for (final m in request.messages) m['role']], ['user', 'user']);
      expect(request.messages.toString(), isNot(contains('361')));

      // Без согласия поле по умолчанию выключено.
      api.requests.clear();
      final again = await session.send('Ещё', conversation: draft);
      expect(again, isTrue);
      await session.whenSettled();
      expect(api.requests.single.sensitiveToolsConsent, isFalse);
    });
  });

  group('чат агента «Финансы»: диалог согласия', () {
    late FakeAiApi api;

    setUp(() {
      api = FakeAiApi()
        ..onCompletion = (req) =>
            eventsStream(okAnswer(req.assistantMessageId, ['ок']));
    });

    Future<AiUi> open(
      WidgetTester tester, {
      String agentId = _agentFinance,
      SecretStore? store,
    }) => pumpAi(
      tester,
      api: api,
      location: '/ai/chat/$_conv',
      secretStore: store,
      seed: (repo) => _seedChat(repo, agentId: agentId),
    );

    Future<bool?> decision(WidgetTester tester, AiUi ui) =>
        tester.runAsync<bool?>(
          () => ui.container.read(sensitiveToolsConsentProvider).read(_conv),
        );

    testWidgets('первая отправка спрашивает; «Разрешить» запоминается на '
        'беседу, поле уходит, повторно не спрашивает', (tester) async {
      final ui = await open(tester);
      await _send(tester, 'Сколько у меня денег?');
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsOneWidget);
      expect(
        find.textContaining(
          'Данные из раздела «Финансы» (балансы, долги, цели)',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('polza.ai'), findsOneWidget);
      expect(find.text('Разрешить для этого чата'), findsOneWidget);
      expect(find.text('Не разрешать'), findsOneWidget);
      expect(api.requests, isEmpty, reason: 'до решения ничего не отправлено');

      await tapKey(tester, 'consent-allow');
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isTrue);
      expect(api.requests.single.toJson()['sensitive_tools_consent'], isTrue);
      expect(await decision(tester, ui), isTrue);
      await _untilIdle(tester);

      await _send(tester, 'А долги?');
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsNothing);
      await _untilRequests(tester, api, 2);
      expect(api.requests.last.sensitiveToolsConsent, isTrue);
    });

    testWidgets('«Не разрешать»: поле не уходит и больше не спрашивают', (
      tester,
    ) async {
      final ui = await open(tester);
      await _send(tester, 'Сколько у меня денег?');
      await tapKey(tester, 'consent-deny');
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isFalse);
      expect(
        api.requests.single.toJson().containsKey('sensitive_tools_consent'),
        isFalse,
      );
      expect(await decision(tester, ui), isFalse);
      await _untilIdle(tester);

      await _send(tester, 'Ещё вопрос');
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsNothing);
      await _untilRequests(tester, api, 2);
      expect(api.requests.last.sensitiveToolsConsent, isFalse);
    });

    testWidgets('закрытие диалога без выбора: ответ без согласия, решение не '
        'сохраняется', (tester) async {
      final ui = await open(tester);
      await _send(tester, 'Сколько у меня денег?');
      await tester.tapAt(const Offset(5, 5)); // за пределами окна
      await tester.pumpAndSettle();
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isFalse);
      expect(await decision(tester, ui), isNull);
    });

    testWidgets('агент без финансовых инструментов: диалога нет', (
      tester,
    ) async {
      await open(tester, agentId: _agentGeneral);
      await _send(tester, 'Привет');
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsNothing);
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isFalse);
    });

    testWidgets('раздел закрыт PIN: сначала разблокировка, потом согласие', (
      tester,
    ) async {
      final store = MemorySecretStore();
      await tester.runAsync(
        () => PinLockService(store, iterations: 5).setPin('4821'),
      );
      final ui = await open(tester, store: store);
      await _send(tester, 'Сколько у меня денег?');
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsNothing);

      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsOneWidget);
      await tapKey(tester, 'consent-allow');
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isTrue);
      expect(await decision(tester, ui), isTrue);
    });

    testWidgets('отказ от разблокировки: ответ без цифр, решение не '
        'сохраняется', (tester) async {
      final store = MemorySecretStore();
      await tester.runAsync(
        () => PinLockService(store, iterations: 5).setPin('4821'),
      );
      final ui = await open(tester, store: store);
      await _send(tester, 'Сколько у меня денег?');
      await tapKey(tester, 'finance-unlock-cancel');
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isFalse);
      expect(await decision(tester, ui), isNull);
    });

    testWidgets('согласие дано, но раздел закрыт снова: снова разблокировка', (
      tester,
    ) async {
      final store = MemorySecretStore();
      await tester.runAsync(
        () => PinLockService(store, iterations: 5).setPin('4821'),
      );
      final ui = await open(tester, store: store);
      await tester.runAsync(
        () => ui.container
            .read(sensitiveToolsConsentProvider)
            .write(_conv, allowed: true),
      );
      await _send(tester, 'Сколько у меня денег?');
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sensitive-consent-dialog')), findsNothing);
      await _untilRequests(tester, api, 1);
      expect(api.requests.single.sensitiveToolsConsent, isTrue);
    });
  });

  group('превью контекста с финансами', () {
    Future<AiUi> open(
      WidgetTester tester, {
      required SecretStore store,
      bool hide = false,
    }) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        secretStore: store,
        seed: (repo) => _seedChat(repo, agentId: _agentGeneral),
      );
      await tester.runAsync(() async {
        await seedFinanceDemo(ui.container);
        if (hide) {
          await ui.container
              .read(hideAmountsProvider.notifier)
              .set(hidden: true);
        }
      });
      ui.container
          .read(chatContextProvider(_conv).notifier)
          .toggle(
            'finance',
            const ContextSourceRef(
              source: 'finance',
              filter: {'period': 'month'},
            ),
          );
      await tester.pumpAndSettle();
      return ui;
    }

    Future<MemorySecretStore> pinStore(WidgetTester tester) async {
      final store = MemorySecretStore();
      await tester.runAsync(
        () => PinLockService(store, iterations: 5).setPin('4821'),
      );
      return store;
    }

    testWidgets('раздел закрыт: контекст не собирается, превью просит '
        'разблокировку', (tester) async {
      final ui = await open(tester, store: await pinStore(tester));
      final package = await tester.runAsync(
        () => ui.container.read(contextPreviewProvider(_conv).future),
      );
      expect(package!.withheld, isTrue);
      expect(package.text, isEmpty);
      expect(package.tokens, 0);
      expect(find.byKey(const Key('context-caption')), findsOneWidget);
      expect(find.textContaining('раздел закрыт'), findsOneWidget);

      await tester.tap(find.byKey(const Key('context-caption')));
      await tester.pumpAndSettle();
      expect(find.text('Для локальной модели'), findsOneWidget);
      expect(find.text('Что уйдёт в облако'), findsNothing);
      expect(find.byKey(const Key('preview-withheld')), findsOneWidget);
      expect(find.byKey(const Key('preview-text')), findsNothing);
      expect(find.textContaining('361'), findsNothing);

      // Разблокировка из самого превью: текст появляется.
      await tester.tap(find.byKey(const Key('preview-unlock')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-withheld')), findsNothing);
      expect(find.byKey(const Key('preview-text')), findsOneWidget);
      expect(find.textContaining(nb('361 000 ₽')), findsOneWidget);
      expect(find.text('Для локальной модели'), findsOneWidget);
    });

    testWidgets('закрытие замка убирает суммы из превью', (tester) async {
      final ui = await open(tester, store: await pinStore(tester));
      await tester.runAsync(
        () => ui.container
            .read(financeLockProvider.notifier)
            .unlockWithPin('4821'),
      );
      await tester.pumpAndSettle();
      final open1 = await tester.runAsync(
        () => ui.container.read(contextPreviewProvider(_conv).future),
      );
      expect(open1!.withheld, isFalse);
      expect(open1.text, contains(nb('361 000 ₽')));

      ui.container.read(financeLockProvider.notifier).lock();
      await tester.pumpAndSettle();
      final closed = await tester.runAsync(
        () => ui.container.read(contextPreviewProvider(_conv).future),
      );
      expect(closed!.withheld, isTrue);
    });

    testWidgets('«скрыть суммы»: в превью маска, заметка про локальную '
        'модель', (tester) async {
      final ui = await open(tester, store: MemorySecretStore(), hide: true);
      final package = await tester.runAsync(
        () => ui.container.read(contextPreviewProvider(_conv).future),
      );
      expect(package!.withheld, isFalse);
      expect(package.text, contains(maskedAmount));
      expect(package.text, isNot(contains('361')));
      expect(package.text, isNot(contains(nb('54 000 ₽'))));

      await tester.tap(find.byKey(const Key('context-caption')));
      await tester.pumpAndSettle();
      expect(find.text('Для локальной модели'), findsOneWidget);
      expect(find.byKey(const Key('preview-masked-note')), findsOneWidget);
      expect(find.textContaining('361'), findsNothing);
    });

    testWidgets('без финансов превью прежнее: «Что уйдёт в облако»', (
      tester,
    ) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        seed: (repo) => _seedChat(repo, agentId: _agentGeneral),
      );
      final package = await tester.runAsync(
        () => ui.container.read(contextPreviewProvider(_conv).future),
      );
      expect(package!.withheld, isFalse);
      expect(package.containsSensitive, isFalse);
    });
  });
}
