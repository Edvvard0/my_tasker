import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/data/finance_context_source.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/finance_ui_env.dart';
import '../../support/manual_clock.dart';
import '../../support/privacy_env.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _agentFinance = '01900000-0000-7000-8000-0000000000a2';
const _nb = ' ';

/// Сумма с «₽» в тексте контекста.
final RegExp _amount = RegExp(r'\d[\d\s ]*(?:,\d{1,2})?\s*₽');

Future<void> _seedChat(AiRepository repo) async {
  await seedAgent(repo, AiTopic.finance, id: _agentFinance);
  await repo.ensureConversation(
    const Conversation(
      id: _conv,
      title: 'Деньги',
      topic: AiTopic.finance,
      agentId: _agentFinance,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_conv, 'Привет');
}

class _Data {
  late FinanceDemo finance;
  late DebtsDemo debts;
}

Future<_Data> _seedData(ProviderContainer c) async {
  final data = _Data()
    ..finance = await seedFinanceDemo(c)
    ..debts = await seedDebtsDemo(c);
  await addGoal(c, name: 'Отпуск', target: 40000000, deadline: '2026-12-31');
  return data;
}

void main() {
  // 30 сентября 2026, 11:40 по Москве: период «месяц» — сентябрь.
  late AiDevice device;
  late MemoryFinancePrivacyStore store;
  late ContextEnv env;
  late ContextBuilder builder;
  late FinanceContextSource source;

  Future<void> start({MemoryFinancePrivacyStore? withStore}) async {
    ensureTimeZones();
    store = withStore ?? MemoryFinancePrivacyStore();
    final clock = ManualClock(demoNow.millisecondsSinceEpoch);
    device = await AiDevice.create(
      aiServer(clock),
      clock: clock,
      overrides: privacyOverrides(store: store),
    );
    final c = device.container;
    await c.read(financeLockProvider.notifier).ready;
    await c.read(hideAmountsProvider.notifier).ready;
    env = c.read(contextEnvProvider)();
    builder = c.read(contextBuilderProvider);
    source = c
        .read(contextSourcesProvider)
        .whereType<FinanceContextSource>()
        .single;
    // Подписка держит автоочищаемые зависимости доступа живыми.
    c.listen(financeAiAccessProvider, (_, _) {});
  }

  tearDown(() => device.dispose());

  Future<List<String>> lines([Map<String, Object?> filter = const {}]) {
    final c = device.container;
    env = c.read(contextEnvProvider)();
    return source.lines(env, {...source.defaultFilter, ...filter});
  }

  group('источник «Финансы»: описание', () {
    test('в реестре, «только локально», фильтр периода', () async {
      await start();
      final sources = device.container.read(contextSourcesProvider);
      expect(sources.map((s) => s.id), ['tasks', 'events', 'finance']);
      expect(source.sensitive, isTrue);
      expect(source.label, 'Финансы');
      expect(source.filters.single.options.keys, [
        'month',
        'quarter',
        'half',
        'year',
      ]);
      expect(source.defaultFilter, {'period': 'month'});
      expect(source.summary({'period': 'quarter'}), 'за 3 месяца');
      expect(source.summary({'period': 'half'}), 'за 6 месяцев');
      expect(source.summary({'period': 'year'}), 'за год');
      expect(source.summary(const {}), 'за месяц');
      expect(
        builder.isSensitive(const [ContextSourceRef(source: 'finance')]),
        isTrue,
      );
    });
  });

  group('суммы разрешены (режим «скрыть суммы» выключен)', () {
    test('балансы по счетам, категории, цели и долги — теми же расчётами, '
        'что на экранах', () async {
      await start();
      await _seedData(device.container);
      final out = await lines();
      final text = out.join('\n');

      expect(out.first, startsWith('Счета (общий баланс 245${_nb}120,10'));
      expect(
        text,
        contains('- Т-Банк Black · дебетовая карта · 195${_nb}620,10'),
      );
      expect(text, contains('- ВТБ Мир · кредитная карта · -12${_nb}500'));
      expect(text, contains('- Наличные · наличные · 49${_nb}000'));
      expect(text, contains('Расходы за период (2026-09-01 — 2026-09-30)'));
      // Сентябрь: продукты 1 249,90, кафе 1 310, транспорт 420 = 2 979,90.
      expect(text, contains('- Продукты · 1${_nb}249,90'));
      expect(text, contains('2${_nb}979,90'));
      expect(text, contains('Доходы за период'));
      expect(text, contains('- Доход с проектов · 20${_nb}000'));
      expect(text, contains('Цели:'));
      expect(text, contains('- Отпуск · '));
      expect(text, contains('срок 2026-12-31'));
      // Долги: Эмир 7 500 просрочен; Настя 2 000 из 2 600; Влад мой.
      expect(text, contains('Долги (мне должны'));
      expect(text, contains('- Эмир · мне должны · остаток 7${_nb}500'));
      expect(text, contains('просрочен'));
      expect(text, contains('- Влад · я должен'));
      expect(text, isNot(contains('Суммы не включены')));
      // Закрытый долг не перечисляется.
      expect(text, isNot(contains('Тимур')));
    });

    test('период «3 месяца» захватывает август', () async {
      await start();
      await _seedData(device.container);
      final month = (await lines()).join('\n');
      final quarter = (await lines({'period': 'quarter'})).join('\n');
      expect(quarter, contains('2026-07-01 — 2026-09-30'));
      expect(quarter, isNot(equals(month)));
      expect(quarter, contains('Зарплата'));
      expect(month, isNot(contains('Зарплата')));
    });

    test('архивные счета и цели не попадают в контекст', () async {
      await start();
      final c = device.container;
      await addAccount(c, 'Рабочий', opening: 100000);
      await addAccount(c, 'Старый', opening: 5000, archived: true);
      await addGoal(c, name: 'Курсы', target: 100, archived: true);
      final text = (await lines()).join('\n');
      expect(text, contains('Рабочий'));
      expect(text, isNot(contains('Старый')));
      expect(text, isNot(contains('Курсы')));
      expect(text, contains('Цели: нет'));
    });

    test('пустые данные: честные «нет»', () async {
      await start();
      final out = await lines();
      expect(out, contains('Счета: нет'));
      expect(out, contains('Цели: нет'));
      expect(out, contains('Долги: нет'));
      expect(
        out.where((l) => l.startsWith('Расходы за период')).single,
        endsWith('нет операций'),
      );
    });

    test('все долги закрыты — «открытых долгов нет»', () async {
      await start();
      final c = device.container;
      final debt = await addDebt(c, who: 'Тимур', amount: 400000);
      await addRepaymentTo(c, debt: debt, amount: 400000);
      final text = (await lines()).join('\n');
      expect(text, contains('- открытых долгов нет'));
    });
  });

  group('«скрыть суммы» включён: суммы не уходят без подтверждения', () {
    test(
      'по умолчанию — только структура, и текст об этом первой строкой',
      () async {
        await start(withStore: MemoryFinancePrivacyStore(hidden: true));
        await _seedData(device.container);
        final out = await lines();
        final text = out.join('\n');

        expect(out.first, financeAmountsWithheldLine);
        expect(_amount.hasMatch(text), isFalse, reason: text);
        for (final fragment in ['245', '195', '1${_nb}249', '7${_nb}500']) {
          expect(text, isNot(contains(fragment)), reason: fragment);
        }
        // Структура на месте: счета, категории и число операций, цели, долги.
        expect(text, contains('- Т-Банк Black · дебетовая карта'));
        expect(text, contains('- Продукты · 1 оп.'));
        expect(text, contains('- Отпуск · срок 2026-12-31'));
        expect(text, contains('- Эмир · мне должны · просрочен'));
        expect(text, isNot(contains('%')));
      },
    );

    test('явное подтверждение в превью включает суммы', () async {
      await start(withStore: MemoryFinancePrivacyStore(hidden: true));
      await _seedData(device.container);
      device.container
          .read(financeAiAmountsConsentProvider.notifier)
          .set(value: true);
      final out = await lines();
      expect(out.first, isNot(financeAmountsWithheldLine));
      expect(out.join('\n'), contains('245${_nb}120,10'));
    });

    test('согласие отзывается сменой режима', () async {
      await start(withStore: MemoryFinancePrivacyStore(hidden: true));
      await _seedData(device.container);
      final c = device.container;
      c.read(financeAiAmountsConsentProvider.notifier).set(value: true);
      await c.read(hideAmountsProvider.notifier).set(hidden: false);
      await c.read(hideAmountsProvider.notifier).set(hidden: true);
      final text = (await lines()).join('\n');
      expect(_amount.hasMatch(text), isFalse);
    });
  });

  group('замок закрыт: данных нет', () {
    test(
      'вместо данных — одна строка о блокировке; после снятия — данные',
      () async {
        await start(withStore: lockedStore());
        await _seedData(device.container);
        final out = await lines();
        expect(out, [financeLockedLine]);
        final locked = out.join('\n');
        for (final secret in ['Т-Банк', 'Эмир', 'Отпуск', 'Продукты', '₽']) {
          expect(locked, isNot(contains(secret)), reason: secret);
        }

        await device.container
            .read(financeLockProvider.notifier)
            .unlock(testPin);
        final open = (await lines()).join('\n');
        expect(open, contains('Т-Банк Black'));
        expect(open, contains('245${_nb}120,10'));
      },
    );

    test('замок закрыт даже при подтверждённых суммах', () async {
      await start(withStore: lockedStore());
      final c = device.container;
      c.read(financeAiAmountsConsentProvider.notifier).set(value: true);
      expect(await lines(), [financeLockedLine]);
    });
  });

  group('сборка контекста', () {
    test('раздел, заголовок, пометка «чувствительный», токены', () async {
      await start();
      await _seedData(device.container);
      final p = await builder.build(const [
        ContextSourceRef(source: 'finance', filter: {'period': 'month'}),
      ], device.container.read(contextEnvProvider)());
      expect(p.containsSensitive, isTrue);
      expect(p.sections.single.label, 'Финансы');
      expect(p.text, startsWith(contextHeader));
      expect(p.text, contains('## Финансы (за месяц)'));
      expect(p.tokens, estimateTokens(p.text));
    });

    test('лимит токенов обрезает строки источника', () async {
      await start();
      await _seedData(device.container);
      final p = await builder.build(const [
        ContextSourceRef(source: 'finance', tokenLimit: 40),
      ], device.container.read(contextEnvProvider)());
      expect(p.sections.single.omittedLines, greaterThan(0));
    });

    test('превью чата пересобирается при смене режима и согласия', () async {
      await start();
      final c = device.container;
      await _seedData(c);
      const id = 'chat-finance';
      final notifier = c.read(chatContextProvider(id).notifier);
      await notifier.ready;
      notifier.toggle(
        'finance',
        ContextSourceRef(source: 'finance', filter: source.defaultFilter),
      );
      // Подписка держит автоочищаемое превью.
      c.listen(contextPreviewProvider(id), (_, _) {});

      var preview = await c.read(contextPreviewProvider(id).future);
      expect(preview.text, contains('245${_nb}120,10'));

      await c.read(hideAmountsProvider.notifier).set(hidden: true);
      preview = await c.read(contextPreviewProvider(id).future);
      expect(_amount.hasMatch(preview.text), isFalse);
      expect(preview.text, contains(financeAmountsWithheldLine));

      c.read(financeAiAmountsConsentProvider.notifier).set(value: true);
      preview = await c.read(contextPreviewProvider(id).future);
      expect(preview.text, contains('245${_nb}120,10'));

      // Замок выключен: lockNow ничего не закрывает.
      c.read(financeLockProvider.notifier).lockNow();
      preview = await c.read(contextPreviewProvider(id).future);
      expect(preview.text, contains('245${_nb}120,10'));
    });
  });

  group('превью в чате «Финансы»', () {
    Future<AiUi> openChat(
      WidgetTester tester, {
      required MemoryFinancePrivacyStore privacy,
    }) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/chat/$_conv',
        seed: _seedChat,
        privacyStore: privacy,
      );
      await tester.runAsync(() => _seedData(ui.container));
      await tester.runAsync(
        () => ui.container.read(hideAmountsProvider.notifier).ready,
      );
      await tester.tap(find.byKey(const Key('chat-context-pill')));
      await tester.pumpAndSettle();
      return ui;
    }

    Future<void> openPreview(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('context-source-finance')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('context-preview')));
      await tester.pumpAndSettle();
    }

    String previewText(WidgetTester tester) => tester
        .widget<SelectableText>(find.byKey(const Key('preview-text')))
        .data!;

    testWidgets('источник «Финансы» помечен «только локально»', (tester) async {
      await openChat(tester, privacy: MemoryFinancePrivacyStore());
      expect(find.byKey(const Key('context-source-finance')), findsOneWidget);
      expect(find.textContaining('только локально'), findsOneWidget);
    });

    testWidgets('«скрыть суммы» включён: в превью только структура, кнопка '
        'подтверждения; подтверждение включает суммы', (tester) async {
      await openChat(tester, privacy: MemoryFinancePrivacyStore(hidden: true));
      await openPreview(tester);
      expect(find.byKey(const Key('preview-finance-notice')), findsOneWidget);
      expect(previewText(tester), contains('Суммы не включены'));
      expect(_amount.hasMatch(previewText(tester)), isFalse);

      await tester.tap(find.byKey(const Key('preview-finance-toggle')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(previewText(tester), contains('245${_nb}120,10'));
      expect(find.text('Убрать суммы'), findsOneWidget);

      await tester.tap(find.byKey(const Key('preview-finance-toggle')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(_amount.hasMatch(previewText(tester)), isFalse);
    });

    testWidgets('режим выключен: уведомления нет, суммы в превью', (
      tester,
    ) async {
      await openChat(tester, privacy: MemoryFinancePrivacyStore());
      await openPreview(tester);
      expect(find.byKey(const Key('preview-finance-notice')), findsNothing);
      expect(previewText(tester), contains('245${_nb}120,10'));
    });

    testWidgets('замок закрыт: в превью нет данных', (tester) async {
      await openChat(tester, privacy: lockedStore());
      await openPreview(tester);
      expect(find.byKey(const Key('preview-finance-notice')), findsNothing);
      expect(previewText(tester), contains(financeLockedLine));
      expect(_amount.hasMatch(previewText(tester)), isFalse);
    });
  });
}
