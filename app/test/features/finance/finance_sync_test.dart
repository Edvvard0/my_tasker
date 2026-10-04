import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы «Финансов» через общий стек синхронизации и фейковый сервер:
/// «сделал офлайн — появилась сеть — данные на втором устройстве».
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice phone;
  late FinanceDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(3000 + ++counter);
    phone = await FinanceDevice.create(server, clock: clock, newId: next);
    pc = await FinanceDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
    // Ни одна операция не отклонена сервером.
    expect((await phone.device.store.outboxSummary()).rejected, 0);
    expect((await pc.device.store.outboxSummary()).rejected, 0);
  }

  Future<List<T>> read<T>(
    FinanceDevice d,
    String table,
    T Function(Map<String, Object?>) parse,
  ) async => [
    for (final r in await d.device.store.visibleRows(table)) parse(r),
  ];

  Future<String> account(
    FinanceDevice d,
    String name,
    int opening, {
    AccountKind kind = AccountKind.debitCard,
  }) async {
    final id = d.finance.newId();
    await d.finance.createAccount(
      Account(
        id: id,
        name: name,
        kind: kind,
        openingBalance: opening,
        openingDate: '2026-01-01',
      ),
    );
    return id;
  }

  test('реестр: семь таблиц «Финансов», родители раньше детей', () {
    final names = [for (final s in registeredSyncTables) s.name];
    for (final name in [
      'accounts',
      'categories',
      'transactions',
      'balance_checkpoints',
      'debts',
      'debt_repayments',
      'goals',
    ]) {
      expect(names, contains(name));
    }
    expect(names.indexOf('accounts'), lessThan(names.indexOf('transactions')));
    expect(names.indexOf('debts'), lessThan(names.indexOf('debt_repayments')));
    // Порядок как на сервере (`FINANCE_TABLES`).
    final order = [
      for (final n in names)
        if ([
          'accounts',
          'categories',
          'transactions',
          'balance_checkpoints',
          'debts',
          'debt_repayments',
          'goals',
        ].contains(n))
          n,
    ];
    expect(order, [
      'accounts',
      'categories',
      'transactions',
      'balance_checkpoints',
      'debts',
      'debt_repayments',
      'goals',
    ]);
    // Реестр собирается без ошибок (родители зарегистрированы).
    SyncRegistry(registeredSyncTables);
  });

  test('офлайн на телефоне: счета, операции, перевод, сверка, долг, цель '
      'доезжают до ПК', () async {
    phone.device.remote.faults.offline = true;
    final bank = await account(phone, 'Т-Банк', 11200000);
    final savings = await account(phone, 'ВТБ', 300000);
    await phone.finance.seedPresetCategories();
    final spend = phone.finance.newId();
    await phone.finance.createTransaction(
      FinTransaction(
        id: spend,
        kind: TxKind.expense,
        accountId: bank,
        amount: 424990,
        occurredAt: DateTime.utc(2026, 9, 30, 20, 59, 59),
        categoryId: categoryPresetId('expense.groceries'),
        merchant: 'Пятёрочка',
        comment: 'молоко',
      ),
    );
    final transfer = phone.finance.newId();
    await phone.finance.createTransaction(
      FinTransaction(
        id: transfer,
        kind: TxKind.transfer,
        accountId: bank,
        toAccountId: savings,
        amount: 500000,
        occurredAt: DateTime.utc(2026, 10, 1, 9),
      ),
    );
    final checkpoint = await phone.finance.reconcile(
      accountId: bank,
      actualBalance: 10500000,
      checkedAt: DateTime.utc(2026, 10, 2, 9),
      note: 'банк',
    );
    final debtId = phone.finance.newId();
    await phone.finance.createDebt(
      Debt(
        id: debtId,
        direction: DebtDirection.owedToMe,
        counterparty: 'Паша',
        amount: 750000,
        debtDate: '2026-09-01',
        dueDate: '2026-10-15',
      ),
    );
    await phone.finance.repayDebt(
      debt: (await phone.finance.getDebt(debtId))!,
      amount: 150000,
      repaidOn: '2026-10-03',
      accountId: savings,
    );
    final goalId = phone.finance.newId();
    await phone.finance.createGoal(
      Goal(
        id: goalId,
        name: 'Подушка',
        targetAmount: 40000000,
        deadlineDate: '2026-11-15',
        formula: [
          ...defaultGoalFormula(),
          const GoalTerm(kind: GoalTermKind.myDebts, plus: false),
        ],
      ),
    );
    phone.device.remote.faults.offline = false;
    await syncBoth();

    final accounts = await read(pc, 'accounts', Account.fromRow);
    expect(accounts.map((a) => a.name), containsAll(['Т-Банк', 'ВТБ']));
    expect(await read(pc, 'categories', FinCategory.fromRow), hasLength(28));
    final txs = await read(pc, 'transactions', FinTransaction.fromRow);
    // Расход, перевод и доход от возврата долга.
    expect(txs, hasLength(3));
    final pcSpend = txs.firstWhere((t) => t.id == spend);
    expect(pcSpend.amount, 424990);
    expect(pcSpend.merchant, 'Пятёрочка');
    // 30 сентября 20:59:59Z — ещё сентябрь по Москве.
    expect(moscowDay(pcSpend.occurredAt), '2026-09-30');
    final pcTransfer = txs.firstWhere((t) => t.id == transfer);
    expect(pcTransfer.toAccountId, savings);
    expect(pcTransfer.categoryId, isNull);
    final cps = await read(
      pc,
      'balance_checkpoints',
      BalanceCheckpoint.fromRow,
    );
    expect(cps.single.id, checkpoint);
    expect(cps.single.actualBalance, 10500000);
    final debts = await read(pc, 'debts', Debt.fromRow);
    final repayments = await read(pc, 'debt_repayments', DebtRepayment.fromRow);
    expect(debts.single.dueDate, '2026-10-15');
    expect(repayments.single.transactionId, isNotNull);
    expect(debtsSummary(debts, repayments).owedToMe, 600000);
    final goal = (await read(pc, 'goals', Goal.fromRow)).single;
    expect(goal.formula.map((t) => t.kind), [
      GoalTermKind.allAccounts,
      GoalTermKind.debtsToMe,
      GoalTermKind.receivables,
      GoalTermKind.myDebts,
    ]);
    expect(goal.formula.last.plus, isFalse);
    expect(goal.formula[2].clientIds, isNull);
    // Балансы на обоих устройствах совпадают.
    final phoneAccounts = await read(phone, 'accounts', Account.fromRow);
    final phoneTxs = await read(phone, 'transactions', FinTransaction.fromRow);
    final phoneCps = await read(
      phone,
      'balance_checkpoints',
      BalanceCheckpoint.fromRow,
    );
    expect(
      accountBalances(accounts, txs, cps).total,
      accountBalances(phoneAccounts, phoneTxs, phoneCps).total,
    );
    expect(server.snapshot('transactions'), hasLength(3));
  });

  test('случай Excel через строки, которые вытянуло второе устройство: Есть '
      '329 600 → 454 600, не хватает −54 600', () async {
    final cash = await account(
      phone,
      'Наличные',
      5400000,
      kind: AccountKind.cash,
    );
    final bank = await account(phone, 'Т-Банк', 17400000);
    final savings = await account(
      phone,
      'ВТБ',
      800000,
      kind: AccountKind.savings,
    );
    for (final (who, amount) in [
      ('Паша', 750000),
      ('Маша', 260000),
      ('Саша', 300000),
    ]) {
      await phone.finance.createDebt(
        Debt(
          id: phone.finance.newId(),
          direction: DebtDirection.owedToMe,
          counterparty: who,
          amount: amount,
          debtDate: '2026-09-01',
        ),
      );
    }
    final roma = phone.work.work.newId();
    await phone.work.work.createPerson(
      WorkPerson(id: roma, name: 'Рома', role: PersonRole.client),
    );
    for (final (title, base) in [
      ('Проект 1', 2000000),
      ('Проект 2', 6050000),
    ]) {
      await phone.work.work.createProject(
        WorkProject(
          id: phone.work.work.newId(),
          title: title,
          clientId: roma,
          status: ProjectStatus.active,
          baseAmount: base,
        ),
      );
    }
    final goalId = phone.finance.newId();
    await phone.finance.createGoal(
      Goal(
        id: goalId,
        name: 'Подушка',
        targetAmount: 40000000,
        formula: [
          GoalTerm(
            kind: GoalTermKind.accounts,
            accountIds: [cash, bank, savings],
          ),
          const GoalTerm(kind: GoalTermKind.debtsToMe),
          const GoalTerm(kind: GoalTermKind.receivables),
        ],
      ),
    );
    await syncBoth();

    Future<GoalProgress> progress({String? goal}) async {
      final goals = await read(pc, 'goals', Goal.fromRow);
      return goalProgress(
        goals.firstWhere((g) => g.id == (goal ?? goalId)),
        accounts: await read(pc, 'accounts', Account.fromRow),
        transactions: await read(pc, 'transactions', FinTransaction.fromRow),
        checkpoints: await read(
          pc,
          'balance_checkpoints',
          BalanceCheckpoint.fromRow,
        ),
        debts: await read(pc, 'debts', Debt.fromRow),
        repayments: await read(pc, 'debt_repayments', DebtRepayment.fromRow),
        projects: await read(pc, 'projects', WorkProject.fromRow),
        changeRequests: await read(
          pc,
          'change_requests',
          ChangeRequest.fromRow,
        ),
        allocations: await read(pc, 'payment_allocations', Allocation.fromRow),
      );
    }

    var p = await progress();
    expect(p.have, 32960000);
    expect(p.missing, 7040000);
    expect(p.reached, isFalse);

    // Кредитка 125 000 как счёт в общем балансе и формула по умолчанию.
    await account(phone, 'Кредитка', 12500000, kind: AccountKind.creditCard);
    final defaultGoal = phone.finance.newId();
    await phone.finance.createGoal(
      Goal(
        id: defaultGoal,
        name: 'По умолчанию',
        targetAmount: 40000000,
        formula: defaultGoalFormula(),
      ),
    );
    await syncBoth();
    p = await progress(goal: defaultGoal);
    expect(p.have, 45460000);
    expect(p.missing, -5460000);
    expect(p.reached, isTrue);
    expect(p.surplus, 5460000);
    expect(p.progressBp, 11365);
  });

  test('удаление счёта скрывает его операции, а также переводы с него и на '
      'него и сверки; восстановление возвращает всё', () async {
    final a = await account(phone, 'А', 100000);
    final b = await account(phone, 'Б', 100000);
    final c = await account(phone, 'В', 100000);
    Future<String> tx(
      TxKind kind,
      String from, {
      String? to,
      int amount = 1000,
    }) async {
      final id = phone.finance.newId();
      await phone.finance.createTransaction(
        FinTransaction(
          id: id,
          kind: kind,
          accountId: from,
          toAccountId: to,
          amount: amount,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
        ),
      );
      return id;
    }

    final own = await tx(TxKind.expense, a);
    final outOfA = await tx(TxKind.transfer, a, to: c);
    final intoA = await tx(TxKind.transfer, b, to: a);
    final other = await tx(TxKind.expense, b);
    final unrelated = await tx(TxKind.transfer, b, to: c);
    await phone.finance.reconcile(accountId: a, actualBalance: 1);
    await syncBoth();
    expect(
      (await read(pc, 'transactions', FinTransaction.fromRow)).map((t) => t.id),
      containsAll([own, outOfA, intoA, other, unrelated]),
    );

    await phone.finance.deleteAccount(a);
    await syncBoth();
    final left = (await read(
      pc,
      'transactions',
      FinTransaction.fromRow,
    )).map((t) => t.id).toSet();
    expect(left, {other, unrelated});
    expect(
      await read(pc, 'balance_checkpoints', BalanceCheckpoint.fromRow),
      isEmpty,
    );
    // Общий баланс без счёта А: переводы на него и с него исчезли.
    final accounts = await read(pc, 'accounts', Account.fromRow);
    expect(accounts.map((x) => x.id), unorderedEquals([b, c]));
    final total = accountBalances(
      accounts,
      await read(pc, 'transactions', FinTransaction.fromRow),
      const [],
    );
    expect(total.of(b), 100000 - 1000 - 1000);
    expect(total.of(c), 100000 + 1000);

    await phone.finance.restoreAccount(a);
    await syncBoth();
    expect(
      (await read(pc, 'transactions', FinTransaction.fromRow)).map((t) => t.id),
      containsAll([own, outOfA, intoA]),
    );
    expect(
      await read(pc, 'balance_checkpoints', BalanceCheckpoint.fromRow),
      hasLength(1),
    );
  });

  test('удаление счёта-получателя скрывает перевод, счёт-отправитель '
      'остаётся с остальной историей', () async {
    final a = await account(phone, 'А', 100000);
    final b = await account(phone, 'Б', 100000);
    final transfer = phone.finance.newId();
    await phone.finance.createTransaction(
      FinTransaction(
        id: transfer,
        kind: TxKind.transfer,
        accountId: a,
        toAccountId: b,
        amount: 5000,
        occurredAt: DateTime.utc(2026, 10, 1, 9),
      ),
    );
    final own = phone.finance.newId();
    await phone.finance.createTransaction(
      FinTransaction(
        id: own,
        kind: TxKind.expense,
        accountId: a,
        amount: 100,
        occurredAt: DateTime.utc(2026, 10, 1, 9),
      ),
    );
    await syncBoth();
    await phone.finance.deleteAccount(b);
    await syncBoth();
    for (final d in [phone, pc]) {
      final ids = (await read(
        d,
        'transactions',
        FinTransaction.fromRow,
      )).map((t) => t.id);
      expect(ids, [own]);
    }
  });

  test(
    'удаление долга скрывает погашения; операции с debt_id остаются',
    () async {
      final a = await account(phone, 'А', 100000);
      final debtId = phone.finance.newId();
      await phone.finance.createDebt(
        Debt(
          id: debtId,
          direction: DebtDirection.owedToMe,
          counterparty: 'Рома',
          amount: 10000,
          debtDate: '2026-10-01',
        ),
        accountId: a,
      );
      await phone.finance.repayDebt(
        debt: (await phone.finance.getDebt(debtId))!,
        amount: 4000,
        repaidOn: '2026-10-02',
        accountId: a,
      );
      await syncBoth();
      expect(
        await read(pc, 'debt_repayments', DebtRepayment.fromRow),
        hasLength(1),
      );
      await phone.finance.deleteDebt(debtId);
      await syncBoth();
      expect(await read(pc, 'debts', Debt.fromRow), isEmpty);
      expect(await read(pc, 'debt_repayments', DebtRepayment.fromRow), isEmpty);
      // Деньги реально двигались: обе операции с debt_id остались.
      final txs = await read(pc, 'transactions', FinTransaction.fromRow);
      expect(txs, hasLength(2));
      expect(txs.every((t) => t.debtId == debtId), isTrue);
      await phone.finance.restoreDebt(debtId);
      await syncBoth();
      expect(
        await read(pc, 'debt_repayments', DebtRepayment.fromRow),
        hasLength(1),
      );
    },
  );

  test('предустановленные категории: два устройства засеяли офлайн — строка '
      'одна, дублей нет; удалённая не воскресает', () async {
    phone.device.remote.faults.offline = true;
    pc.device.remote.faults.offline = true;
    expect(await phone.finance.seedPresetCategories(), 28);
    expect(await pc.finance.seedPresetCategories(), 28);
    phone.device.remote.faults.offline = false;
    pc.device.remote.faults.offline = false;
    await syncBoth();
    for (final d in [phone, pc]) {
      final rows = await read(d, 'categories', FinCategory.fromRow);
      expect(rows, hasLength(28));
      expect(
        {for (final r in rows) r.id},
        {for (final p in categoryPresets) p.id},
      );
    }
    expect(server.snapshot('categories'), hasLength(28));

    // Пользователь удалил предустановленную категорию на телефоне.
    final other = categoryPresetId('expense.other');
    await phone.finance.deleteCategory(other);
    await syncBoth();
    expect(await pc.finance.seedPresetCategories(), 0);
    expect(await phone.finance.seedPresetCategories(), 0);
    expect(await read(pc, 'categories', FinCategory.fromRow), hasLength(27));
  });

  test('одновременная правка разных полей операции сливается', () async {
    final a = await account(phone, 'А', 100000);
    final id = phone.finance.newId();
    await phone.finance.createTransaction(
      FinTransaction(
        id: id,
        kind: TxKind.expense,
        accountId: a,
        amount: 1000,
        occurredAt: DateTime.utc(2026, 10, 1, 9),
        merchant: 'Было',
      ),
    );
    await syncBoth();
    clock.advance(const Duration(seconds: 5));
    await phone.finance.updateTransaction(
      (await phone.finance.getTransaction(id))!.copyWith(merchant: 'Стало'),
    );
    clock.advance(const Duration(seconds: 5));
    await pc.finance.updateTransaction(
      (await pc.finance.getTransaction(id))!.copyWith(amount: 2500),
    );
    await syncBoth();
    for (final d in [phone, pc]) {
      final tx = (await d.finance.getTransaction(id))!;
      expect(tx.merchant, 'Стало');
      expect(tx.amount, 2500);
    }
  });

  test(
    'подтверждение черновика на одном устройстве даёт баланс на другом',
    () async {
      final a = await account(phone, 'А', 100000);
      final id = phone.finance.newId();
      await phone.finance.createTransaction(
        FinTransaction(
          id: id,
          kind: TxKind.expense,
          accountId: a,
          amount: 7000,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
          status: TxStatus.draft,
        ),
      );
      await syncBoth();
      Future<int> balanceOnPc() async => accountBalances(
        await read(pc, 'accounts', Account.fromRow),
        await read(pc, 'transactions', FinTransaction.fromRow),
        const [],
      ).of(a);
      expect(await balanceOnPc(), 100000);
      await phone.finance.confirmTransaction(id);
      await syncBoth();
      expect(await balanceOnPc(), 93000);
    },
  );
}
