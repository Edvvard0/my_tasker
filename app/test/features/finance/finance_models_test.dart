import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

void main() {
  test('перечисления: значения колонок и запасной вариант', () {
    expect(AccountKind.parse('credit_card'), AccountKind.creditCard);
    expect(AccountKind.parse('???'), AccountKind.other);
    expect(AccountKind.creditCard.isCard, isTrue);
    expect(AccountKind.cash.isCard, isFalse);
    expect(AccountKind.debitCard.wire, 'debit_card');
    expect(CategoryKind.parse('income'), CategoryKind.income);
    expect(CategoryKind.parse(null), CategoryKind.expense);
    expect(TransactionKind.parse('transfer'), TransactionKind.transfer);
    expect(TransactionKind.parse('x'), TransactionKind.expense);
    expect(
      TransactionSource.parse('work_payment'),
      TransactionSource.workPayment,
    );
    expect(TransactionSource.parse('x'), TransactionSource.manual);
    expect(
      TransactionStatus.parse('needs_review'),
      TransactionStatus.needsReview,
    );
    expect(TransactionStatus.parse('x'), TransactionStatus.confirmed);
    expect(CheckpointSource.parse('statement'), CheckpointSource.statement);
    expect(CheckpointSource.parse('x'), CheckpointSource.manual);
    expect(TransactionKind.income.label, 'Доход');
    expect(AccountKind.savings.label, 'Накопительный счёт');
  });

  test('счёт: строка, поля и copyWith', () {
    final row = {
      'id': 'a',
      'name': 'Карта',
      'kind': 'credit_card',
      'bank': 'Банк',
      'card_last4': '1234',
      'opening_balance': -500,
      'opening_date': '2026-01-01',
      'include_in_total': false,
      'credit_limit': 30000000,
      'archived': true,
    };
    final a = Account.fromRow(row);
    expect(a.toRow(), row);
    expect(a.toFields().containsKey('id'), isFalse);
    final b = a.copyWith(
      name: 'Другая',
      kind: AccountKind.cash,
      bank: null,
      cardLast4: null,
      openingBalance: 1,
      openingDate: '2026-02-02',
      includeInTotal: true,
      creditLimit: null,
      archived: false,
    );
    expect(b.id, 'a');
    expect(b.name, 'Другая');
    expect(b.kind, AccountKind.cash);
    expect(b.bank, isNull);
    expect(b.cardLast4, isNull);
    expect(b.creditLimit, isNull);
    expect(b.includeInTotal, isTrue);
    expect(b.archived, isFalse);
    final c = a.copyWith();
    expect(c.toRow(), a.toRow());
  });

  test('категория: строка, поля и copyWith (ключ сохраняется)', () {
    final row = {
      'id': 'c',
      'name': 'Еда',
      'kind': 'income',
      'parent_id': 'p',
      'icon': 'home',
      'color': '#112233',
      'system_key': 'income.salary',
    };
    final c = FinanceCategory.fromRow(row);
    expect(c.toRow(), row);
    expect(c.isPreset, isTrue);
    final d = c.copyWith(
      name: 'Н',
      kind: CategoryKind.expense,
      parentId: null,
      icon: null,
      color: null,
    );
    expect(d.systemKey, 'income.salary');
    expect(d.parentId, isNull);
    expect(d.icon, isNull);
    expect(d.color, isNull);
    expect(d.kind, CategoryKind.expense);
    expect(c.copyWith().toRow(), row);
    expect(
      const FinanceCategory(
        id: 'x',
        name: 'n',
        kind: CategoryKind.expense,
      ).isPreset,
      isFalse,
    );
  });

  test('операция: строка с долями секунды, поля и copyWith', () {
    final row = {
      'id': 't',
      'kind': 'transfer',
      'account_id': 'a',
      'to_account_id': 'b',
      'amount': 5000,
      'occurred_at': '2026-09-30T21:30:00.123456Z',
      'category_id': null,
      'merchant': 'M',
      'comment': 'K',
      'source': 'manual',
      'status': 'draft',
      'external_id': 'e',
      'dedup_hash': '0123456789abcdef',
      'work_payment_id': null,
      'debt_id': 'd',
    };
    final t = FinanceTransaction.fromRow(row);
    expect(t.occurredAt, DateTime.utc(2026, 9, 30, 21, 30));
    expect(t.moscowDay, '2026-10-01', reason: '00:30 по Москве — уже октябрь');
    expect(t.status, TransactionStatus.draft);
    expect(t.toRow()['occurred_at'], '2026-09-30T21:30:00Z');
    final d = t.copyWith(
      kind: TransactionKind.expense,
      accountId: 'z',
      toAccountId: null,
      amount: 1,
      occurredAt: DateTime.utc(2026, 10, 2),
      categoryId: 'c',
      merchant: null,
      comment: null,
      status: TransactionStatus.confirmed,
    );
    expect(d.id, 't');
    expect(d.toAccountId, isNull);
    expect(d.merchant, isNull);
    expect(d.comment, isNull);
    expect(d.categoryId, 'c');
    expect(d.externalId, 'e');
    expect(d.debtId, 'd');
    expect(t.copyWith().toRow()['occurred_at'], '2026-09-30T21:30:00Z');
    expect(formatSeconds(0), '1970-01-01T00:00:00Z');
  });

  test('точка сверки и корректировка', () {
    final row = {
      'id': 'k',
      'account_id': 'a',
      'checked_at': '2026-10-05T09:00:00Z',
      'actual_balance': 17400000,
      'source': 'statement',
      'note': 'н',
    };
    final cp = BalanceCheckpoint.fromRow(row);
    expect(cp.toRow(), row);
    final adj = BalanceAdjustment.fromJson(const {
      'checkpoint_id': 'k',
      'checked_at': '2026-10-05T09:00:00Z',
      'actual': 17400000,
      'expected': 17320000,
      'adjustment': 80000,
    });
    expect(adj.adjustment, 80000);
    expect(adj.checkedAt, DateTime.utc(2026, 10, 5, 9));
  });
}
