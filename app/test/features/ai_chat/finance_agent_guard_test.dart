import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/presentation/finance_agent_guard.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/privacy_env.dart';

const _agentGeneral = '01900000-0000-7000-8000-0000000000a1';
const _agentFinance = '01900000-0000-7000-8000-0000000000a2';

const _consentText =
    'Агент «Финансы» увидит суммы и данные ваших счетов. Отправить?';

Future<void> _seed(AiRepository repo) async {
  await seedAgent(repo, AiTopic.general, id: _agentGeneral);
  await seedAgent(repo, AiTopic.finance, id: _agentFinance);
  await repo.addFavorite(
    const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  );
}

FakeAiApi _api() =>
    FakeAiApi()
      ..onCompletion = (req) =>
          Stream.fromIterable(okAnswer(req.assistantMessageId, ['Ответ']));

/// Новый чат с темой [topic] (по умолчанию «Финансы»).
Future<AiUi> _newChat(
  WidgetTester tester,
  FakeAiApi api, {
  MemoryFinancePrivacyStore? privacy,
  AiTopic topic = AiTopic.finance,
}) async {
  final ui = await pumpAi(
    tester,
    location: '/ai/new',
    api: api,
    seed: _seed,
    privacyStore: privacy,
  );
  await tester.runAsync(() async {
    await ui.container.read(hideAmountsProvider.notifier).ready;
    await ui.container.read(financeLockProvider.notifier).ready;
  });
  if (topic != AiTopic.general) {
    await tester.tap(find.byKey(Key('topic-${topic.wire}')));
    await tester.pumpAndSettle();
  }
  return ui;
}

Future<void> _send(WidgetTester tester, String text) async {
  await typeInto(tester, 'chat-input', text);
  await tester.tap(find.byKey(const Key('chat-send')));
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _untilRequests(WidgetTester tester, FakeAiApi api, int n) async {
  for (var i = 0; i < 200 && api.requests.length < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

String _inputText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('chat-input')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  group('агент «Финансы»: замок', () {
    testWidgets('замок закрыт: отправка требует PIN, отмена — не уходит', (
      tester,
    ) async {
      final api = _api();
      await _newChat(tester, api, privacy: lockedStore());
      await _send(tester, 'Сколько у меня денег?');
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(api.requests, isEmpty);

      await tester.tap(find.byKey(const Key('finance-unlock-cancel')));
      await tester.pumpAndSettle();
      expect(api.requests, isEmpty);
      expect(_inputText(tester), 'Сколько у меня денег?');
      expect(find.byKey(const Key('user-bubble')), findsNothing);
    });

    testWidgets('замок закрыт: верный PIN — сообщение можно отправить', (
      tester,
    ) async {
      final api = _api();
      await _newChat(tester, api, privacy: lockedStore());
      await _send(tester, 'Сколько у меня денег?');
      await enterPin(tester, testPin);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      // Отправка продолжилась сама, без повторного нажатия.
      await _untilRequests(tester, api, 1);
      expect(api.requests, hasLength(1));
    });

    testWidgets('обычный чат при закрытом замке: PIN не просят', (
      tester,
    ) async {
      final api = _api();
      await _newChat(
        tester,
        api,
        privacy: lockedStore(),
        topic: AiTopic.general,
      );
      await _send(tester, 'Привет');
      await _untilRequests(tester, api, 1);
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(api.requests, hasLength(1));
    });
  });

  group('агент «Финансы»: «скрыть суммы»', () {
    testWidgets('режим выключен: подтверждения нет', (tester) async {
      final api = _api();
      await _newChat(tester, api);
      await _send(tester, 'Баланс?');
      await _untilRequests(tester, api, 1);
      expect(find.byKey(const Key('confirm-dialog')), findsNothing);
      expect(api.requests, hasLength(1));
    });

    testWidgets('режим включён: вопрос; отказ — не уходит, текст в поле', (
      tester,
    ) async {
      final api = _api();
      await _newChat(
        tester,
        api,
        privacy: MemoryFinancePrivacyStore(hidden: true),
      );
      await _send(tester, 'Баланс?');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(find.text(_consentText), findsOneWidget);
      expect(api.requests, isEmpty);

      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.requests, isEmpty);
      expect(_inputText(tester), 'Баланс?');
    });

    testWidgets('согласие один раз на чат; новое переключение режима '
        'спрашивает снова', (tester) async {
      final api = _api();
      final ui = await _newChat(
        tester,
        api,
        privacy: MemoryFinancePrivacyStore(hidden: true),
      );
      await _send(tester, 'Баланс?');
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pump();
      await _untilRequests(tester, api, 1);
      expect(api.requests, hasLength(1));

      // Второе сообщение того же чата — без вопроса.
      await _send(tester, 'А долги?');
      expect(find.byKey(const Key('confirm-dialog')), findsNothing);
      await _untilRequests(tester, api, 2);
      expect(api.requests, hasLength(2));

      // Режим выключили и включили: согласие отозвано.
      final hide = ui.container.read(hideAmountsProvider.notifier);
      await tester.runAsync(() => hide.set(hidden: false));
      await tester.runAsync(() => hide.set(hidden: true));
      await tester.pump();
      await _send(tester, 'И цели?');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(api.requests, hasLength(2));
    });

    testWidgets('обычный чат при включённом режиме: подтверждения нет', (
      tester,
    ) async {
      final api = _api();
      await _newChat(
        tester,
        api,
        privacy: MemoryFinancePrivacyStore(hidden: true),
        topic: AiTopic.general,
      );
      await _send(tester, 'Привет');
      await _untilRequests(tester, api, 1);
      expect(find.byKey(const Key('confirm-dialog')), findsNothing);
      expect(api.requests, hasLength(1));
    });
  });

  group('согласие и определение чата «Финансов»', () {
    test('блокировка раздела отзывает согласие', () async {
      final store = lockedStore(hidden: true);
      final c = ProviderContainer(overrides: privacyOverrides(store: store));
      addTearDown(c.dispose);
      await c.read(financeLockProvider.notifier).ready;
      await c.read(hideAmountsProvider.notifier).ready;
      await c.read(financeLockProvider.notifier).unlock(testPin);
      c.read(financeAgentConsentProvider.notifier).grant('chat-1');
      expect(c.read(financeAgentConsentProvider), {'chat-1'});
      c.read(financeLockProvider.notifier).lockNow();
      expect(c.read(financeAgentConsentProvider), isEmpty);
    });

    test('чат «Финансов»: по теме чата, теме агента и его инструментам', () {
      const general = Conversation(id: 'c', title: '', topic: AiTopic.general);
      AgentProfile agent({
        AiTopic topic = AiTopic.custom,
        String? seedKey,
        List<String> tools = const [],
      }) => AgentProfile(
        id: 'a',
        seedKey: seedKey,
        name: 'A',
        topic: topic,
        systemPrompt: '',
        promptVersion: 1,
        position: 0,
        enabledTools: tools,
      );
      expect(isFinanceAgentChat(general, null), isFalse);
      expect(isFinanceAgentChat(general, agent()), isFalse);
      expect(isFinanceAgentChat(general, agent(tools: ['get_tasks'])), isFalse);
      expect(
        isFinanceAgentChat(general.copyWith(topic: AiTopic.finance), null),
        isTrue,
      );
      expect(
        isFinanceAgentChat(general, agent(topic: AiTopic.finance)),
        isTrue,
      );
      expect(isFinanceAgentChat(general, agent(seedKey: 'finance')), isTrue);
      expect(
        isFinanceAgentChat(general, agent(tools: ['get_tasks', 'get_debts'])),
        isTrue,
      );
    });
  });
}
