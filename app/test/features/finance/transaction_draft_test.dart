import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/transaction_draft.dart';

final _now = DateTime.utc(2026, 9, 30, 8, 40);

TransactionDraft _draft({
  TransactionKind kind = TransactionKind.expense,
  String amount = '1 249,90',
  String? account = 'a1',
  String? to,
  String? category,
  DateTime? at,
}) => TransactionDraft(
  kind: kind,
  occurredAt: at ?? _now,
  amountText: amount,
  accountId: account,
  toAccountId: to,
  categoryId: category,
);

BalanceCheckpoint _cp(String account, DateTime at, {String id = 'c1'}) =>
    BalanceCheckpoint(
      id: id,
      accountId: account,
      checkedAt: at,
      actualBalance: 100,
    );

void main() {
  group('сумма', () {
    test('разбирается в целые копейки', () {
      expect(_draft(amount: '1 249,90').amountKopecks, 124990);
      expect(_draft(amount: '1 249,9').amountKopecks, 124990);
      expect(_draft(amount: '12,').amountKopecks, 1200);
      expect(_draft(amount: '12.').amountKopecks, 1200);
      expect(_draft(amount: '0,01').amountKopecks, 1);
    });

    test('пусто, ноль, минус и мусор — нет суммы', () {
      for (final text in ['', '  ', '0', '0,00', '−5', 'abc', ',']) {
        expect(_draft(amount: text).amountKopecks, isNull, reason: text);
        expect(_draft(amount: text).problem, 'Введи сумму больше нуля');
      }
    });

    test('больше максимума — нет суммы', () {
      expect(_draft(amount: '1000000000000').amountKopecks, isNull);
      expect(_draft(amount: '999999999999,99').amountKopecks, 99999999999999);
    });
  });

  group('смена вида', () {
    test('расход -> перевод: категория сбрасывается', () {
      final d = _draft(
        category: 'cat',
      ).withKind(TransactionKind.transfer, categoryKind: CategoryKind.expense);
      expect(d.kind, TransactionKind.transfer);
      expect(d.categoryId, isNull);
    });

    test('перевод -> доход: «куда» сбрасывается', () {
      final d = _draft(
        kind: TransactionKind.transfer,
        to: 'a2',
      ).withKind(TransactionKind.income);
      expect(d.toAccountId, isNull);
      expect(d.accountId, 'a1');
    });

    test('тот же вид — тот же черновик', () {
      final d = _draft();
      expect(identical(d.withKind(TransactionKind.expense), d), isTrue);
    });

    test('расход -> доход: категория расхода сбрасывается', () {
      final d = _draft(category: 'cat')
          .withKind(TransactionKind.income, categoryKind: CategoryKind.expense);
      expect(d.categoryId, isNull);
    });

    test('категория того же вида сохраняется', () {
      final d = _draft(
        kind: TransactionKind.income,
        category: 'cat',
      ).withKind(TransactionKind.income, categoryKind: CategoryKind.income);
      expect(d.categoryId, 'cat');
      final e = _draft(category: 'cat')
          .withKind(TransactionKind.income, categoryKind: CategoryKind.income);
      expect(e.categoryId, 'cat');
    });

    test('сумма, дата и текст остаются', () {
      final d = _draft().copyWith(merchant: 'Лента', comment: 'к');
      final next = d.withKind(TransactionKind.income);
      expect(next.amountText, '1 249,90');
      expect(next.occurredAt, _now);
      expect(next.merchant, 'Лента');
      expect(next.comment, 'к');
    });
  });

  group('перевод', () {
    test('нужны оба счёта и они разные', () {
      expect(
        _draft(kind: TransactionKind.transfer, account: null).problem,
        'Выбери счёт, откуда переводим',
      );
      expect(
        _draft(kind: TransactionKind.transfer).problem,
        'Выбери счёт, куда переводим',
      );
      expect(
        _draft(kind: TransactionKind.transfer, to: 'a1').problem,
        'Перевод — между двумя разными счетами',
      );
      expect(_draft(kind: TransactionKind.transfer, to: 'a2').problem, isNull);
    });

    test('«откуда» = «куда» сбрасывает «куда»', () {
      final d = _draft(
        kind: TransactionKind.transfer,
        to: 'a2',
      ).withAccount('a2');
      expect(d.accountId, 'a2');
      expect(d.toAccountId, isNull);
      expect(_draft(to: 'a2').withAccount('a3').toAccountId, 'a2');
    });

    test('«поменять местами»', () {
      final d = _draft(kind: TransactionKind.transfer, to: 'a2').swapped();
      expect(d.accountId, 'a2');
      expect(d.toAccountId, 'a1');
    });

    test('операция расхода без счёта', () {
      expect(_draft(account: null).problem, 'Выбери счёт');
      expect(_draft().problem, isNull);
    });
  });

  group('операция из черновика', () {
    test('расход: без «куда», пустой текст — null', () {
      final t = _draft(category: 'cat', to: 'ignored').toTransaction('id1');
      expect(t.id, 'id1');
      expect(t.kind, TransactionKind.expense);
      expect(t.amount, 124990);
      expect(t.categoryId, 'cat');
      expect(t.toAccountId, isNull);
      expect(t.merchant, isNull);
      expect(t.comment, isNull);
      expect(t.source, TransactionSource.manual);
      expect(t.status, TransactionStatus.confirmed);
    });

    test('перевод: без категории', () {
      final t = _draft(
        kind: TransactionKind.transfer,
        to: 'a2',
        category: 'cat',
      ).toTransaction('id1');
      expect(t.toAccountId, 'a2');
      expect(t.categoryId, isNull);
    });

    test('правка сохраняет источник и статус существующей операции', () {
      final base = FinanceTransaction(
        id: 'id1',
        kind: TransactionKind.income,
        accountId: 'a1',
        amount: 100,
        occurredAt: _now,
        source: TransactionSource.notification,
        status: TransactionStatus.needsReview,
        externalId: 'ext',
      );
      final draft = TransactionDraft.fromTransaction(base);
      expect(draft.amountText, '1');
      expect(draft.kind, TransactionKind.income);
      final t = draft
          .copyWith(amountText: '2,5')
          .toTransaction('id1', base: base);
      expect(t.amount, 250);
      expect(t.source, TransactionSource.notification);
      expect(t.status, TransactionStatus.needsReview);
      expect(t.externalId, 'ext');
    });

    test('операция с debt_id: вид и сумма не меняются, debt_id и остальное '
        'правятся/сохраняются', () {
      final base = FinanceTransaction(
        id: 'id1',
        kind: TransactionKind.income,
        accountId: 'a1',
        amount: 100000,
        occurredAt: _now,
        merchant: 'Тимур',
        debtId: 'debt',
      );
      // Попытка превратить в перевод на другой счёт с другой суммой.
      final hostile = TransactionDraft.fromTransaction(base)
          .withKind(TransactionKind.transfer)
          .copyWith(amountText: '5', toAccountId: 'a2', comment: 'заметка');
      expect(hostile.kind, TransactionKind.transfer);
      final t = hostile.toTransaction('id1', base: base);
      expect(t.kind, TransactionKind.income);
      expect(t.amount, 100000);
      expect(t.debtId, 'debt');
      expect(t.toAccountId, isNull);
      // Счёт, дата и комментарий — редактируются.
      expect(t.comment, 'заметка');

      final moved = TransactionDraft.fromTransaction(base)
          .withAccount('a3')
          .copyWith(merchant: 'Тимур Р.')
          .toTransaction('id1', base: base);
      expect(moved.accountId, 'a3');
      expect(moved.merchant, 'Тимур Р.');
      expect(moved.debtId, 'debt');
      expect(moved.kind, TransactionKind.income);
    });

    test('fromTransaction: копейки в тексте суммы', () {
      final t = FinanceTransaction(
        id: 'i',
        kind: TransactionKind.expense,
        accountId: 'a1',
        amount: 124905,
        occurredAt: _now,
        merchant: 'Лента',
        comment: 'ужин',
      );
      final d = TransactionDraft.fromTransaction(t);
      expect(d.amountText, '1249,05');
      expect(d.merchant, 'Лента');
      expect(d.comment, 'ужин');
    });
  });

  group('предупреждение «задним числом» (spec 4.2)', () {
    final checked = DateTime.utc(2026, 9, 20, 12);

    test('операция раньше последней сверки счёта — предупреждение', () {
      final d = _draft(at: DateTime.utc(2026, 9, 10));
      expect(d.backdatedAccounts([_cp('a1', checked)]), ['a1']);
    });

    test('в тот же момент баланс тоже не меняется', () {
      expect(_draft(at: checked).backdatedAccounts([_cp('a1', checked)]), [
        'a1',
      ]);
    });

    test('позже сверки или без сверок — нет', () {
      final later = _draft(at: DateTime.utc(2026, 9, 21));
      expect(later.backdatedAccounts([_cp('a1', checked)]), isEmpty);
      expect(later.backdatedAccounts(const []), isEmpty);
    });

    test('сверка другого счёта не мешает', () {
      final d = _draft(at: DateTime.utc(2026, 9, 10));
      expect(d.backdatedAccounts([_cp('a9', checked)]), isEmpty);
    });

    test('берётся последняя из нескольких сверок', () {
      final d = _draft(at: DateTime.utc(2026, 9, 15));
      expect(
        d.backdatedAccounts([
          _cp('a1', DateTime.utc(2026, 9)),
          _cp('a1', checked, id: 'c2'),
          _cp('a1', DateTime.utc(2026, 9, 5), id: 'c3'),
        ]),
        ['a1'],
      );
    });

    test('у перевода проверяются оба счёта', () {
      final d = _draft(
        kind: TransactionKind.transfer,
        to: 'a2',
        at: DateTime.utc(2026, 9, 10),
      );
      expect(
        d.backdatedAccounts([_cp('a1', checked), _cp('a2', checked, id: 'c2')]),
        ['a1', 'a2'],
      );
      // У расхода «куда» не учитывается.
      final e = _draft(to: 'a2', at: DateTime.utc(2026, 9, 10));
      expect(e.backdatedAccounts([_cp('a2', checked)]), isEmpty);
    });
  });
}
