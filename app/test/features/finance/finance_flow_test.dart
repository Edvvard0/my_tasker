import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/finance_ui_env.dart';

const _nb = ' ';

void main() {
  testWidgets('счёт -> расход -> балансы меняются -> сверка', (tester) async {
    final c = await pumpFinance(tester);
    expect(find.byKey(const Key('finance-empty')), findsOneWidget);

    // 1. Счёт «Копилка» с 1 000 ₽.
    await tester.tap(find.byKey(const Key('finance-add-account')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'acc-kind-cash');
    await enter(tester, 'acc-name', 'Копилка');
    await enter(tester, 'acc-opening', '1000');
    await tapKey(tester, 'acc-save');
    await settleDb(tester);
    expect(find.byKey(const Key('finance-empty')), findsNothing);
    expect(textOf(tester, 'finance-total'), '1${_nb}000$_nb₽');
    expect(find.text('Копилка'), findsWidgets);

    // 2. Расход 250 ₽ через быстрое действие.
    await tester.tap(find.byKey(const Key('finance-quick-expense')));
    await tester.pumpAndSettle();
    await enter(tester, 'tx-amount', '250');
    await enter(tester, 'tx-merchant', 'Кофе');
    await tapKey(tester, 'tx-save');
    await settleDb(tester);
    expect(textOf(tester, 'finance-total'), '750$_nb₽');
    expect(find.text('−250$_nb₽'), findsOneWidget);

    // 3. Доход 100 ₽ через «+» раздела.
    await tester.tap(find.byKey(const Key('create-fab')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'tx-kind-income');
    await enter(tester, 'tx-amount', '100');
    await tapKey(tester, 'tx-save');
    await settleDb(tester);
    expect(textOf(tester, 'finance-total'), '850$_nb₽');
    expect(find.text('+100$_nb₽'), findsOneWidget);

    // 4. Экран счёта: баланс, операции.
    final account = (await tester.runAsync(() => financeRepo(c).accounts()))!
        .single;
    await tester.tap(find.byKey(Key('account-tile-${account.id}')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'account-balance'), '850$_nb₽');
    expect(find.text('Кофе'), findsOneWidget);

    // 5. Сверка: в банке 900 ₽ — на 50 ₽ больше.
    await tester.tap(find.byKey(const Key('account-reconcile')));
    await tester.pumpAndSettle();
    await enter(tester, 'reconcile-amount', '900');
    await tapKey(tester, 'reconcile-save');
    await settleDb(tester);
    expect(find.text('В банке больше на 50$_nb₽'), findsWidgets);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'account-balance'), '900$_nb₽');
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'finance-total'), '900$_nb₽');
  });

  testWidgets('корзина: счета, операции, категории и сверки видны и '
      'восстанавливаются', (tester) async {
    late FinanceDemo demo;
    late String checkpointId;
    late String transferId;
    late String cafeId;
    final c = await pumpFinance(
      tester,
      seedWith: (c) async {
        demo = await seedFinanceDemo(c);
        final repo = financeRepo(c);
        checkpointId = (await repo.reconcile(
          accountId: demo.tbank,
          actualBalance: 19000000,
          at: DateTime.utc(2026, 9, 30, 7),
        )).checkpointId;
        transferId = (await repo.transactions())
            .firstWhere((t) => t.isTransfer)
            .id;
        cafeId = (await repo.categories())
            .firstWhere((x) => x.name == 'Кафе и рестораны')
            .id;
        await repo.deleteTransaction(demo.shop);
        await repo.deleteCategory(cafeId);
        await repo.deleteCheckpoint(checkpointId);
        await repo.deleteAccount(demo.cash);
        await repo.deleteAccount(demo.vtb);
      },
    );
    await goTo(tester, '/settings/trash');
    await settleDb(tester);
    expect(find.byKey(const Key('trash-list')), findsOneWidget);
    // Операция, категория, сверка и два счёта — с названиями из реестра.
    expect(find.text('Расход 1${_nb}249,90$_nb₽ · Пятёрочка'), findsOneWidget);
    expect(find.text('Кафе и рестораны'), findsOneWidget);
    expect(find.textContaining('Сверка 2026-09-30'), findsOneWidget);
    expect(find.text('Наличные'), findsOneWidget);
    expect(find.text('ВТБ Мир'), findsOneWidget);
    expect(find.textContaining('Операция · удалено'), findsOneWidget);
    expect(find.textContaining('Категория · удалено'), findsOneWidget);
    expect(find.textContaining('Сверка баланса · удалено'), findsOneWidget);
    expect(find.textContaining('Счёт · удалено'), findsNWidgets(2));
    // Перевод ушёл вместе со счётом «Наличные» и отдельной строки не имеет.
    expect(find.byKey(Key('trash-transactions-$transferId')), findsNothing);

    for (final id in [demo.shop, checkpointId, cafeId, demo.cash, demo.vtb]) {
      await tester.tap(find.byKey(Key('restore-$id')));
      await settleDb(tester);
    }

    // Всё вернулось: счета, операции, сверка, перевод вместе со счётом.
    final repo = financeRepo(c);
    final accounts = (await tester.runAsync(repo.accounts))!;
    expect(accounts.map((a) => a.id), containsAll([demo.cash, demo.vtb]));
    final txs = (await tester.runAsync(repo.transactions))!;
    expect(txs.map((t) => t.id), containsAll([demo.shop, transferId]));
    final cps = (await tester.runAsync(
      () => repo.checkpoints(accountId: demo.tbank),
    ))!;
    expect(cps.map((x) => x.id), [checkpointId]);
    final categories = (await tester.runAsync(repo.categories))!;
    expect(categories.map((x) => x.id), contains(cafeId));
    expect(find.byKey(const Key('trash-list')), findsNothing);
    expect(find.text('Корзина пуста'), findsOneWidget);
    // Сверка 7:00Z — истина на свой момент: баланс Т-Банка равен факту, а
    // восстановленная раньше неё «Пятёрочка» его не меняет.
    await goTo(tester, '/finance');
    expect(
      textOf(tester, 'account-balance-${demo.tbank}'),
      '190${_nb}000$_nb₽',
    );
  });
}
