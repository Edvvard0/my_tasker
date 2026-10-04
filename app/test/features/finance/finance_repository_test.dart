import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/calendar_env.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

Matcher _invalid([String? part]) => throwsA(
  isA<ValidationError>().having(
    (e) => e.message,
    'message',
    part == null ? isNotEmpty : contains(part),
  ),
);

void main() {
  late ManualClock clock;
  late FinanceDevice dev;
  late FinanceRepository repo;
  var counter = 0;

  setUp(() async {
    // 5 октября 2026, 12:00 по Москве.
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    counter = 0;
    dev = await FinanceDevice.create(
      appServer(clock),
      clock: clock,
      newId: () => _uuid(7000 + ++counter),
    );
    repo = dev.finance;
  });
  tearDown(() => dev.close());

  Future<String> account({
    String name = 'Т-Банк',
    AccountKind kind = AccountKind.debitCard,
    int opening = 100000,
    bool inTotal = true,
  }) async {
    final id = repo.newId();
    await repo.createAccount(
      Account(
        id: id,
        name: name,
        kind: kind,
        openingBalance: opening,
        openingDate: '2026-01-01',
        includeInTotal: inTotal,
      ),
    );
    return id;
  }

  Future<List<FinTransaction>> txs() async => [
    for (final r in await dev.device.store.visibleRows('transactions'))
      FinTransaction.fromRow(r),
  ];

  Future<int> balance(String accountId) async {
    final accounts = [
      for (final r in await dev.device.store.visibleRows('accounts'))
        Account.fromRow(r),
    ];
    final cps = [
      for (final r in await dev.device.store.visibleRows('balance_checkpoints'))
        BalanceCheckpoint.fromRow(r),
    ];
    return accountBalances(accounts, await txs(), cps).of(accountId);
  }

  group('счета', () {
    test('создание, правка (уходят только изменённые поля), архив', () async {
      final id = await account();
      final created = (await repo.getAccount(id))!;
      expect(created.name, 'Т-Банк');
      expect(created.includeInTotal, isTrue);

      await repo.updateAccount(created.copyWith(name: '  Тинькофф  '));
      expect((await repo.getAccount(id))!.name, 'Тинькофф');
      // Без изменений правка ничего не отправляет.
      final before = (await dev.device.store.outbox()).length;
      await repo.updateAccount((await repo.getAccount(id))!);
      expect((await dev.device.store.outbox()).length, before);

      await repo.setAccountArchived(id, archived: true);
      expect((await repo.getAccount(id))!.archived, isTrue);
      await repo.setAccountArchived(id, archived: false);
      expect((await repo.getAccount(id))!.archived, isFalse);
    });

    test(
      'проверки: пустое имя, цифры карты у наличных, неизвестный счёт',
      () async {
        await expectLater(
          repo.createAccount(
            Account(
              id: repo.newId(),
              name: ' ',
              kind: AccountKind.cash,
              openingBalance: 0,
              openingDate: '2026-01-01',
            ),
          ),
          _invalid('пустым'),
        );
        await expectLater(
          repo.createAccount(
            Account(
              id: repo.newId(),
              name: 'Нал',
              kind: AccountKind.cash,
              cardLast4: '1234',
              openingBalance: 0,
              openingDate: '2026-01-01',
            ),
          ),
          _invalid('карты'),
        );
        await expectLater(
          repo.updateAccount(
            const Account(
              id: 'нет',
              name: 'x',
              kind: AccountKind.cash,
              openingBalance: 0,
              openingDate: '2026-01-01',
            ),
          ),
          throwsStateError,
        );
      },
    );

    test('удаление и восстановление счёта', () async {
      final id = await account();
      await repo.deleteAccount(id);
      expect(await dev.device.store.visibleRows('accounts'), isEmpty);
      await repo.restoreAccount(id);
      expect(await dev.device.store.visibleRows('accounts'), hasLength(1));
    });
  });

  group('категории', () {
    test('двухуровневость: подкатегория подкатегории — ошибка', () async {
      final top = repo.newId();
      await repo.createCategory(
        FinCategory(id: top, name: 'Еда', kind: CategoryKind.expense),
      );
      final child = repo.newId();
      await repo.createCategory(
        FinCategory(
          id: child,
          name: 'Кафе',
          kind: CategoryKind.expense,
          parentId: top,
        ),
      );
      await expectLater(
        repo.createCategory(
          FinCategory(
            id: repo.newId(),
            name: 'Бизнес-ланч',
            kind: CategoryKind.expense,
            parentId: child,
          ),
        ),
        _invalid('верхнего уровня'),
      );
      await expectLater(
        repo.createCategory(
          FinCategory(
            id: repo.newId(),
            name: 'Подарок',
            kind: CategoryKind.income,
            parentId: top,
          ),
        ),
        _invalid('того же вида'),
      );
      await expectLater(
        repo.updateCategory(
          (await repo.getCategory(top))!.copyWith(parentId: top),
        ),
        _invalid('своим родителем'),
      );
    });

    test('правка не отправляет system_key; удаление и возврат', () async {
      await repo.seedPresetCategories();
      final id = categoryPresetId('expense.groceries');
      final preset = (await repo.getCategory(id))!;
      expect(preset.systemKey, 'expense.groceries');
      await repo.updateCategory(preset.copyWith(name: 'Еда', icon: 'tag'));
      final changed = (await repo.getCategory(id))!;
      expect(changed.name, 'Еда');
      expect(changed.systemKey, 'expense.groceries');
      await repo.deleteCategory(id);
      await repo.restoreCategory(id);
      expect((await repo.getCategory(id))!.name, 'Еда');
    });

    test('засев: 28 категорий, подкатегории ссылаются на родителей; повтор '
        'ничего не создаёт; удалённая не воскресает', () async {
      expect(await repo.seedPresetCategories(), 28);
      expect(await repo.seedPresetCategories(), 0);
      final rows = await dev.device.store.visibleRows('categories');
      expect(rows, hasLength(28));
      final taxi = FinCategory.fromRow(
        rows.firstWhere((r) => r['system_key'] == 'expense.transport.taxi'),
      );
      expect(taxi.parentId, categoryPresetId('expense.transport'));
      expect(taxi.id, categoryPresetId('expense.transport.taxi'));
      expect(taxi.name, 'Такси');

      await repo.deleteCategory(categoryPresetId('expense.other'));
      expect(await repo.seedPresetCategories(), 0);
      expect(await dev.device.store.visibleRows('categories'), hasLength(27));
    });
  });

  group('операции', () {
    test('расход и доход двигают баланс; перевод — обе стороны', () async {
      final a = await account();
      final b = await account(name: 'Наличные', opening: 50000);
      await repo.createTransaction(
        FinTransaction(
          id: repo.newId(),
          kind: TxKind.expense,
          accountId: a,
          amount: 1000,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
          merchant: '  Пятёрочка ',
          comment: '',
        ),
      );
      await repo.createTransaction(
        FinTransaction(
          id: repo.newId(),
          kind: TxKind.income,
          accountId: a,
          amount: 5000,
          occurredAt: DateTime.utc(2026, 10, 2, 9),
        ),
      );
      await repo.createTransaction(
        FinTransaction(
          id: repo.newId(),
          kind: TxKind.transfer,
          accountId: a,
          toAccountId: b,
          amount: 20000,
          occurredAt: DateTime.utc(2026, 10, 3, 9),
        ),
      );
      expect(await balance(a), 100000 - 1000 + 5000 - 20000);
      expect(await balance(b), 70000);
      final list = await txs();
      // Строка нормализована: пробелы обрезаны, пустое — null.
      final expense = list.firstWhere((t) => t.kind == TxKind.expense);
      expect(expense.merchant, 'Пятёрочка');
      expect(expense.comment, isNull);
      // Перевод — одна строка.
      expect(list.where((t) => t.kind == TxKind.transfer), hasLength(1));
    });

    test('проверки: счёт не найден, перевод на тот же счёт', () async {
      final a = await account();
      await expectLater(
        repo.createTransaction(
          FinTransaction(
            id: repo.newId(),
            kind: TxKind.expense,
            accountId: 'нет',
            amount: 1,
            occurredAt: DateTime.utc(2026, 10),
          ),
        ),
        _invalid('Счёт не найден'),
      );
      await expectLater(
        repo.createTransaction(
          FinTransaction(
            id: repo.newId(),
            kind: TxKind.transfer,
            accountId: a,
            toAccountId: a,
            amount: 1,
            occurredAt: DateTime.utc(2026, 10),
          ),
        ),
        _invalid('разными'),
      );
      await repo.deleteAccount(a);
      await expectLater(
        repo.createTransaction(
          FinTransaction(
            id: repo.newId(),
            kind: TxKind.expense,
            accountId: a,
            amount: 1,
            occurredAt: DateTime.utc(2026, 10),
          ),
        ),
        _invalid('Счёт не найден'),
      );
    });

    test('черновик не двигает баланс, подтверждение — двигает', () async {
      final a = await account();
      final id = repo.newId();
      await repo.createTransaction(
        FinTransaction(
          id: id,
          kind: TxKind.expense,
          accountId: a,
          amount: 3000,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
          status: TxStatus.draft,
        ),
      );
      expect(await balance(a), 100000);
      await repo.confirmTransaction(id);
      expect(await balance(a), 97000);
      expect((await repo.getTransaction(id))!.status, TxStatus.confirmed);
    });

    test('правка меняет сумму и категорию; удаление и возврат', () async {
      final a = await account();
      final id = repo.newId();
      await repo.createTransaction(
        FinTransaction(
          id: id,
          kind: TxKind.expense,
          accountId: a,
          amount: 3000,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
        ),
      );
      final tx = (await repo.getTransaction(id))!;
      await repo.updateTransaction(tx.copyWith(amount: 4000, categoryId: 'c'));
      expect((await repo.getTransaction(id))!.amount, 4000);
      expect((await repo.getTransaction(id))!.categoryId, 'c');
      await repo.deleteTransaction(id);
      expect(await balance(a), 100000);
      await repo.restoreTransaction(id);
      expect(await balance(a), 96000);
      await expectLater(
        repo.updateTransaction(
          FinTransaction(
            id: 'нет',
            kind: TxKind.expense,
            accountId: a,
            amount: 1,
            occurredAt: DateTime.utc(2026, 10),
          ),
        ),
        throwsStateError,
      );
    });

    test(
      '«деньги по проекту пришли на карту»: доход со ссылкой на платёж',
      () async {
        final a = await account();
        final payment = _uuid(900);
        final id = await repo.reflectWorkPayment(
          paymentId: payment,
          accountId: a,
          amount: 2500000,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
          merchant: 'Рома',
        );
        final tx = (await repo.getTransaction(id))!;
        expect(tx.kind, TxKind.income);
        expect(tx.source, TxSource.workPayment);
        expect(tx.workPaymentId, payment);
        expect(tx.status, TxStatus.confirmed);
        // Категории «Доход с проектов» ещё нет — ссылка пустая.
        expect(tx.categoryId, isNull);
        await repo.seedPresetCategories();
        final id2 = await repo.reflectWorkPayment(
          paymentId: payment,
          accountId: a,
          amount: 100,
          occurredAt: DateTime.utc(2026, 10, 1, 9),
        );
        expect(
          (await repo.getTransaction(id2))!.categoryId,
          categoryPresetId('income.projects'),
        );
        final coverage = workPaymentCoverage([
          Payment(id: payment, paidAt: DateTime.utc(2026, 10), amount: 3000000),
        ], await txs());
        expect(coverage.single.linked, 2500100);
        expect(coverage.single.unlinked, 499900);
      },
    );
  });

  group('сверка баланса', () {
    test(
      'точка сверки заменяет расчётный баланс; операций не создаёт',
      () async {
        final a = await account();
        await repo.createTransaction(
          FinTransaction(
            id: repo.newId(),
            kind: TxKind.expense,
            accountId: a,
            amount: 10000,
            occurredAt: DateTime.utc(2026, 10, 1, 9),
          ),
        );
        expect(await balance(a), 90000);
        // 5 октября 12:00 МСК: в банке 91 000 (на 1 000 больше).
        final id = await repo.reconcile(
          accountId: a,
          actualBalance: 9100000 ~/ 100,
          note: '  Т-Банк  ',
        );
        expect(await balance(a), 91000);
        expect(await txs(), hasLength(1));
        final accounts = [
          for (final r in await dev.device.store.visibleRows('accounts'))
            Account.fromRow(r),
        ];
        final cps = [
          for (final r in await dev.device.store.visibleRows(
            'balance_checkpoints',
          ))
            BalanceCheckpoint.fromRow(r),
        ];
        expect(cps.single.id, id);
        expect(cps.single.note, 'Т-Банк');
        final gaps = adjustments(accounts.single, await txs(), cps);
        expect(gaps.single.expected, 90000);
        expect(gaps.single.adjustment, 1000);
        // Аналитика не изменилась.
        expect(monthlyTotals(await txs()).single.expense, 10000);
        expect(monthlyTotals(await txs()).single.income, 0);
        await repo.deleteCheckpoint(id);
        expect(await balance(a), 90000);
      },
    );

    test('неизвестный счёт — ошибка', () async {
      await expectLater(
        repo.reconcile(accountId: 'нет', actualBalance: 1),
        _invalid('Счёт не найден'),
      );
    });
  });

  group('долги', () {
    Future<String> debt({
      DebtDirection direction = DebtDirection.owedToMe,
      int amount = 100000,
      String? account,
    }) async {
      final id = repo.newId();
      await repo.createDebt(
        Debt(
          id: id,
          direction: direction,
          counterparty: ' Рома ',
          amount: amount,
          debtDate: '2026-10-01',
        ),
        accountId: account,
      );
      return id;
    }

    Future<List<DebtRepayment>> repayments() async => [
      for (final r in await dev.device.store.visibleRows('debt_repayments'))
        DebtRepayment.fromRow(r),
    ];

    test(
      'выдал в долг: расход со счёта с debt_id — в «расход» не входит',
      () async {
        final a = await account();
        final id = await debt(account: a);
        final list = await txs();
        expect(list.single.kind, TxKind.expense);
        expect(list.single.debtId, id);
        expect(list.single.merchant, 'Рома');
        expect(await balance(a), 0);
        expect(monthlyTotals(list), isEmpty);
      },
    );

    test('взял в долг: доход на счёт', () async {
      final a = await account();
      await debt(direction: DebtDirection.iOwe, account: a);
      expect((await txs()).single.kind, TxKind.income);
      expect(await balance(a), 200000);
    });

    test('частичные погашения; статус вычисляется; больше остатка — ошибка', () async {
      final a = await account();
      final id = await debt();
      var d = (await repo.getDebt(id))!;
      await repo.repayDebt(
        debt: d,
        amount: 40000,
        repaidOn: '2026-10-02',
        accountId: a,
        note: 'часть',
      );
      var summary = debtsSummary([d], await repayments());
      expect(summary.debts.single.status, DebtStatus.partial);
      expect(summary.owedToMe, 60000);
      // Деньги реально пришли на счёт: доход с debt_id и ссылкой из погашения.
      final repayment = (await repayments()).single;
      final linked = (await repo.getTransaction(repayment.transactionId!))!;
      expect(linked.kind, TxKind.income);
      expect(linked.debtId, id);
      expect(await balance(a), 140000);
      expect(monthlyTotals(await txs()), isEmpty);

      await expectLater(
        repo.repayDebt(debt: d, amount: 60001, repaidOn: '2026-10-03'),
        _invalid('больше остатка'),
      );
      // «Простил»: погашение без движения денег.
      await repo.repayDebt(debt: d, amount: 60000, repaidOn: '2026-10-03');
      d = (await repo.getDebt(id))!;
      summary = debtsSummary([d], await repayments());
      expect(summary.debts.single.status, DebtStatus.closed);
      expect(summary.owedToMe, 0);
      expect((await repayments()).last.transactionId, isNull);
      expect(await balance(a), 140000);
      await expectLater(
        repo.repayDebt(debt: d, amount: 1, repaidOn: '2026-10-04'),
        _invalid('больше остатка'),
      );
    });

    test('я вернул долг со счёта — расход с debt_id', () async {
      final a = await account();
      final id = await debt(direction: DebtDirection.iOwe);
      await repo.repayDebt(
        debt: (await repo.getDebt(id))!,
        amount: 25000,
        repaidOn: '2026-10-02',
        accountId: a,
      );
      expect((await txs()).single.kind, TxKind.expense);
      expect(await balance(a), 75000);
    });

    test(
      'правка и удаление долга (погашения скрываются), удаление погашения',
      () async {
        final id = await debt();
        final d = (await repo.getDebt(id))!;
        await repo.updateDebt(
          d.copyWith(amount: 120000, dueDate: '2026-11-01'),
        );
        expect((await repo.getDebt(id))!.amount, 120000);
        await repo.repayDebt(debt: d, amount: 100, repaidOn: '2026-10-02');
        final repayment = (await repayments()).single;
        expect((await repo.repaymentsOf(id)).single.id, repayment.id);
        await repo.deleteRepayment(repayment.id);
        expect(await repayments(), isEmpty);
        await repo.deleteDebt(id);
        expect(await dev.device.store.visibleRows('debts'), isEmpty);
        await repo.restoreDebt(id);
        expect(await dev.device.store.visibleRows('debts'), hasLength(1));
        await expectLater(
          repo.createDebt(
            Debt(
              id: repo.newId(),
              direction: DebtDirection.owedToMe,
              amount: 1,
              debtDate: '2026-10-01',
            ),
          ),
          _invalid('Укажите, кто'),
        );
        await expectLater(
          repo.updateDebt(
            const Debt(
              id: 'нет',
              direction: DebtDirection.owedToMe,
              amount: 1,
              debtDate: '2026-10-01',
              counterparty: 'x',
            ),
          ),
          throwsStateError,
        );
      },
    );
  });

  group('цели', () {
    test('создание с формулой по умолчанию, правка, архив, удаление', () async {
      final id = repo.newId();
      await repo.createGoal(
        Goal(
          id: id,
          name: ' Подушка ',
          targetAmount: 40000000,
          formula: defaultGoalFormula(),
        ),
      );
      var goal = (await repo.getGoal(id))!;
      expect(goal.name, 'Подушка');
      expect(goal.formula.map((t) => t.kind), [
        GoalTermKind.allAccounts,
        GoalTermKind.debtsToMe,
        GoalTermKind.receivables,
      ]);
      await repo.updateGoal(
        goal.copyWith(
          targetAmount: 50000000,
          formula: [
            ...goal.formula,
            const GoalTerm(kind: GoalTermKind.myDebts, plus: false),
          ],
        ),
      );
      goal = (await repo.getGoal(id))!;
      expect(goal.targetAmount, 50000000);
      expect(goal.formula.last.plus, isFalse);
      await repo.setGoalArchived(id, archived: true);
      expect((await repo.getGoal(id))!.archived, isTrue);
      await repo.deleteGoal(id);
      expect(await dev.device.store.visibleRows('goals'), isEmpty);
      await repo.restoreGoal(id);
      expect(await dev.device.store.visibleRows('goals'), hasLength(1));
      await expectLater(
        repo.createGoal(
          Goal(id: repo.newId(), name: 'x', targetAmount: 1, formula: const []),
        ),
        _invalid('слагаемых'),
      );
      await expectLater(
        repo.updateGoal(goal.copyWith(targetAmount: 0)),
        _invalid('Целевая'),
      );
    });
  });
}
