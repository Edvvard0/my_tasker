import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../support/finance_env.dart';

/// Golden-тесты Этапа 5: счета и общий баланс, операция (быстрый ввод) и
/// цели (случай Excel: «Есть» 454 600 и без кредитки 329 600) на демо
/// по макетам 02, 6.5. Только эти экраны (04, 2.4): остальное проверено
/// виджет-тестами. Эталоны — `files/finance_*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Финансы: обзор и счета', () {
    testWidgets('обзор (телефон)', (tester) async {
      await pumpFinance(tester, seed: true);
      await _shot(tester, 'finance_overview_phone');
    });

    testWidgets('счета (телефон)', (tester) async {
      await pumpFinance(tester, seed: true, location: '/finance/accounts');
      await _shot(tester, 'finance_accounts_phone');
    });

    testWidgets('счета (десктоп)', (tester) async {
      await pumpFinance(
        tester,
        seed: true,
        location: '/finance/accounts',
        size: desktopSize,
      );
      await _shot(tester, 'finance_accounts_desktop');
    });
  });

  group('Финансы: операция', () {
    testWidgets('быстрый ввод расхода (телефон)', (tester) async {
      await pumpFinance(tester, seed: true, location: '/finance/transactions');
      await tapKey(tester, 'transactions-add');
      await tester.enterText(find.byKey(const Key('tx-amount')), '1 249,90');
      await tapKey(tester, 'tx-category-${groceriesId()}');
      await tester.enterText(find.byKey(const Key('tx-merchant')), 'Пятёрочка');
      await tester.pumpAndSettle();
      await _shot(tester, 'finance_transaction_phone');
    });

    testWidgets('лента операций (телефон)', (tester) async {
      await pumpFinance(tester, seed: true, location: '/finance/transactions');
      await _shot(tester, 'finance_transactions_phone');
    });
  });

  group('Финансы: цели', () {
    Future<void> addWithoutCredit(ProviderContainer c) async {
      final repo = c.read(financeRepositoryProvider);
      // Те же данные, но цель считает только три счёта: «Есть» 329 600.
      final accounts = [
        for (final r in await c.read(syncStoreProvider).visibleRows('accounts'))
          Account.fromRow(r),
      ];
      await repo.createGoal(
        Goal(
          id: repo.newId(),
          name: 'Без кредитки',
          targetAmount: 40000000,
          formula: [
            GoalTerm(
              kind: GoalTermKind.accounts,
              accountIds: [
                for (final a in accounts)
                  if (a.kind != AccountKind.creditCard) a.id,
              ],
            ),
            const GoalTerm(kind: GoalTermKind.debtsToMe),
            const GoalTerm(kind: GoalTermKind.receivables),
          ],
        ),
      );
    }

    testWidgets('цели: случай Excel (телефон)', (tester) async {
      await pumpFinance(
        tester,
        seed: true,
        location: '/finance/goals',
        seedWith: addWithoutCredit,
      );
      await _shot(tester, 'finance_goals_phone');
    });

    testWidgets('цели: случай Excel (десктоп)', (tester) async {
      await pumpFinance(
        tester,
        seed: true,
        location: '/finance/goals',
        size: desktopSize,
        seedWith: addWithoutCredit,
      );
      await _shot(tester, 'finance_goals_desktop');
    });

    testWidgets('конструктор формулы (телефон)', (tester) async {
      await pumpFinance(tester, seed: true, location: '/finance/goals');
      await tapKey(tester, 'goals-add');
      await tester.enterText(find.byKey(const Key('goal-name')), 'Подушка');
      await tester.enterText(find.byKey(const Key('goal-target')), '400 000');
      await tester.pumpAndSettle();
      await _shot(tester, 'finance_goal_editor_phone');
    });
  });
}
