import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';

/// Клиентские проверки — зеркало серверных
/// (`backend/src/tasker/finance/schema.py`: `account_problem`,
/// `category_problem`, `transaction_problem`, `checkpoint_problem`,
/// `debt_problem`, `repayment_problem` и колонки
/// `*_COLUMNS`; spec Этапа 5, 1 и 3.1).
void main() {
  const maxK = 99999999999999;

  Account account({
    String name = 'Карта',
    AccountKind kind = AccountKind.debitCard,
    String? bank,
    String? last4,
    int opening = 0,
    String date = '2026-01-01',
    int? limit,
  }) => Account(
    id: 'a',
    name: name,
    kind: kind,
    bank: bank,
    cardLast4: last4,
    openingBalance: opening,
    openingDate: date,
    creditLimit: limit,
  );

  group('счёт', () {
    test('нормальный счёт', () {
      expect(accountProblem(account()), isNull);
      expect(accountProblem(account(name: 'x' * 100, bank: 'b' * 100)), isNull);
      expect(accountProblem(account(opening: -maxK)), isNull);
      expect(accountProblem(account(opening: maxK)), isNull);
      expect(accountProblem(account(last4: '0042')), isNull);
      expect(
        accountProblem(
          account(kind: AccountKind.creditCard, limit: maxK, last4: '1234'),
        ),
        isNull,
      );
      expect(
        accountProblem(account(kind: AccountKind.creditCard, limit: 0)),
        isNull,
      );
    });

    test('название: 1–100 символов, не пустое', () {
      expect(accountProblem(account(name: '')), isNotNull);
      expect(accountProblem(account(name: '   ')), isNotNull);
      expect(accountProblem(account(name: 'x' * 101)), isNotNull);
    });

    test('банк не длиннее 100', () {
      expect(accountProblem(account(bank: 'b' * 101)), isNotNull);
    });

    test('card_last4: ровно 4 цифры и только у карт', () {
      for (final bad in ['123', '12345', 'abcd', '12 4', '١٢٣٤']) {
        expect(accountProblem(account(last4: bad)), isNotNull, reason: bad);
      }
      for (final kind in [
        AccountKind.cash,
        AccountKind.savings,
        AccountKind.deposit,
        AccountKind.other,
      ]) {
        expect(
          accountProblem(account(kind: kind, last4: '1234')),
          isNotNull,
          reason: kind.name,
        );
      }
    });

    test('credit_limit: только у кредитной карты, 0…максимум', () {
      expect(accountProblem(account(limit: 5)), isNotNull);
      expect(
        accountProblem(account(kind: AccountKind.creditCard, limit: -1)),
        isNotNull,
      );
      expect(
        accountProblem(account(kind: AccountKind.creditCard, limit: maxK + 1)),
        isNotNull,
      );
    });

    test('opening_balance вне диапазона и несуществующая дата', () {
      expect(accountProblem(account(opening: maxK + 1)), isNotNull);
      expect(accountProblem(account(opening: -maxK - 1)), isNotNull);
      expect(accountProblem(account(date: '2026-02-30')), isNotNull);
      expect(accountProblem(account(date: '1.10.2026')), isNotNull);
      expect(accountProblem(account(date: '')), isNotNull);
    });
  });

  group('категория', () {
    FinanceCategory category({
      String name = 'Еда',
      String? icon,
      String? color,
      String? key,
      String? parent,
      CategoryKind kind = CategoryKind.expense,
      String id = 'c',
    }) => FinanceCategory(
      id: id,
      name: name,
      kind: kind,
      icon: icon,
      color: color,
      systemKey: key,
      parentId: parent,
    );

    test('нормальная категория', () {
      expect(categoryProblem(category()), isNull);
      expect(
        categoryProblem(
          category(icon: 'home', color: '#AaBb09', key: 'expense.groceries'),
        ),
        isNull,
      );
      expect(categoryProblem(category(name: 'x' * 100)), isNull);
    });

    test('название, иконка, цвет', () {
      expect(categoryProblem(category(name: ' ')), isNotNull);
      expect(categoryProblem(category(name: 'x' * 101)), isNotNull);
      expect(categoryProblem(category(icon: '')), isNotNull);
      expect(categoryProblem(category(icon: 'i' * 51)), isNotNull);
      for (final bad in ['red', '#12345', '#1234567', '123456', '#gggggg']) {
        expect(categoryProblem(category(color: bad)), isNotNull, reason: bad);
      }
    });

    test('system_key: только известные ключи spec 3.2', () {
      expect(categoryProblem(category(key: 'expense.nope')), isNotNull);
      expect(categoryProblem(category(key: 'Expense.Groceries')), isNotNull);
      expect(categoryProblem(category(key: 'income.salary')), isNull);
    });

    test('родитель: верхний уровень, тот же вид, не сам себе', () {
      final root = category(id: 'r');
      final child = category(parent: 'r');
      expect(categoryParentProblem(category(), null), isNull);
      expect(categoryParentProblem(child, root), isNull);
      expect(categoryParentProblem(child, null), isNotNull);
      expect(
        categoryParentProblem(child, category(id: 'r', parent: 'x')),
        isNotNull,
        reason: 'глубина 3',
      );
      expect(
        categoryParentProblem(
          child,
          category(id: 'r', kind: CategoryKind.income),
        ),
        isNotNull,
        reason: 'другой вид',
      );
      expect(
        categoryParentProblem(category(parent: 'c'), root),
        isNotNull,
        reason: 'сам себе родитель',
      );
      expect(categoryParentProblem(child, root, hasChildren: true), isNotNull);
    });
  });

  group('операция', () {
    FinanceTransaction tx({
      TransactionKind kind = TransactionKind.expense,
      int amount = 100,
      DateTime? at,
      String? to,
      String account = 'a',
      String? category,
      String? work,
      String? debt,
      TransactionSource source = TransactionSource.manual,
      String? merchant,
      String? comment,
      String? external,
      String? hash,
    }) => FinanceTransaction(
      id: 't',
      kind: kind,
      accountId: account,
      toAccountId: to,
      amount: amount,
      occurredAt: at ?? DateTime.utc(2026, 10, 5, 9),
      categoryId: category,
      workPaymentId: work,
      debtId: debt,
      source: source,
      merchant: merchant,
      comment: comment,
      externalId: external,
      dedupHash: hash,
    );

    test('нормальные операции', () {
      expect(transactionProblem(tx()), isNull);
      expect(transactionProblem(tx(amount: 1)), isNull);
      expect(transactionProblem(tx(amount: maxK)), isNull);
      expect(
        transactionProblem(tx(at: DateTime.utc(2015))),
        isNull,
        reason: 'ровно 2015-01-01 — можно',
      );
      expect(
        transactionProblem(
          tx(kind: TransactionKind.transfer, to: 'b', amount: 5),
        ),
        isNull,
      );
      expect(
        transactionProblem(
          tx(
            kind: TransactionKind.income,
            work: 'p',
            source: TransactionSource.workPayment,
            debt: 'd',
          ),
        ),
        isNull,
      );
      expect(
        transactionProblem(
          tx(
            merchant: 'm' * 200,
            comment: 'c' * 2000,
            external: 'e' * 200,
            hash: '0123456789abcdef',
          ),
        ),
        isNull,
      );
    });

    test('сумма: 1…максимум (знак задаёт вид)', () {
      expect(transactionProblem(tx(amount: 0)), isNotNull);
      expect(transactionProblem(tx(amount: -5)), isNotNull);
      expect(transactionProblem(tx(amount: maxK + 1)), isNotNull);
    });

    test('occurred_at не раньше 2015-01-01 и до 2200', () {
      expect(
        transactionProblem(tx(at: DateTime.utc(2014, 12, 31, 23, 59, 59))),
        isNotNull,
      );
      expect(transactionProblem(tx(at: DateTime.utc(1999))), isNotNull);
      expect(transactionProblem(tx(at: DateTime.utc(2200))), isNotNull);
    });

    test('перевод: два разных счёта и без категории, платежа и долга', () {
      FinanceTransaction transfer({
        String? to = 'b',
        String? category,
        String? work,
        String? debt,
      }) => tx(
        kind: TransactionKind.transfer,
        to: to,
        category: category,
        work: work,
        debt: debt,
      );
      expect(transactionProblem(transfer(to: null)), isNotNull);
      expect(transactionProblem(transfer(to: 'a')), isNotNull);
      expect(transactionProblem(transfer(category: 'c')), isNotNull);
      expect(transactionProblem(transfer(work: 'p')), isNotNull);
      expect(transactionProblem(transfer(debt: 'd')), isNotNull);
    });

    test('to_account_id только у перевода', () {
      expect(transactionProblem(tx(to: 'b')), isNotNull);
      expect(
        transactionProblem(tx(kind: TransactionKind.income, to: 'b')),
        isNotNull,
      );
    });

    test('work_payment_id: только доход; источник и ссылка — вместе', () {
      expect(transactionProblem(tx(work: 'p')), isNotNull);
      expect(
        transactionProblem(tx(kind: TransactionKind.income, work: 'p')),
        isNotNull,
        reason: 'ссылка есть, источник manual',
      );
      expect(
        transactionProblem(
          tx(
            kind: TransactionKind.income,
            source: TransactionSource.workPayment,
          ),
        ),
        isNotNull,
        reason: 'источник work_payment без ссылки',
      );
    });

    test('тексты и формат внешних полей', () {
      expect(transactionProblem(tx(merchant: 'm' * 201)), isNotNull);
      expect(transactionProblem(tx(comment: 'c' * 2001)), isNotNull);
      expect(transactionProblem(tx(external: '')), isNotNull);
      expect(transactionProblem(tx(external: 'e' * 201)), isNotNull);
      for (final bad in [
        '0123456789abcde',
        '0123456789ABCDEF',
        'g123456789abcdef',
        '0' * 65,
      ]) {
        expect(transactionProblem(tx(hash: bad)), isNotNull, reason: bad);
      }
    });
  });

  group('точка сверки', () {
    BalanceCheckpoint cp({DateTime? at, int actual = 0, String? note}) =>
        BalanceCheckpoint(
          id: 'c',
          accountId: 'a',
          checkedAt: at ?? DateTime.utc(2026, 10, 5),
          actualBalance: actual,
          note: note,
        );

    test('нормальная', () {
      expect(checkpointProblem(cp()), isNull);
      expect(checkpointProblem(cp(actual: -maxK)), isNull);
      expect(checkpointProblem(cp(actual: maxK, note: 'n' * 500)), isNull);
      expect(checkpointProblem(cp(at: DateTime.utc(2015))), isNull);
    });

    test('момент, баланс, заметка', () {
      expect(
        checkpointProblem(cp(at: DateTime.utc(2014, 12, 31, 23))),
        isNotNull,
      );
      expect(checkpointProblem(cp(actual: maxK + 1)), isNotNull);
      expect(checkpointProblem(cp(actual: -maxK - 1)), isNotNull);
      expect(checkpointProblem(cp(note: 'n' * 501)), isNotNull);
    });
  });

  group('долг', () {
    Debt debt({
      String? who = 'Эмир',
      String? person,
      int amount = 750000,
      String date = '2026-09-01',
      String? due,
      String? comment,
      DebtDirection direction = DebtDirection.owedToMe,
    }) => Debt(
      id: 'd',
      direction: direction,
      personId: person,
      counterparty: who,
      amount: amount,
      debtDate: date,
      dueDate: due,
      comment: comment,
    );

    test('нормальные долги (debt_problem, DEBT_COLUMNS)', () {
      expect(debtProblem(debt()), isNull);
      expect(debtProblem(debt(direction: DebtDirection.iOwe)), isNull);
      expect(debtProblem(debt(who: 'x' * 200)), isNull);
      expect(debtProblem(debt(amount: 1)), isNull);
      expect(debtProblem(debt(amount: maxK)), isNull);
      expect(
        debtProblem(debt(due: '2026-09-01')),
        isNull,
        reason: 'срок = дата',
      );
      expect(debtProblem(debt(due: '2026-12-31', comment: 'c' * 2000)), isNull);
      // человек вместо контрагента-текста допустим (сервер: person_id)
      expect(debtProblem(debt(who: null, person: 'p')), isNull);
      expect(debtProblem(debt(who: '  ', person: 'p')), isNull);
    });

    test('нужен person_id или непустой контрагент', () {
      expect(debtProblem(debt(who: null)), isNotNull);
      expect(debtProblem(debt(who: '')), isNotNull);
      expect(debtProblem(debt(who: '   ')), isNotNull);
    });

    test('контрагент ≤ 200, комментарий ≤ 2000', () {
      expect(debtProblem(debt(who: 'x' * 201)), isNotNull);
      expect(debtProblem(debt(comment: 'c' * 2001)), isNotNull);
    });

    test('сумма: 1…максимум', () {
      expect(debtProblem(debt(amount: 0)), isNotNull);
      expect(debtProblem(debt(amount: -1)), isNotNull);
      expect(debtProblem(debt(amount: maxK + 1)), isNotNull);
    });

    test('даты: формат, несуществующие, срок не раньше даты долга', () {
      for (final bad in ['2026-02-30', '1.10.2026', '', '2026-13-01']) {
        expect(debtProblem(debt(date: bad)), isNotNull, reason: bad);
        expect(debtProblem(debt(due: bad.isEmpty ? 'x' : bad)), isNotNull);
      }
      expect(debtProblem(debt(due: '2026-08-31')), isNotNull);
    });
  });

  group('погашение', () {
    DebtRepayment repayment({
      int amount = 100000,
      String on = '2026-10-01',
      String? transaction,
      String? note,
      String debtId = 'd',
    }) => DebtRepayment(
      id: 'r',
      debtId: debtId,
      amount: amount,
      repaidOn: on,
      transactionId: transaction,
      note: note,
    );

    test('нормальное погашение (repayment_problem, REPAYMENT_COLUMNS)', () {
      expect(repaymentProblem(repayment()), isNull);
      expect(repaymentProblem(repayment(amount: 1)), isNull);
      expect(
        repaymentProblem(repayment(amount: maxK, note: 'n' * 500)),
        isNull,
      );
    });

    test('сумма 1…максимум, дата реальная, заметка ≤ 500', () {
      expect(repaymentProblem(repayment(amount: 0)), isNotNull);
      expect(repaymentProblem(repayment(amount: -5)), isNotNull);
      expect(repaymentProblem(repayment(amount: maxK + 1)), isNotNull);
      for (final bad in ['2026-02-30', '1.10.2026', '']) {
        expect(repaymentProblem(repayment(on: bad)), isNotNull, reason: bad);
      }
      expect(repaymentProblem(repayment(note: 'n' * 501)), isNotNull);
    });

    test('операция должна двигать этот же долг (spec 1.6, раздел 8)', () {
      // нет операции — нет проверки
      expect(
        repaymentTransactionProblem(repayment(), transactionFound: false),
        isNull,
      );
      final linked = repayment(transaction: 't');
      expect(
        repaymentTransactionProblem(
          linked,
          transactionFound: true,
          transactionDebtId: 'd',
        ),
        isNull,
      );
      for (final other in <String?>['x', null]) {
        expect(
          repaymentTransactionProblem(
            linked,
            transactionFound: true,
            transactionDebtId: other,
          ),
          contains(repaymentTransactionMismatchCode),
        );
      }
      expect(
        repaymentTransactionMismatchCode,
        'repayment_transaction_mismatch',
      );
      expect(
        repaymentTransactionProblem(linked, transactionFound: false),
        isNotNull,
      );
    });
  });
}
