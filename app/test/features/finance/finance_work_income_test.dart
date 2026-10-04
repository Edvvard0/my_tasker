import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = phoneSize,
    bool seed = true,
  }) => pumpFinance(
    tester,
    location: '/finance/work',
    size: size,
    seedWith: (c) async {
      if (seed) demo = await seedFinanceDemo(c);
    },
  );

  Future<List<Payment>> payments(
    WidgetTester tester,
    ProviderContainer c,
  ) async => (await tester.runAsync(
    () async => [
      for (final r in await c.read(syncStoreProvider).visibleRows('payments'))
        Payment.fromRow(r),
    ],
  ))!;

  group('ожидаемые поступления из «Работы»', () {
    testWidgets('дебиторка по заказчикам и платежи, не отражённые на '
        'счетах', (tester) async {
      final container = await pump(tester);
      expect(_textOf(tester, 'work-income-total'), nb('80 500 ₽'));
      expect(find.text('2 заказчика'), findsOneWidget);
      expect(
        find.byKey(Key('work-income-client-${demo.work.roma}')),
        findsOneWidget,
      );
      expect(find.text('Рома'), findsWidgets);
      expect(find.text('Елена'), findsWidgets);
      final list = await payments(tester, container);
      expect(list, hasLength(4));
      for (final p in list) {
        expect(find.byKey(Key('work-income-unlinked-${p.id}')), findsOneWidget);
      }
      expect(find.byKey(const Key('work-income-no-pending')), findsNothing);
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(_textOf(tester, 'work-income-total'), nb('80 500 ₽'));
    });

    testWidgets('клиент ведёт в «Мне должны» Работы', (tester) async {
      await pump(tester);
      await tapKey(tester, 'work-income-client-${demo.work.roma}');
      expect(find.byKey(const Key('receivables-screen')), findsOneWidget);
    });

    testWidgets('«На счёт»: доход со ссылкой на платёж; платёж больше не '
        'ждёт; в аналитике доход один раз', (tester) async {
      final container = await pump(tester);
      final payment = (await payments(
        tester,
        container,
      )).firstWhere((p) => p.amount == 1200000);
      final before = container
          .read(financeDataProvider)
          .requireValue
          .balanceOf(demo.bank);
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      // Сумма по умолчанию — всё, что ещё не отражено.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('reflect-amount')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '12000',
      );
      await tapKey(tester, 'reflect-account-${demo.bank}');
      await tapKey(tester, 'reflect-save');
      expect(
        find.byKey(Key('work-income-unlinked-${payment.id}')),
        findsNothing,
      );
      final data = container.read(financeDataProvider).requireValue;
      final income = data.transactions.firstWhere(
        (t) => t.workPaymentId == payment.id,
      );
      expect(income.kind, TxKind.income);
      expect(income.source, TxSource.workPayment);
      expect(income.status, TxStatus.confirmed);
      expect(income.accountId, demo.bank);
      expect(income.amount, 1200000);
      expect(income.merchant, 'Рома');
      // Момент платежа Работы сохранён: 20 августа.
      expect(moscowDay(income.occurredAt), '2026-08-20');
      expect(data.balanceOf(demo.bank), before + 1200000);
      expect(data.coverageOf(payment.id)!.unlinked, 0);
      // Доход платежа попал в аналитику августа ровно один раз.
      final august = monthlyTotals(data.transactions)
          .firstWhere((m) => m.month == '2026-08');
      expect(august.income, 1200000);
      // Дебиторка Работы не изменилась: это отдельная от денег на счёте
      // запись о факте оплаты.
      expect(_textOf(tester, 'work-income-total'), nb('80 500 ₽'));
    });

    testWidgets('платёж делится между счетами несколькими доходами', (
      tester,
    ) async {
      final container = await pump(tester);
      final payment = (await payments(
        tester,
        container,
      )).firstWhere((p) => p.amount == 1200000);
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      await tester.enterText(find.byKey(const Key('reflect-amount')), '5 000');
      await tapKey(tester, 'reflect-account-${demo.cash}');
      await tapKey(tester, 'reflect-save');
      // Осталось не отражено 7 000.
      expect(
        _textOf(tester, 'work-income-unlinked-${payment.id}'),
        nb('7 000 ₽'),
      );
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      await tapKey(tester, 'reflect-account-${demo.savings}');
      await tapKey(tester, 'reflect-save');
      expect(
        find.byKey(Key('work-income-unlinked-${payment.id}')),
        findsNothing,
      );
      final data = container.read(financeDataProvider).requireValue;
      expect(
        data.transactions.where((t) => t.workPaymentId == payment.id),
        hasLength(2),
      );
      expect(data.balanceOf(demo.cash), 5400000 + 500000);
      expect(data.balanceOf(demo.savings), 800000 + 700000);
    });

    testWidgets('ошибки: больше, чем не отражено; нет суммы; нет счёта', (
      tester,
    ) async {
      final container = await pump(tester);
      final payment = (await payments(tester, container)).first;
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      await tester.enterText(find.byKey(const Key('reflect-amount')), '');
      await tapKey(tester, 'reflect-save');
      expect(find.text('Укажите сумму'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('reflect-amount')),
        '1 000 000',
      );
      await tapKey(tester, 'reflect-save');
      expect(
        find.text('Больше, чем ещё не отражено на счетах'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('reflect-amount')), '1');
      await tapKey(tester, 'reflect-save');
      // Счёт выбран по умолчанию, поэтому сохраняется.
      expect(find.byKey(const Key('reflect-error')), findsNothing);
    });

    testWidgets('привязано больше суммы платежа — предупреждение', (
      tester,
    ) async {
      final container = await pump(tester);
      final payment = (await payments(tester, container)).first;
      await tester.runAsync(
        () => container
            .read(financeRepositoryProvider)
            .reflectWorkPayment(
              paymentId: payment.id,
              accountId: demo.bank,
              amount: payment.amount + 5,
              occurredAt: payment.paidAt,
            ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('work-income-over-${payment.id}')), findsOneWidget);
    });

    testWidgets('нет проектов: пустое состояние', (tester) async {
      await pump(tester, seed: false);
      expect(find.byKey(const Key('work-income-empty')), findsOneWidget);
      expect(_textOf(tester, 'work-income-total'), nb('0 ₽'));
      expect(find.byKey(const Key('work-income-no-pending')), findsOneWidget);
    });

    testWidgets('«На счёт» без счетов — подсказка', (tester) async {
      final container = await pumpFinance(
        tester,
        location: '/finance/work',
        seedWith: (c) async {
          await seedWorkDemo(c);
        },
      );
      final payment = (await payments(tester, container)).first;
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      expect(find.text('Сначала добавьте счёт.'), findsOneWidget);
      await tapKey(tester, 'reflect-save');
      expect(find.text('Выберите счёт'), findsOneWidget);
    });
  });
}
