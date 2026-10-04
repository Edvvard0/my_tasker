import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_sync_specs.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';

FinTransaction _tx({
  String id = 't',
  TxKind kind = TxKind.expense,
  String account = 'a1',
  String? to,
  int amount = 100,
  DateTime? at,
  String? category,
  String? work,
  String? debt,
  TxSource source = TxSource.manual,
  String? external,
  String? hash,
  String? merchant,
}) => FinTransaction(
  id: id,
  kind: kind,
  accountId: account,
  toAccountId: to,
  amount: amount,
  occurredAt: at ?? DateTime.utc(2026, 10, 5, 9),
  categoryId: category,
  workPaymentId: work,
  debtId: debt,
  source: source,
  externalId: external,
  dedupHash: hash,
  merchant: merchant,
);

const _account = Account(
  id: 'a1',
  name: 'Т-Банк',
  kind: AccountKind.debitCard,
  openingBalance: 100000,
  openingDate: '2026-01-01',
);

void main() {
  group('модели: мягкое чтение строк', () {
    test('неизвестные перечисления читаются безопасно', () {
      final tx = FinTransaction.fromRow(const {
        'id': 't',
        'kind': 'новый вид',
        'status': 'неизвестный',
        'source': '???',
        'account_id': 'a',
        'amount': 5,
        'occurred_at': '2026-10-05T09:00:00Z',
      });
      expect(tx.kind, TxKind.expense);
      // Неизвестный статус не считается подтверждённым.
      expect(tx.status, TxStatus.needsReview);
      expect(tx.isConfirmed, isFalse);
      expect(tx.source, TxSource.manual);
      expect(AccountKind.parse('x'), AccountKind.other);
      expect(CategoryKind.parse('x'), CategoryKind.expense);
      expect(CheckpointSource.parse('x'), CheckpointSource.manual);
      expect(DebtDirection.parse('x'), DebtDirection.owedToMe);
      expect(GoalTermKind.parse('x'), isNull);
    });

    test('строка без status — подтверждена (векторы), доли секунды '
        'отбрасываются, мусорный момент — 2015', () {
      expect(
        FinTransaction.fromRow(const {'id': 't'}).status,
        TxStatus.confirmed,
      );
      expect(
        parseFinanceInstant('2026-10-05T09:00:00.900Z'),
        DateTime.utc(2026, 10, 5, 9),
      );
      expect(parseFinanceInstant('мусор'), DateTime.utc(2015));
      expect(parseFinanceInstant(null), DateTime.utc(2015));
      expect(
        financeInstantText(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03:04:05Z',
      );
    });

    test('toFields <-> fromRow: счёт, операция, долг, цель', () {
      const account = Account(
        id: 'a',
        name: 'Кредитка',
        kind: AccountKind.creditCard,
        bank: 'Т-Банк',
        cardLast4: '4242',
        openingBalance: -500,
        openingDate: '2026-01-01',
        includeInTotal: false,
        creditLimit: 300000,
        archived: true,
      );
      final back = Account.fromRow({'id': 'a', ...account.toFields()});
      expect(back.toFields(), account.toFields());
      expect(back.copyWith(bank: null).bank, isNull);
      expect(back.copyWith(name: 'x').name, 'x');

      final tx = _tx(
        kind: TxKind.income,
        category: 'c',
        work: 'w',
        source: TxSource.workPayment,
        merchant: 'Рома',
      );
      final txBack = FinTransaction.fromRow({'id': 't', ...tx.toFields()});
      expect(txBack.toFields(), tx.toFields());
      expect(tx.copyWith(categoryId: null).categoryId, isNull);
      expect(tx.copyWith(toAccountId: 'x').toAccountId, 'x');

      const debt = Debt(
        id: 'd',
        direction: DebtDirection.iOwe,
        amount: 100,
        debtDate: '2026-10-01',
        counterparty: 'Банк',
        dueDate: '2026-11-01',
        comment: 'c',
      );
      expect(
        Debt.fromRow({'id': 'd', ...debt.toFields()}).toFields(),
        debt.toFields(),
      );
      expect(debt.copyWith(dueDate: null).dueDate, isNull);

      const goal = Goal(
        id: 'g',
        name: 'Подушка',
        targetAmount: 100,
        formula: [
          GoalTerm(kind: GoalTermKind.accounts, accountIds: ['a']),
          GoalTerm(
            kind: GoalTermKind.receivables,
            plus: false,
            clientIds: ['p'],
          ),
        ],
        deadlineDate: '2026-12-01',
      );
      final goalBack = Goal.fromRow({'id': 'g', ...goal.toFields()});
      expect(goalBack.toFields(), goal.toFields());
      expect(goal.copyWith(deadlineDate: null).deadlineDate, isNull);
    });

    test('формула цели: свои ключи, знак, неизвестные слагаемые отброшены', () {
      expect(
        [for (final t in defaultGoalFormula()) t.toJson()],
        [
          {'kind': 'all_accounts', 'sign': '+'},
          {'kind': 'debts_to_me', 'sign': '+'},
          {'kind': 'receivables', 'sign': '+', 'client_ids': null},
        ],
      );
      expect(
        const GoalTerm(
          kind: GoalTermKind.accounts,
          plus: false,
          accountIds: ['x'],
        ).toJson(),
        {
          'kind': 'accounts',
          'sign': '-',
          'account_ids': ['x'],
        },
      );
      final goal = Goal.fromRow(const {
        'id': 'g',
        'formula': [
          {'kind': 'будущий', 'sign': '+'},
          {'kind': 'my_debts', 'sign': '-'},
          'не слагаемое',
        ],
      });
      expect(goal.formula.single.kind, GoalTermKind.myDebts);
      expect(goal.formula.single.plus, isFalse);
      expect(Goal.fromRow(const {'id': 'g', 'formula': 5}).formula, isEmpty);
    });
  });

  group('синхронизация: описания таблиц', () {
    test('порядок, неизменяемые колонки, родители перевода', () {
      expect(
        [for (final s in financeSyncSpecs) s.name],
        [
          'accounts',
          'categories',
          'transactions',
          'balance_checkpoints',
          'debts',
          'debt_repayments',
          'goals',
        ],
      );
      expect(
        transactionsSpec.parents.map((p) => '${p.column}>${p.parentTable}'),
        ['account_id>accounts', 'to_account_id>accounts'],
      );
      expect(balanceCheckpointsSpec.column('account_id')!.immutable, isTrue);
      expect(debtRepaymentsSpec.column('debt_id')!.immutable, isTrue);
      expect(categoriesSpec.column('system_key')!.immutable, isTrue);
      // Мягкие ссылки родителями не объявлены.
      expect(categoriesSpec.parents, isEmpty);
      expect(goalsSpec.parents, isEmpty);
      expect(debtsSpec.parents, isEmpty);
    });

    test('заголовки строк в корзине', () {
      expect(accountsSpec.titleOf({'name': 'Т-Банк'}), 'Т-Банк');
      expect(
        transactionsSpec.titleOf({
          'kind': 'income',
          'occurred_at': '2026-10-05T09:00:00Z',
          'merchant': 'Рома',
        }),
        'Доход 2026-10-05 · Рома',
      );
      expect(
        transactionsSpec.titleOf({
          'kind': 'transfer',
          'occurred_at': '2026-10-05T09:00:00Z',
        }),
        'Перевод 2026-10-05',
      );
      expect(
        transactionsSpec.titleOf({
          'kind': 'expense',
          'occurred_at': '2026-10-05T09:00:00Z',
        }),
        'Расход 2026-10-05',
      );
      expect(
        balanceCheckpointsSpec.titleOf({'checked_at': '2026-10-05T09:00:00Z'}),
        'Сверка 2026-10-05',
      );
      expect(
        debtsSpec.titleOf({'direction': 'i_owe', 'counterparty': 'Банк'}),
        'Я должен · Банк',
      );
      expect(debtsSpec.titleOf({'direction': 'owed_to_me'}), 'Мне должны');
      expect(
        debtRepaymentsSpec.titleOf({'repaid_on': '2026-10-05'}),
        'Погашение 2026-10-05',
      );
      expect(goalsSpec.titleOf({'name': 'Подушка'}), 'Подушка');
      expect(categoriesSpec.titleOf({'name': 'Продукты'}), 'Продукты');
    });
  });

  group('проверки значений', () {
    test('счёт', () {
      expect(accountProblem(_account), isNull);
      expect(accountProblem(_account.copyWith(name: ' ')), contains('пустым'));
      expect(
        accountProblem(_account.copyWith(cardLast4: '12a4')),
        contains('4 цифры'),
      );
      expect(
        accountProblem(
          _account.copyWith(kind: AccountKind.cash, cardLast4: '1234'),
        ),
        contains('только у карты'),
      );
      expect(
        accountProblem(_account.copyWith(creditLimit: 5)),
        contains('только у кредитной'),
      );
      expect(
        accountProblem(
          _account.copyWith(kind: AccountKind.creditCard, creditLimit: -1),
        ),
        contains('Кредитный лимит'),
      );
      expect(
        accountProblem(_account.copyWith(openingDate: '2026-02-30')),
        contains('нет такой даты'),
      );
      expect(
        accountProblem(_account.copyWith(openingBalance: 100000000000000)),
        contains('по модулю'),
      );
      expect(
        accountProblem(_account.copyWith(bank: 'x' * 101)),
        contains('Банк'),
      );
      // Отрицательный остаток допустим (кредитка).
      expect(accountProblem(_account.copyWith(openingBalance: -5)), isNull);
    });

    test('категория: глубина и вид родителя', () {
      const top = FinCategory(id: 't', name: 'А', kind: CategoryKind.expense);
      const child = FinCategory(
        id: 'c',
        name: 'Б',
        kind: CategoryKind.expense,
        parentId: 't',
      );
      expect(categoryProblem(top), isNull);
      expect(categoryProblem(child, parent: top), isNull);
      expect(
        categoryProblem(child, parent: child),
        contains('верхнего уровня'),
      );
      expect(
        categoryProblem(child.copyWith(kind: CategoryKind.income), parent: top),
        contains('того же вида'),
      );
      expect(categoryProblem(top.copyWith(color: 'red')), contains('#RRGGBB'));
      expect(categoryProblem(top.copyWith(name: '')), contains('пустым'));
      expect(categoryProblem(top.copyWith(icon: '')), contains('Иконка'));
    });

    test('операция: суммы, перевод, связи', () {
      expect(transactionProblem(_tx()), isNull);
      expect(transactionProblem(_tx(amount: 0)), contains('Сумма'));
      expect(
        transactionProblem(_tx(at: DateTime.utc(2014, 12, 31))),
        contains('2015'),
      );
      expect(
        transactionProblem(_tx(kind: TxKind.transfer)),
        contains('куда переводите'),
      );
      expect(
        transactionProblem(_tx(kind: TxKind.transfer, to: 'a1')),
        contains('разными'),
      );
      expect(transactionProblem(_tx(kind: TxKind.transfer, to: 'a2')), isNull);
      expect(
        transactionProblem(_tx(kind: TxKind.transfer, to: 'a2', category: 'c')),
        contains('нет категории'),
      );
      expect(
        transactionProblem(_tx(kind: TxKind.transfer, to: 'a2', debt: 'd')),
        contains('нет категории'),
      );
      expect(transactionProblem(_tx(to: 'a2')), contains('только у перевода'));
      expect(
        transactionProblem(_tx(work: 'w', source: TxSource.workPayment)),
        contains('только к доходу'),
      );
      expect(
        transactionProblem(_tx(kind: TxKind.income, work: 'w')),
        contains('идут вместе'),
      );
      expect(
        transactionProblem(
          _tx(kind: TxKind.income, source: TxSource.workPayment),
        ),
        contains('идут вместе'),
      );
      expect(
        transactionProblem(
          _tx(kind: TxKind.income, work: 'w', source: TxSource.workPayment),
        ),
        isNull,
      );
      expect(transactionProblem(_tx(external: '')), contains('Внешний'));
      expect(transactionProblem(_tx(hash: 'xyz')), contains('Хеш'));
      expect(transactionProblem(_tx(hash: 'abababababababab')), isNull);
      expect(
        transactionProblem(_tx(merchant: 'x' * 201)),
        contains('Контрагент'),
      );
    });

    test('сверка, долг, погашение', () {
      final cp = BalanceCheckpoint(
        id: 'c',
        accountId: 'a1',
        checkedAt: DateTime.utc(2026, 10),
        actualBalance: -5,
      );
      expect(checkpointProblem(cp), isNull);
      expect(
        checkpointProblem(
          BalanceCheckpoint(
            id: 'c',
            accountId: 'a1',
            checkedAt: DateTime.utc(2014),
            actualBalance: 0,
          ),
        ),
        contains('2015'),
      );
      const debt = Debt(
        id: 'd',
        direction: DebtDirection.owedToMe,
        amount: 100,
        debtDate: '2026-10-01',
        counterparty: 'Рома',
      );
      expect(debtProblem(debt), isNull);
      expect(
        debtProblem(debt.copyWith(counterparty: ' ')),
        contains('Укажите, кто'),
      );
      expect(debtProblem(debt.copyWith(amount: 0)), contains('Сумма'));
      expect(
        debtProblem(debt.copyWith(dueDate: '2026-09-30')),
        contains('раньше'),
      );
      expect(
        debtProblem(debt.copyWith(dueDate: '2026-13-01')),
        contains('Срок'),
      );
      expect(
        debtProblem(debt.copyWith(debtDate: '2026-00-01')),
        contains('Дата долга'),
      );
      const repayment = DebtRepayment(
        id: 'r',
        debtId: 'd',
        amount: 10,
        repaidOn: '2026-10-02',
      );
      expect(repaymentProblem(repayment), isNull);
      expect(
        repaymentProblem(
          const DebtRepayment(
            id: 'r',
            debtId: 'd',
            amount: 0,
            repaidOn: '2026-10-02',
          ),
        ),
        contains('Сумма'),
      );
      expect(
        repaymentProblem(
          const DebtRepayment(
            id: 'r',
            debtId: 'd',
            amount: 1,
            repaidOn: 'вчера',
          ),
        ),
        contains('нет такой даты'),
      );
    });

    test('цель и формула', () {
      final goal = Goal(
        id: 'g',
        name: 'Подушка',
        targetAmount: 100,
        formula: defaultGoalFormula(),
      );
      expect(goalProblem(goal), isNull);
      expect(goalProblem(goal.copyWith(targetAmount: 0)), contains('Целевая'));
      expect(goalProblem(goal.copyWith(name: '')), contains('пустым'));
      expect(
        goalProblem(goal.copyWith(deadlineDate: '2026-02-31')),
        contains('Срок'),
      );
      expect(goalProblem(goal.copyWith(formula: [])), contains('слагаемых'));
      expect(
        goalProblem(
          goal.copyWith(formula: [const GoalTerm(kind: GoalTermKind.accounts)]),
        ),
        contains('счетов'),
      );
      expect(
        goalProblem(
          goal.copyWith(
            formula: [
              const GoalTerm(kind: GoalTermKind.receivables, clientIds: []),
            ],
          ),
        ),
        contains('заказчиков'),
      );
      expect(
        formulaProblem([
          for (var i = 0; i < 31; i++)
            const GoalTerm(kind: GoalTermKind.allAccounts),
        ]),
        contains('30'),
      );
    });
  });

  group('помощники расчётов', () {
    test(
      'момент выбранной даты: сегодня — «сейчас», иначе полдень по Москве',
      () {
        final now = DateTime.utc(2026, 9, 30, 8, 40, 12, 500);
        expect(
          momentForDate('2026-09-30', now),
          DateTime.utc(2026, 9, 30, 8, 40, 12),
        );
        expect(momentForDate('2026-09-20', now), DateTime.utc(2026, 9, 20, 9));
        // Поздний вечер UTC — уже следующий день по Москве.
        expect(
          momentForDate('2026-10-01', DateTime.utc(2026, 9, 30, 21, 30)),
          DateTime.utc(2026, 9, 30, 21, 30),
        );
      },
    );

    test('операция не позже точки сверки не изменит баланс', () {
      final cps = [
        BalanceCheckpoint(
          id: 'c',
          accountId: 'a1',
          checkedAt: DateTime.utc(2026, 10, 5, 9),
          actualBalance: 1,
        ),
      ];
      expect(
        isBeforeLastCheckpoint('a1', DateTime.utc(2026, 10, 5, 9), cps),
        isTrue,
      );
      expect(
        isBeforeLastCheckpoint('a1', DateTime.utc(2026, 10, 5, 9, 1), cps),
        isFalse,
      );
      expect(
        isBeforeLastCheckpoint('a2', DateTime.utc(2026, 10), cps),
        isFalse,
      );
    });

    test('месяцы назад, в том числе через границу года', () {
      expect(monthsBack('2026-03', 4), [
        '2025-12',
        '2026-01',
        '2026-02',
        '2026-03',
      ]);
      expect(monthsBack('2026-10', 1), ['2026-10']);
      expect(monthsBack('2026-01', 2), ['2025-12', '2026-01']);
    });

    test('сравнение по кодовым точкам, свёртка мерчанта', () {
      expect(compareCodePoints('a', 'b'), lessThan(0));
      expect(compareCodePoints('b', 'a'), greaterThan(0));
      expect(compareCodePoints('ab', 'ab'), 0);
      expect(compareCodePoints('a', 'ab'), lessThan(0));
      expect(compareCodePoints('ab', 'a'), greaterThan(0));
      // Символ вне BMP старше U+FFFF по кодовой точке, хотя суррогат меньше.
      expect(compareCodePoints('\u{1F600}', '�'), greaterThan(0));
      expect(foldMerchant('ЁЛКА  Palki'), 'ёлка palki');
      expect(collapseSpaces('  a \t b  '), 'a b');
    });

    test('черновик, перевод и долг не входят в аналитику', () {
      expect(countsInAnalytics(_tx()), isTrue);
      expect(countsInAnalytics(_tx(kind: TxKind.transfer, to: 'a2')), isFalse);
      expect(countsInAnalytics(_tx(debt: 'd')), isFalse);
      expect(
        countsInAnalytics(_tx().copyWith(status: TxStatus.draft)),
        isFalse,
      );
    });

    test('перевод между счетами в общем балансе не меняет общий баланс', () {
      const second = Account(
        id: 'a2',
        name: 'Наличные',
        kind: AccountKind.cash,
        openingBalance: 50000,
        openingDate: '2026-01-01',
      );
      final before = accountBalances([_account, second], [], []);
      final after = accountBalances(
        [_account, second],
        [_tx(kind: TxKind.transfer, to: 'a2', amount: 30000)],
        [],
      );
      expect(before.total, 150000);
      expect(after.total, 150000);
      expect(after.of('a1'), 70000);
      expect(after.of('a2'), 80000);
      expect(after.of('нет'), 0);
    });
  });

  group('форматирование сумм и режим «скрыть суммы»', () {
    test('обычный и скрытый режим', () {
      const shown = AmountFormat(hidden: false);
      const hidden = AmountFormat(hidden: true);
      expect(shown.full(123456), '1 234,56 ₽');
      expect(shown.signed(100000), '+1 000 ₽');
      expect(shown.signed(-100000), '-1 000 ₽');
      expect(shown.signed(0), '0 ₽');
      expect(shown.short(8050000), '80,5к ₽');
      expect(hidden.full(123456), AmountFormat.mask);
      expect(hidden.signed(5), AmountFormat.mask);
      expect(hidden.short(5), AmountFormat.mask);
      expect(AmountFormat.mask, '••• ₽');
    });
  });
}
