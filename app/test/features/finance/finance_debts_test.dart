import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<List<T>> _rows<T>(
  WidgetTester tester,
  ProviderContainer c,
  String table,
  T Function(Map<String, Object?>) parse,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows(table))
      parse(r),
  ],
))!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = phoneSize,
    Future<void> Function(ProviderContainer c)? more,
  }) => pumpFinance(
    tester,
    location: '/finance/debts',
    size: size,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      if (more != null) await more(c);
    },
  );

  group('«Долги»', () {
    testWidgets('мне должны: итог, карточки, статусы, срок', (tester) async {
      await pump(tester);
      expect(_textOf(tester, 'debts-total'), nb('13 100 ₽'));
      expect(find.byKey(Key('debt-${demo.debtPasha}')), findsOneWidget);
      expect(find.byKey(Key('debt-${demo.debtMasha}')), findsOneWidget);
      expect(find.byKey(Key('debt-${demo.debtSasha}')), findsOneWidget);
      expect(find.text('ОТКРЫТ'), findsNWidgets(3));
      expect(find.text('Паша'), findsOneWidget);
      expect(find.textContaining('срок 15 окт.'), findsOneWidget);
      expect(find.text('просрочен'), findsNothing);
      // «Я должен» пока пусто.
      await tapKey(tester, 'debts-direction-i_owe');
      expect(find.byKey(const Key('debts-empty')), findsOneWidget);
      expect(_textOf(tester, 'debts-total'), nb('0 ₽'));
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(_textOf(tester, 'debts-total'), nb('13 100 ₽'));
    });

    testWidgets('частичные погашения: статус и остаток вычисляются', (
      tester,
    ) async {
      final container = await pump(tester);
      await tapKey(tester, 'debt-${demo.debtMasha}');
      expect(_textOf(tester, 'debt-status'), 'Открыт');
      expect(_textOf(tester, 'debt-remaining'), nb('2 600 ₽'));
      expect(find.byKey(const Key('debt-no-repayments')), findsOneWidget);
      // Сумма по умолчанию — весь остаток.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('repay-amount')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '2600',
      );
      await tester.enterText(find.byKey(const Key('repay-amount')), '600');
      await tester.enterText(find.byKey(const Key('repay-note')), 'на кофе');
      await tapKey(tester, 'repay-save');
      expect(_textOf(tester, 'debt-status'), 'Частично');
      expect(_textOf(tester, 'debt-repaid'), nb('600 ₽'));
      expect(_textOf(tester, 'debt-remaining'), nb('2 000 ₽'));
      expect(find.text('на кофе', skipOffstage: false), findsNothing);
      expect(find.textContaining('на кофе'), findsOneWidget);
      var data = container.read(financeDataProvider).requireValue;
      expect(data.debtSummary.owedToMe, 1250000);
      // Операций по счетам нет («без движения денег»).
      expect(data.transactions, hasLength(9));

      // Больше остатка нельзя.
      await tester.enterText(find.byKey(const Key('repay-amount')), '2 000,01');
      await tapKey(tester, 'repay-save');
      expect(find.text('Погашение больше остатка долга'), findsOneWidget);

      // Остаток целиком: долг закрыт, формы возврата больше нет.
      await tester.enterText(find.byKey(const Key('repay-amount')), '2 000');
      await tapKey(tester, 'repay-save');
      expect(_textOf(tester, 'debt-status'), 'Закрыт');
      expect(find.byKey(const Key('repay-save')), findsNothing);
      data = container.read(financeDataProvider).requireValue;
      expect(data.debtSummary.owedToMe, 1050000);
    });

    testWidgets('возврат на счёт создаёт доход с debt_id — «доход» месяца '
        'не растёт', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'debt-${demo.debtPasha}');
      await tapKey(tester, 'repay-account-${demo.cash}');
      await tester.enterText(find.byKey(const Key('repay-amount')), '3 000');
      await tapKey(tester, 'repay-save');
      final data = container.read(financeDataProvider).requireValue;
      expect(data.balanceOf(demo.cash), 5400000 + 300000);
      final incomes = data.transactions.where(
        (t) => t.debtId == demo.debtPasha,
      );
      expect(incomes, hasLength(1));
      expect(incomes.single.kind, TxKind.income);
      expect(
        data.repaymentsOf(demo.debtPasha).single.transactionId,
        incomes.single.id,
      );
      // Доход месяца прежний: 85 000.
      final sept = monthlyTotals(data.transactions).last;
      expect(sept.income, 8500000);
    });

    testWidgets('закрытые долги — в отдельном фильтре', (tester) async {
      await pump(tester);
      await tapKey(tester, 'debt-${demo.debtSasha}');
      await tapKey(tester, 'repay-save');
      expect(_textOf(tester, 'debt-status'), 'Закрыт');
      // Закрываем лист.
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('debt-${demo.debtSasha}')), findsNothing);
      expect(_textOf(tester, 'debts-total'), nb('10 100 ₽'));
      await tapKey(tester, 'debts-closed');
      expect(find.byKey(Key('debt-${demo.debtSasha}')), findsOneWidget);
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.text('Погашен'), findsOneWidget);
    });

    testWidgets('просроченный долг помечен; в день срока ещё нет', (
      tester,
    ) async {
      final container = await pump(
        tester,
        more: (c) async {
          final repo = c.read(financeRepositoryProvider);
          await repo.createDebt(
            Debt(
              id: repo.newId(),
              direction: DebtDirection.owedToMe,
              counterparty: 'Должник',
              amount: 100000,
              debtDate: '2026-08-01',
              dueDate: '2026-09-29',
            ),
          );
          await repo.createDebt(
            Debt(
              id: repo.newId(),
              direction: DebtDirection.owedToMe,
              counterparty: 'Срок сегодня',
              amount: 100000,
              debtDate: '2026-08-01',
              dueDate: '2026-09-30',
            ),
          );
        },
      );
      expect(find.text('Должник'), findsOneWidget);
      expect(find.textContaining('просрочен'), findsOneWidget);
      final data = container.read(financeDataProvider).requireValue;
      expect(data.debtSummary.debts.where((d) => d.overdue), hasLength(1));
    });

    testWidgets('переплата другим устройством — предупреждение в карточке', (
      tester,
    ) async {
      final container = await pump(
        tester,
        more: (c) async {
          final store = c.read(syncStoreProvider);
          for (final (id, note) in [
            ('01900000-0000-7000-8000-000000000011', 'a'),
            ('01900000-0000-7000-8000-000000000012', 'b'),
          ]) {
            await store.create('debt_repayments', id, {
              'debt_id': demo.debtMasha,
              'amount': 200000,
              'repaid_on': '2026-09-20',
              'transaction_id': null,
              'note': note,
            });
          }
        },
      );
      // Долг закрыт: он в фильтре «Закрытые».
      await tapKey(tester, 'debts-closed');
      await tapKey(tester, 'debt-${demo.debtMasha}');
      expect(find.textContaining('переплата'), findsOneWidget);
      expect(_textOf(tester, 'debt-remaining'), nb('0 ₽'));
      expect(_textOf(tester, 'debt-status'), 'Закрыт');
      // Расхождение видно и в данных обзора.
      final data = container.read(financeDataProvider).requireValue;
      expect([for (final p in data.problems) p.code], contains('over_repaid'));
    });

    testWidgets('удаление погашения возвращает остаток', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'debt-${demo.debtMasha}');
      await tester.enterText(find.byKey(const Key('repay-amount')), '1 000');
      await tapKey(tester, 'repay-save');
      final id = (await _rows(
        tester,
        container,
        'debt_repayments',
        DebtRepayment.fromRow,
      )).single.id;
      await tapKey(tester, 'repayment-delete-$id');
      // Подтверждение обязательно: пока не нажато, ничего не удалено.
      expect(find.byKey(const Key('repayment-delete-dialog')), findsOneWidget);
      expect(find.byKey(const Key('repayment-delete-only')), findsNothing);
      expect(_textOf(tester, 'debt-remaining'), nb('1 600 ₽'));
      await tapKey(tester, 'repayment-delete-cancel');
      expect(_textOf(tester, 'debt-remaining'), nb('1 600 ₽'));
      await tapKey(tester, 'repayment-delete-$id');
      await tapKey(tester, 'repayment-delete-confirm');
      expect(_textOf(tester, 'debt-remaining'), nb('2 600 ₽'));
      expect(find.byKey(const Key('debt-no-repayments')), findsOneWidget);
    });

    group('удаление погашения со связанной операцией', () {
      Future<(ProviderContainer, String, String)> repaidViaAccount(
        WidgetTester tester,
      ) async {
        final container = await pump(tester);
        await tapKey(tester, 'debt-${demo.debtMasha}');
        await tester.enterText(find.byKey(const Key('repay-amount')), '1 000');
        await tapKey(tester, 'repay-account-${demo.cash}');
        await tapKey(tester, 'repay-save');
        final repayment = (await _rows(
          tester,
          container,
          'debt_repayments',
          DebtRepayment.fromRow,
        )).single;
        expect(repayment.transactionId, isNotNull);
        return (container, repayment.id, repayment.transactionId!);
      }

      testWidgets('«Погашение и операцию» удаляет обе строки', (tester) async {
        final (container, id, txId) = await repaidViaAccount(tester);
        await tapKey(tester, 'repayment-delete-$id');
        expect(find.byKey(const Key('repayment-delete-only')), findsOneWidget);
        await tapKey(tester, 'repayment-delete-confirm');
        expect(_textOf(tester, 'debt-remaining'), nb('2 600 ₽'));
        final txs = await _rows(
          tester,
          container,
          'transactions',
          FinTransaction.fromRow,
        );
        expect(txs.where((t) => t.id == txId), isEmpty);
      });

      testWidgets('«Только погашение» оставляет операцию', (tester) async {
        final (container, id, txId) = await repaidViaAccount(tester);
        await tapKey(tester, 'repayment-delete-$id');
        await tapKey(tester, 'repayment-delete-only');
        expect(_textOf(tester, 'debt-remaining'), nb('2 600 ₽'));
        final txs = await _rows(
          tester,
          container,
          'transactions',
          FinTransaction.fromRow,
        );
        expect(txs.where((t) => t.id == txId), hasLength(1));
      });
    });

    testWidgets('«Из Работы» ведёт к ожидаемым поступлениям', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('debts-work-link')));
      await tester.tap(find.byKey(const Key('debts-work-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-income-screen')), findsOneWidget);
    });
  });

  group('форма долга', () {
    testWidgets('«я должен» человеку из «Работы», со счёта не отражаем', (
      tester,
    ) async {
      final container = await pump(tester);
      await tapKey(tester, 'debts-add');
      await tapKey(tester, 'debt-direction-i_owe');
      // Люди из «Работы» — чипами.
      await tapKey(tester, 'debt-person-${demo.work.roma}');
      await tester.enterText(find.byKey(const Key('debt-amount')), '5 000');
      await tester.enterText(
        find.byKey(const Key('debt-comment')),
        'за ноутбук',
      );
      await tapKey(tester, 'debt-due-tomorrow');
      await tapKey(tester, 'debt-save');
      final debt = (await _rows(
        tester,
        container,
        'debts',
        Debt.fromRow,
      )).firstWhere((d) => d.direction == DebtDirection.iOwe);
      expect(debt.personId, demo.work.roma);
      expect(debt.counterparty, isNull);
      expect(debt.amount, 500000);
      expect(debt.dueDate, '2026-10-01');
      expect(debt.debtDate, '2026-09-30');
      expect(debt.comment, 'за ноутбук');
      expect(
        container.read(financeDataProvider).requireValue.transactions,
        hasLength(9),
      );
      // Во вкладке «Я должен» — по имени человека.
      await tapKey(tester, 'debts-direction-i_owe');
      expect(find.text('Рома'), findsOneWidget);
      expect(_textOf(tester, 'debts-total'), nb('5 000 ₽'));
    });

    testWidgets('выдал в долг со счёта: расход с debt_id', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'debts-add');
      await tester.enterText(
        find.byKey(const Key('debt-counterparty')),
        'Коля',
      );
      await tester.enterText(find.byKey(const Key('debt-amount')), '1 000');
      await tapKey(tester, 'debt-account-${demo.cash}');
      await tapKey(tester, 'debt-save');
      final data = container.read(financeDataProvider).requireValue;
      final debt = data.debts.firstWhere((d) => d.counterparty == 'Коля');
      final tx = data.transactions.firstWhere((t) => t.debtId == debt.id);
      expect(tx.kind, TxKind.expense);
      expect(tx.accountId, demo.cash);
      expect(data.balanceOf(demo.cash), 5400000 - 100000);
      expect(find.text('Коля'), findsOneWidget);
    });

    testWidgets('ошибки: нет контрагента, нет суммы, срок раньше даты', (
      tester,
    ) async {
      await pump(tester);
      await tapKey(tester, 'debts-add');
      await tester.enterText(find.byKey(const Key('debt-amount')), '100');
      await tapKey(tester, 'debt-save');
      expect(find.text('Укажите, кто должен или кому должны'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('debt-counterparty')),
        'Вася',
      );
      await tester.enterText(find.byKey(const Key('debt-amount')), '');
      await tapKey(tester, 'debt-save');
      expect(find.text('Укажите сумму долга'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('debt-amount')), '100');
      await tapKey(tester, 'debt-date-tomorrow');
      await tapKey(tester, 'debt-due-today');
      await tapKey(tester, 'debt-save');
      expect(find.text('Срок раньше даты долга'), findsOneWidget);
    });

    testWidgets('правка и удаление долга', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'debt-${demo.debtSasha}');
      await tapKey(tester, 'debt-sheet-edit');
      await tester.enterText(find.byKey(const Key('debt-amount')), '3 500');
      await tapKey(tester, 'debt-save');
      expect(
        (await _rows(
          tester,
          container,
          'debts',
          Debt.fromRow,
        )).firstWhere((d) => d.id == demo.debtSasha).amount,
        350000,
      );
      await tapKey(tester, 'debt-sheet-edit');
      await tapKey(tester, 'debt-delete');
      expect(
        find.textContaining('Операции по счетам останутся'),
        findsOneWidget,
      );
      await tapKey(tester, 'confirm-ok');
      expect(
        (await _rows(
          tester,
          container,
          'debts',
          Debt.fromRow,
        )).map((d) => d.id),
        isNot(contains(demo.debtSasha)),
      );
      // Лист удалённого долга сообщает, что его нет.
      expect(find.byKey(const Key('debt-sheet-missing')), findsOneWidget);
    });

    testWidgets('долг найден после удаления на другом устройстве', (
      tester,
    ) async {
      await pump(tester);
      await tapKey(tester, 'debt-${demo.debtSasha}');
      await tapKey(tester, 'debt-sheet-edit');
      expect(find.byKey(const Key('debt-amount')), findsOneWidget);
    });
  });
}
