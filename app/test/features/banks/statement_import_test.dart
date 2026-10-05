import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/banks/data/statement_importer.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/banks/domain/statement_plan.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';

import '../../support/banks_env.dart';
import '../../support/calendar_env.dart';
import '../../support/manual_clock.dart';

/// Импорт выписки без дублей: план по строкам сервера и подтверждение на
/// устройстве (настоящая БД в памяти).
void main() {
  late ManualClock clock;
  late BanksDevice d;
  late String account;
  late String other;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 3, 12).millisecondsSinceEpoch);
    d = await BanksDevice.create(appServer(clock), clock: clock);
    await d.fin.finance.seedPresetCategories();
    Future<String> make(String name, String last4) async {
      final id = d.fin.finance.newId();
      await d.fin.finance.createAccount(
        Account(
          id: id,
          name: name,
          kind: AccountKind.debitCard,
          cardLast4: last4,
          openingBalance: 0,
          openingDate: '2026-01-01',
        ),
      );
      return id;
    }

    account = await make('Т-Банк', '1234');
    other = await make('ВТБ', '5678');
  });
  tearDown(() => d.close());

  Future<List<FinTransaction>> txs() async => [
    for (final r in await d.fin.device.store.visibleRows('transactions'))
      FinTransaction.fromRow(r),
  ];

  Future<List<ImportItem>> plan(
    ParsedStatement statement, {
    Map<String?, String?>? mapping,
  }) async => planImport(
    data: d.data,
    lines: statement.lines,
    accountOfCard: mapping ?? {null: account},
    transactions: await txs(),
    rules: await d.banks.rules(),
  );

  Future<ImportResult> import(
    ParsedStatement statement, {
    Map<String?, String?>? mapping,
  }) async {
    final items = await plan(statement, mapping: mapping);
    return await d.importer.commit(statement: statement, items: items);
  }

  ParsedStatement september() => statementOf(
    [
      serverLine(
        index: 0,
        occurredAt: '2026-09-10T09:00:00Z',
        kind: 'expense',
        amount: 50000,
        merchant: 'Кофе Дом',
        dateOnly: true,
      ),
      serverLine(
        index: 1,
        occurredAt: '2026-09-10T09:00:00Z',
        kind: 'expense',
        amount: 50000,
        merchant: 'Кофе Дом',
        dateOnly: true,
      ),
      serverLine(
        index: 2,
        occurredAt: '2026-09-12T08:15:00Z',
        kind: 'income',
        amount: 8500000,
        merchant: 'Работодатель',
      ),
      serverLine(
        index: 3,
        occurredAt: '2026-09-15T10:00:00Z',
        kind: 'expense',
        amount: 99900,
        merchant: 'Пятёрочка 1234 Москва',
        externalId: 'OP-77',
      ),
    ],
    closing: {'amount': 7777700, 'at': '2026-09-30T20:59:59Z'},
  );

  test('первый импорт: операции source=statement, подтверждены, категории из '
      'словаря, остаток → точка сверки', () async {
    final statement = september();
    final result = await import(statement);
    expect(result.created, 4);
    expect(result.refined, 0);
    expect(result.checkpointCreated, isTrue);
    final all = await txs();
    expect(all, hasLength(4));
    for (final t in all) {
      expect(t.source, TxSource.statement);
      expect(t.status, TxStatus.confirmed);
      expect(t.accountId, account);
    }
    final shop = all.firstWhere((t) => t.externalId == 'OP-77');
    expect(shop.categoryId, categoryPresetId('expense.groceries'));
    expect(shop.dedupHash, isNull);
    final coffee = all.where((t) => t.merchant == 'Кофе Дом').toList();
    expect(coffee, hasLength(2));
    // Две одинаковые покупки в один день: разные хеши (порядковый номер).
    expect(coffee.map((t) => t.dedupHash).toSet(), hasLength(2));
    final cps = [
      for (final r in await d.fin.device.store.visibleRows(
        'balance_checkpoints',
      ))
        BalanceCheckpoint.fromRow(r),
    ];
    expect(cps.single.source, CheckpointSource.statement);
    expect(cps.single.actualBalance, 7777700);
    expect(cps.single.checkedAt, DateTime.utc(2026, 9, 30, 20, 59, 59));
  });

  test('выписка «по сегодня»: точка сверки не позже «сейчас», поздние '
      'операции не «съедаются»', () async {
    // Сейчас 2026-10-03 12:00 UTC; выписка по сегодня: остаток «на конец
    // дня» — это 20:59:59Z, то есть в будущем.
    final statement = statementOf(
      [
        serverLine(
          index: 0,
          occurredAt: '2026-10-03T07:00:00Z',
          kind: 'expense',
          amount: 10000,
          merchant: 'Кофе Дом',
        ),
      ],
      closing: {'amount': 500000, 'at': '2026-10-03T20:59:59Z'},
    );
    final result = await import(statement);
    expect(result.checkpointCreated, isTrue);
    final cps = [
      for (final r in await d.fin.device.store.visibleRows(
        'balance_checkpoints',
      ))
        BalanceCheckpoint.fromRow(r),
    ];
    expect(cps.single.checkedAt, DateTime.utc(2026, 10, 3, 12));

    // Позже выписки пользователь вносит покупку (14:00 того же дня): она
    // идёт после точки и уменьшает баланс, а не теряется.
    clock.advance(const Duration(hours: 2));
    final later = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: later,
        kind: TxKind.expense,
        accountId: account,
        amount: 30000,
        occurredAt: DateTime.utc(2026, 10, 3, 14),
      ),
    );
    final acc = (await d.fin.finance.getAccount(account))!;
    expect(balanceAt(acc, await txs(), cps), 470000);

    // Повторный импорт той же выписки позже в тот же день не плодит точек.
    final again = await import(statement);
    expect(again.checkpointCreated, isFalse);
    expect(
      await d.fin.device.store.visibleRows('balance_checkpoints'),
      hasLength(1),
    );
  });

  test('повторный импорт той же выписки: все строки — дубликаты, ничего не '
      'создаётся, обе одинаковые покупки находятся', () async {
    final statement = september();
    await import(statement);
    final again = await plan(statement);
    expect(again.every((i) => i.isDuplicate), isTrue);
    expect(again.every((i) => !i.selected), isTrue);
    expect(again.map((i) => i.match!.reason), [
      'hash',
      'hash',
      'hash',
      'external_id',
    ]);
    final result = await d.importer.commit(statement: statement, items: again);
    expect(result.created, 0);
    expect(result.skipped, 4);
    expect(result.checkpointCreated, isFalse);
    expect(await txs(), hasLength(4));
    final summary = summarize(again);
    expect(summary.duplicates, 4);
    expect(summary.total, 0);
  });

  test('пересекающаяся выписка: создаются только новые строки', () async {
    await import(september());
    final overlap = statementOf([
      serverLine(
        index: 0,
        occurredAt: '2026-09-10T09:00:00Z',
        kind: 'expense',
        amount: 50000,
        merchant: 'Кофе Дом',
        dateOnly: true,
      ),
      serverLine(
        index: 1,
        occurredAt: '2026-09-10T09:00:00Z',
        kind: 'expense',
        amount: 50000,
        merchant: 'Кофе Дом',
        dateOnly: true,
      ),
      serverLine(
        index: 2,
        occurredAt: '2026-10-01T09:00:00Z',
        kind: 'expense',
        amount: 12000,
        merchant: 'Метро',
        dateOnly: true,
      ),
    ]);
    final result = await import(overlap);
    expect(result.created, 1);
    expect(await txs(), hasLength(5));
  });

  test('строка выписки уточняет черновик уведомления, а не создаёт вторую '
      'операцию; повторный импорт — дубликат', () async {
    final draft = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: draft,
        kind: TxKind.expense,
        accountId: account,
        amount: 123456,
        occurredAt: DateTime.utc(2026, 10, 3, 8, 30),
        merchant: 'PYATEROCHKA',
        source: TxSource.notification,
        status: TxStatus.draft,
        dedupHash: 'a' * 32,
      ),
    );
    final statement = statementOf([
      serverLine(
        index: 0,
        occurredAt: '2026-10-03T08:33:10Z',
        kind: 'expense',
        amount: 123456,
        merchant: 'PYATEROCHKA 1234',
        externalId: 'OP-1',
      ),
    ]);
    final items = await plan(statement);
    expect(items.single.isRefinement, isTrue);
    expect(items.single.match!.action, MatchAction.merge);
    expect(items.single.selected, isTrue);
    final result = await d.importer.commit(statement: statement, items: items);
    expect(result.refined, 1);
    expect(result.created, 0);
    final all = await txs();
    expect(all, hasLength(1));
    final row = all.single;
    expect(row.id, draft);
    expect(row.occurredAt, DateTime.utc(2026, 10, 3, 8, 33, 10));
    expect(row.merchant, 'PYATEROCHKA 1234');
    expect(row.externalId, 'OP-1');
    expect(row.source, TxSource.statement);
    // Статус черновика остаётся за пользователем.
    expect(row.status, TxStatus.draft);
    final again = await plan(statement);
    expect(again.single.isDuplicate, isTrue);
    expect(again.single.match!.reason, 'external_id');
  });

  test('уточнение ручной операции без изменений — «уже есть», источник '
      'сохраняется', () async {
    final manual = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: manual,
        kind: TxKind.expense,
        accountId: account,
        amount: 7000,
        occurredAt: DateTime.utc(2026, 10, 3, 9),
        merchant: 'Кофе Дом',
      ),
    );
    final statement = statementOf([
      serverLine(
        index: 0,
        occurredAt: '2026-10-03T09:00:00Z',
        kind: 'expense',
        amount: 7000,
        merchant: 'Кофе Дом',
        dateOnly: true,
      ),
    ]);
    final items = await plan(statement);
    expect(items.single.match!.action, MatchAction.merge);
    expect(items.single.isRefinement, isFalse);
    expect(items.single.isDuplicate, isTrue);
    expect(items.single.selected, isFalse);
  });

  test('перевод между своими счетами считается существующим для строки '
      'выписки получателя', () async {
    final transfer = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: transfer,
        kind: TxKind.transfer,
        accountId: other,
        toAccountId: account,
        amount: 500000,
        occurredAt: DateTime.utc(2026, 10, 3, 9),
        merchant: 'Перевод Себе',
      ),
    );
    final statement = statementOf([
      serverLine(
        index: 0,
        occurredAt: '2026-10-03T09:00:00Z',
        kind: 'income',
        amount: 500000,
        merchant: 'Входящий перевод от ВТБ',
        dateOnly: true,
      ),
    ]);
    final items = await plan(statement);
    expect(items.single.match!.action, MatchAction.duplicate);
    expect(items.single.match!.existingId, transfer);
  });

  test(
    'чужая валюта: needs_review, не нечётко, создаётся «Требует проверки»',
    () async {
      final statement = statementOf([
        serverLine(
          index: 0,
          occurredAt: '2026-10-03T09:00:00Z',
          kind: 'expense',
          amount: 110000,
          merchant: 'AMAZON',
          needsReview: true,
          originalAmount: 1250,
          originalCurrency: 'USD',
          dateOnly: true,
        ),
      ]);
      final items = await plan(statement);
      expect(items.single.line.needsReview, isTrue);
      expect(summarize(items).foreign, 1);
      final result = await d.importer.commit(
        statement: statement,
        items: items,
      );
      expect(result.created, 1);
      final tx = (await txs()).single;
      expect(tx.status, TxStatus.needsReview);
      expect(tx.comment, contains('12,50 USD'));
      expect(tx.amount, 110000);
    },
  );

  test('карты выписки — разные счета; остаток не привязывается к одному, '
      'если счетов несколько', () async {
    final statement = statementOf(
      [
        serverLine(
          index: 0,
          occurredAt: '2026-09-10T09:00:00Z',
          kind: 'expense',
          amount: 1000,
          merchant: 'Магнит',
          card: '1234',
          dateOnly: true,
        ),
        serverLine(
          index: 1,
          occurredAt: '2026-09-10T09:00:00Z',
          kind: 'expense',
          amount: 2000,
          merchant: 'Магнит',
          card: '5678',
          dateOnly: true,
        ),
        serverLine(
          index: 2,
          occurredAt: '2026-09-11T09:00:00Z',
          kind: 'expense',
          amount: 3000,
          merchant: 'Лента',
          dateOnly: true,
        ),
      ],
      cards: ['1234', '5678'],
      closing: {'amount': 100, 'at': '2026-09-30T20:59:59Z'},
    );
    final mapping = {'1234': account, '5678': other, null: account};
    final result = await import(statement, mapping: mapping);
    expect(result.created, 3);
    expect(result.checkpointCreated, isFalse);
    final all = await txs();
    expect(all.where((t) => t.accountId == other), hasLength(1));
    expect(all.where((t) => t.accountId == account), hasLength(2));
  });

  test('строки без счёта не импортируются', () async {
    final statement = september();
    final items = planImport(
      data: d.data,
      lines: statement.lines,
      accountOfCard: const {},
      transactions: const [],
      rules: const [],
    );
    expect(items.every((i) => i.accountId == null && !i.selected), isTrue);
    expect(summarize(items).withoutAccount, 4);
    final result = await d.importer.commit(statement: statement, items: items);
    expect(result.created, 0);
  });

  test('хеш клиента совпадает с dedup_tail сервера (один счёт)', () async {
    final tails = [
      'expense|50000|2026-09-10T09:00|кофе дом',
      'expense|50000|2026-09-10T09:00|кофе дом|1',
    ];
    final statement = statementOf([
      {
        ...serverLine(
          index: 0,
          occurredAt: '2026-09-10T09:00:00Z',
          kind: 'expense',
          amount: 50000,
          merchant: 'Кофе Дом',
          dateOnly: true,
        ),
        'dedup_tail': tails[0],
      },
      {
        ...serverLine(
          index: 1,
          occurredAt: '2026-09-10T09:00:00Z',
          kind: 'expense',
          amount: 50000,
          merchant: 'Кофе Дом',
          dateOnly: true,
        ),
        'dedup_tail': tails[1],
      },
    ]);
    final items = await plan(statement);
    for (var i = 0; i < 2; i++) {
      expect(items[i].match!.dedupHash, hashOf(account, tails[i]));
      expect(statement.lines[i].serverTail, tails[i]);
    }
  });

  test('модели ответа сервера: период, пропуски, названия', () {
    final s = ParsedStatement.fromJson(const {
      'format': 'xlsx',
      'bank': 'vtb',
      'period': {'from': '2026-09-01', 'to': '2026-09-30'},
      'closing_balance': {'amount': 5, 'at': '2026-09-30T20:59:59Z'},
      'cards': ['1234'],
      'candidates': <Object?>[],
      'skipped': [
        {'row': 5, 'reason': 'bad_date'},
        {'row': 6, 'reason': 'status FAILED'},
        {'row': 7, 'reason': 'no_amount'},
        {'row': 8, 'reason': 'x'},
      ],
    });
    expect(s.periodFrom, '2026-09-01');
    expect(s.closingBalance!.amount, 5);
    expect(statementBankName(s.bank), 'ВТБ');
    expect(statementBankName('tbank'), 'Т-Банк');
    expect(statementBankName('generic'), 'Банк не определён');
    expect(
      [for (final x in s.skipped) skippedReasonText(x.reason)],
      [
        'Не удалось прочитать дату',
        'Операция не проведена',
        'Нет суммы',
        'Строка пропущена',
      ],
    );
    final empty = ParsedStatement.fromJson(const {});
    expect(empty.lines, isEmpty);
    expect(empty.closingBalance, isNull);
    expect(empty.bank, 'generic');
  });
}
