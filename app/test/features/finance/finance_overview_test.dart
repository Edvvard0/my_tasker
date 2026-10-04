import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  group('«Финансы»: обзор', () {
    testWidgets('пусто: подсказка «Начните со счёта», ссылки есть', (
      tester,
    ) async {
      await pumpFinance(tester);
      expect(find.byKey(const Key('finance-empty')), findsOneWidget);
      expect(find.text('Начните со счёта'), findsOneWidget);
      expect(find.byKey(const Key('finance-link-categories')), findsOneWidget);

      await tapKey(tester, 'finance-add-account');
      await tester.enterText(find.byKey(const Key('account-name')), 'Наличные');
      await tester.enterText(find.byKey(const Key('account-opening')), '1 500');
      await tapKey(tester, 'account-save');
      expect(find.byKey(const Key('finance-empty')), findsNothing);
      expect(_textOf(tester, 'finance-total'), nb('1 500 ₽'));
    });

    testWidgets('телефон: баланс, плитки, цель, месяц, последние операции', (
      tester,
    ) async {
      await pumpFinance(tester, seed: true);
      // Общий баланс: 236 000 + кредитка 125 000.
      expect(_textOf(tester, 'finance-total'), nb('361 000 ₽'));
      // Плитки: мне должны 13 100 (3 долга), кредитка 125 000, ожидается 80 500.
      expect(find.text(nb('13,1к ₽')), findsOneWidget);
      expect(find.text('3 долга'), findsOneWidget);
      expect(find.text(nb('125к ₽')), findsOneWidget);
      expect(find.text('Кредитка'), findsWidgets);
      expect(find.text(nb('80,5к ₽')), findsOneWidget);
      expect(find.text('2 заказчика'), findsOneWidget);
      // Цель: Excel — Есть 454 600, цель достигнута с запасом 54 600.
      expect(
        find.text('Есть ${nb('454 600 ₽')} из ${nb('400 000 ₽')}'),
        findsOneWidget,
      );
      expect(find.text('Цель достигнута +${nb('54 600 ₽')}'), findsOneWidget);
      expect(find.text('113,6 %'), findsOneWidget);
      // Месяц: доход 85 000, расход 11 500 (черновик и перевод не входят).
      expect(
        _textOf(tester, 'finance-month-sums'),
        '+${nb('85 000 ₽')}  -${nb('11 500 ₽')}',
      );
      // Категории месяца: продукты 6 500 — первая.
      expect(find.text('Продукты'), findsOneWidget);
      expect(find.text(nb('6 500 ₽')), findsWidgets);
      // Последние операции: свежая — черновик, с пометкой.
      expect(find.text('ЧЕРНОВИК'), findsWidgets);
      expect(find.text('Черновик из уведомления'), findsOneWidget);
    });

    testWidgets('переходы в подразделы', (tester) async {
      final container = await pumpFinance(tester, seed: true);
      final router = container.read(routerProvider);
      for (final (key, key2) in [
        ('finance-link-accounts', 'accounts-screen'),
        ('finance-link-transactions', 'transactions-screen'),
        ('finance-link-categories', 'categories-screen'),
        ('finance-link-debts', 'debts-screen'),
        ('finance-link-goals', 'goals-screen'),
        ('finance-link-analytics', 'analytics-screen'),
        ('finance-link-work', 'work-income-screen'),
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(key2)), findsOneWidget, reason: key);
        router.pop();
        await tester.pumpAndSettle();
      }
      // Плитки ведут туда же.
      for (final (key, key2) in [
        ('kpi-owed', 'debts-screen'),
        ('kpi-credit', 'accounts-screen'),
        ('kpi-expected', 'work-income-screen'),
        ('finance-hero', 'accounts-screen'),
        ('finance-months', 'analytics-screen'),
        ('finance-categories-card', 'analytics-screen'),
        ('finance-all-tx', 'transactions-screen'),
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(key2)), findsOneWidget, reason: key);
        router.pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('десктоп: те же блоки в две колонки', (tester) async {
      await pumpFinance(tester, seed: true, size: desktopSize);
      expect(_textOf(tester, 'finance-total'), nb('361 000 ₽'));
      expect(find.byKey(const Key('kpi-owed')), findsOneWidget);
      expect(find.byKey(const Key('finance-months')), findsOneWidget);
      expect(find.byKey(const Key('finance-categories-card')), findsOneWidget);
      expect(find.byKey(const Key('finance-all-tx')), findsOneWidget);
    });

    testWidgets('«Требуют проверки» ведёт в ленту с фильтром', (tester) async {
      await pumpFinance(tester, seed: true);
      expect(find.byKey(const Key('finance-link-unconfirmed')), findsOneWidget);
      await tapKey(tester, 'finance-link-unconfirmed');
      expect(find.byKey(const Key('transactions-screen')), findsOneWidget);
      expect(find.text('Черновик из уведомления'), findsOneWidget);
      // Остальных операций в ленте нет.
      expect(find.text('Пятёрочка'), findsNothing);
    });

    testWidgets('нет цели: предложение задать; нет операций и расходов', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        seedWith: (c) async {
          await c
              .read(financeRepositoryProvider)
              .createAccount(
                const Account(
                  id: '01900000-0000-7000-8000-000000000001',
                  name: 'Нал',
                  kind: AccountKind.cash,
                  openingBalance: 100,
                  openingDate: '2026-01-01',
                ),
              );
        },
      );
      expect(find.byKey(const Key('finance-no-goal')), findsOneWidget);
      expect(find.byKey(const Key('finance-no-tx')), findsOneWidget);
      expect(find.byKey(const Key('finance-no-expenses')), findsOneWidget);
      await tapKey(tester, 'finance-add-goal');
      expect(find.byKey(const Key('goals-screen')), findsOneWidget);
    });

    testWidgets('предупреждения целостности показываются на обзоре', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        seed: true,
        seedWith: (c) async {
          final repo = c.read(financeRepositoryProvider);
          final store = c.read(syncStoreProvider);
          final bank = Account.fromRow(
            (await store.visibleRows('accounts'))
                .firstWhere((r) => r['name'] == 'Т-Банк'),
          );
          // Доход привязан к платежу Работы на сумму больше платежа.
          final payment = Payment.fromRow(
            (await store.visibleRows('payments')).first,
          );
          await repo.reflectWorkPayment(
            paymentId: payment.id,
            accountId: bank.id,
            amount: payment.amount + 100,
            occurredAt: payment.paidAt,
          );
        },
      );
      expect(find.byKey(const Key('finance-problems')), findsOneWidget);
      expect(
        find.textContaining('привязано доходов больше его суммы'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Нашлись расхождения в данных (1)'),
        findsOneWidget,
      );
    });

    testWidgets('ошибка чтения — карточка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        overrides: [
          accountsProvider.overrideWith(
            (ref) => Stream<List<Account>>.error(StateError('сбой')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pump();
    });

    testWidgets('«+» в оболочке: «Операция» открывает форму', (tester) async {
      await pumpFinance(tester, seed: true);
      await tapKey(tester, 'create-fab');
      await tapKey(tester, 'quick-create-transaction');
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect(find.text('Новая операция'), findsWidgets);
    });

    testWidgets('кнопка «Новая операция» в верхней панели', (tester) async {
      await pumpFinance(tester, seed: true);
      await tapKey(tester, 'finance-add-tx');
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('bootstrap: до первой синхронизации категории не засеваются, '
        'после успешной — засеваются (после удаления не воскресают)', (
      tester,
    ) async {
      final container = await pumpFinance(tester);
      final store = container.read(syncStoreProvider);
      final repo = container.read(financeRepositoryProvider);
      Future<int> categories() async =>
          (await store.visibleRows('categories')).length;
      final counts = await tester.runAsync(() async {
        await container.read(financeBootstrapProvider.future);
        final before = await categories();
        await store.markSuccess();
        await container.refresh(financeBootstrapProvider.future);
        final seeded = await categories();
        // Пользователь удалил категорию: следующий засев её не возвращает.
        await repo.deleteCategory(categoryPresetId('expense.other'));
        await container.refresh(financeBootstrapProvider.future);
        return [before, seeded, await categories()];
      });
      expect(counts, [0, 28, 27]);
    });
  });
}
