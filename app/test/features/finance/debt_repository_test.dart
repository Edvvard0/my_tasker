import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

Debt _debt(
  int n, {
  DebtDirection direction = DebtDirection.owedToMe,
  String? who = 'Эмир',
  int amount = 750000,
  String date = '2026-09-01',
  String? due,
  String? comment,
}) => Debt(
  id: uuid(n),
  direction: direction,
  counterparty: who,
  amount: amount,
  debtDate: date,
  dueDate: due,
  comment: comment,
);

DebtRepayment _repayment(
  int n, {
  required int debt,
  int amount = 100000,
  String on = '2026-10-01',
  String? transaction,
  String? note,
}) => DebtRepayment(
  id: uuid(n),
  debtId: uuid(debt),
  amount: amount,
  repaidOn: on,
  transactionId: transaction,
  note: note,
);

Account _account(int n, {int opening = 1000000}) => Account(
  id: uuid(n),
  name: 'Карта $n',
  kind: AccountKind.debitCard,
  openingBalance: opening,
  openingDate: '2026-01-01',
);

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice d;
  late FinanceRepository repo;
  var counter = 0;

  setUp(() async {
    // 5 октября 2026, 12:00 по Москве.
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    d = await FinanceDevice.create(
      server,
      clock: clock,
      newId: () => uuid(900 + ++counter),
    );
    repo = d.finance;
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  Future<List<OutboxOp>> ops() => d.device.store.outbox();

  Future<String?> problem(Future<Object?> action) async {
    try {
      await action;
    } on ValidationError catch (e) {
      return e.message;
    }
    return null;
  }

  group('долги', () {
    test(
      'создание, чтение, обрезка контрагента, порядок по созданию',
      () async {
        await repo.createDebt(_debt(2, who: '  Настя '));
        clock.advance(const Duration(seconds: 1));
        await repo.createDebt(
          _debt(
            1,
            who: 'Bender',
            direction: DebtDirection.iOwe,
            due: '2026-10-20',
            comment: '  на ремонт ',
          ),
        );
        final all = await repo.debts();
        expect(all.map((x) => x.who), ['Настя', 'Bender']);
        final got = (await repo.getDebt(uuid(1)))!;
        expect(got.direction, DebtDirection.iOwe);
        expect(got.dueDate, '2026-10-20');
        expect(got.comment, 'на ремонт');
        expect(got.personId, isNull);
        expect(await repo.getDebt('нет'), isNull);
        // только долги в очереди: ни одной операции счёта
        final queue = await ops();
        expect(queue.map((o) => o.table), ['debts', 'debts']);
        expect(queue.first.fields!['counterparty'], 'Настя');
      },
    );

    test('значения проверяются до записи в outbox', () async {
      final bad = <Debt>[
        _debt(1, who: null),
        _debt(1, who: '   '),
        _debt(1, who: 'x' * 201),
        _debt(1, amount: 0),
        _debt(1, amount: -5),
        _debt(1, amount: 99999999999999 + 1),
        _debt(1, date: '2026-02-30'),
        _debt(1, date: '1.10.2026'),
        _debt(1, due: '2026-02-30'),
        _debt(1, due: '2026-08-31'),
        _debt(1, comment: 'c' * 2001),
      ];
      for (final b in bad) {
        expect(await problem(repo.createDebt(b)), isNotNull, reason: '$b');
      }
      expect(await ops(), isEmpty);
      // граничные значения допустимы
      await repo.createDebt(
        _debt(
          1,
          who: 'x' * 200,
          amount: 99999999999999,
          due: '2026-09-01',
          comment: 'c' * 2000,
        ),
      );
      expect(await repo.debts(), hasLength(1));
    });

    test('правка уносит только изменившиеся колонки', () async {
      await repo.createDebt(_debt(1));
      await d.device.sync();
      final before = (await ops()).length;
      await repo.updateDebt(
        (await repo.getDebt(uuid(1)))!
            .copyWith(amount: 800000, dueDate: '2026-10-30'),
      );
      final all = await ops();
      expect(all, hasLength(before + 1));
      expect(all.last.fields, {'amount': 800000, 'due_date': '2026-10-30'});
      await repo.updateDebt((await repo.getDebt(uuid(1)))!); // без изменений
      expect(await ops(), hasLength(before + 1));
      await expectLater(repo.updateDebt(_debt(77)), throwsA(isA<StateError>()));
      expect(
        await problem(repo.updateDebt(_debt(1, due: '2026-08-01'))),
        isNotNull,
      );
    });

    test('удаление долга — одна операция delete; погашения скрыты, операции '
        'остаются', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(_debt(1));
      await repo.addRepayment(
        debtId: uuid(1),
        amount: 100000,
        repaidOn: '2026-10-02',
        accountId: uuid(1),
      );
      await repo.addRepayment(
        debtId: uuid(1),
        amount: 50000,
        repaidOn: '2026-10-03',
      );
      await d.device.sync();
      expect(await repo.repayments(), hasLength(2));
      await repo.deleteDebt(uuid(1));
      final queue = await ops();
      expect(queue, hasLength(1));
      expect(queue.single.type, 'delete');
      expect(queue.single.table, 'debts');
      expect(await repo.debts(), isEmpty);
      expect(await repo.repayments(), isEmpty);
      expect((await repo.debtsOverview()).isEmpty, isTrue);
      // операция счёта с debt_id осталась и считается в балансе
      expect(await repo.transactions(), hasLength(1));
      expect((await repo.balances()).of(uuid(1)), 1100000);
      // восстановление возвращает долг вместе с погашениями
      await repo.restoreDebt(uuid(1));
      expect(await repo.repayments(), hasLength(2));
      expect((await repo.debtState(uuid(1)))!.repaid, 150000);
    });
  });

  group('погашения и статусы', () {
    test('открыт -> частично -> закрыт; остатки и итоги направлений', () async {
      // «Мне должны» 7 500 + 2 600 + 3 000; «я должен» 125 000 (spec 6.1).
      await repo.createDebt(_debt(1));
      await repo.createDebt(_debt(2, who: 'Настя', amount: 260000));
      await repo.createDebt(_debt(3, who: 'Bender', amount: 300000));
      await repo.createDebt(
        _debt(
          4,
          who: 'Кредитка',
          direction: DebtDirection.iOwe,
          amount: 12500000,
        ),
      );
      var o = await repo.debtsOverview();
      expect(o.owedToMe, 1310000);
      expect(o.iOwe, 12500000);
      expect(o.byId(uuid(2))!.status, DebtStatus.open);

      await repo.createRepayment(_repayment(10, debt: 2, amount: 60000));
      o = await repo.debtsOverview();
      final nastya = o.byId(uuid(2))!;
      expect(nastya.status, DebtStatus.partial);
      expect(nastya.repaid, 60000);
      expect(nastya.remaining, 200000);
      expect(o.owedToMe, 1250000);
      expect(o.iOwe, 12500000);
      expect(o.byId(uuid(1))!.status, DebtStatus.open);
      expect(o.openCount(DebtDirection.owedToMe), 3);

      // закрыть остаток: два погашения подряд
      await repo.createRepayment(_repayment(11, debt: 2, amount: 150000));
      await repo.createRepayment(_repayment(12, debt: 2, amount: 50000));
      o = await repo.debtsOverview();
      final closed = o.byId(uuid(2))!;
      expect(closed.status, DebtStatus.closed);
      expect(closed.remaining, 0);
      expect(closed.overpaid, 0);
      expect(o.owedToMe, 1050000);
      expect(o.openCount(DebtDirection.owedToMe), 2);
      expect(
        o.of(DebtDirection.owedToMe, closed: true).single.debt.id,
        uuid(2),
      );
      // порядок открытых: больший остаток выше
      expect(
        o.of(DebtDirection.owedToMe, closed: false).map((s) => s.debt.id),
        [uuid(1), uuid(3)],
      );
    });

    test(
      'просрочка считается по московской дате: в день срока ещё нет',
      () async {
        await repo.createDebt(_debt(1, due: '2026-10-05'));
        await repo.createDebt(_debt(2, due: '2026-10-04'));
        await repo.createDebt(_debt(3, due: '2026-10-04', amount: 1000));
        await repo.createRepayment(_repayment(10, debt: 3, amount: 1000));
        var o = await repo.debtsOverview();
        expect(repo.moscowToday, '2026-10-05');
        expect(o.byId(uuid(1))!.overdue, isFalse, reason: 'день срока');
        expect(o.byId(uuid(2))!.overdue, isTrue);
        expect(o.byId(uuid(2))!.overdueDays, 1);
        expect(o.byId(uuid(3))!.overdue, isFalse, reason: 'закрыт');
        expect(o.byId(uuid(3))!.overdueDays, 0);

        // 21:00 UTC 5 октября — уже 6 октября по Москве: срок «5-го» прошёл,
        // хотя по UTC ещё 5-е.
        clock.advance(const Duration(hours: 12));
        expect(clock.now.day, 5);
        expect(repo.moscowToday, '2026-10-06');
        o = await repo.debtsOverview();
        expect(o.byId(uuid(1))!.overdue, isTrue);
        expect(o.byId(uuid(1))!.overdueDays, 1);
        expect(o.byId(uuid(2))!.overdueDays, 2);
        // явная дата перекрывает часы
        o = await repo.debtsOverview(today: '2026-10-04');
        expect(o.byId(uuid(1))!.overdue, isFalse);
        expect(o.byId(uuid(2))!.overdue, isFalse);
      },
    );

    test('переплата: остаток 0, статус закрыт, переплата видна', () async {
      await repo.createDebt(_debt(1, amount: 100000));
      await repo.createRepayment(_repayment(10, debt: 1, amount: 130000));
      final s = (await repo.debtState(uuid(1)))!;
      expect(s.status, DebtStatus.closed);
      expect(s.remaining, 0);
      expect(s.overpaid, 30000);
      expect(s.repaid, 130000);
      expect((await repo.debtsOverview()).owedToMe, 0);
    });

    test('значения погашения проверяются до записи', () async {
      await repo.createDebt(_debt(1));
      await d.device.sync();
      final before = (await ops()).length;
      final bad = <DebtRepayment>[
        _repayment(10, debt: 1, amount: 0),
        _repayment(10, debt: 1, amount: -1),
        _repayment(10, debt: 1, amount: 99999999999999 + 1),
        _repayment(10, debt: 1, on: '2026-02-30'),
        _repayment(10, debt: 1, on: ''),
        _repayment(10, debt: 1, note: 'n' * 501),
      ];
      for (final b in bad) {
        expect(await problem(repo.createRepayment(b)), isNotNull);
      }
      // долга нет
      expect(
        await problem(repo.createRepayment(_repayment(10, debt: 55))),
        'Долг не найден',
      );
      expect(
        await problem(
          repo.addRepayment(
            debtId: uuid(55),
            amount: 5,
            repaidOn: '2026-10-01',
          ),
        ),
        'Долг не найден',
      );
      expect(await ops(), hasLength(before));
      await repo.createRepayment(
        _repayment(10, debt: 1, amount: 99999999999999, note: 'n' * 500),
      );
      expect(await repo.repayments(debtId: uuid(1)), hasLength(1));
    });

    test('правка и удаление погашения меняют остаток; восстановление '
        'возвращает', () async {
      await repo.createDebt(_debt(1, amount: 100000));
      await repo.createRepayment(_repayment(10, debt: 1, amount: 40000));
      await repo.createRepayment(_repayment(11, debt: 1, amount: 10000));
      await d.device.sync();
      await repo.updateRepayment(
        (await repo.getRepayment(uuid(10)))!
            .copyWith(amount: 30000, note: ' часть '),
      );
      final last = (await ops()).last;
      expect(last.table, 'debt_repayments');
      expect(last.fields, {'amount': 30000, 'note': 'часть'});
      expect((await repo.debtState(uuid(1)))!.remaining, 60000);
      // без изменений операции нет
      final count = (await ops()).length;
      await repo.updateRepayment((await repo.getRepayment(uuid(10)))!);
      expect(await ops(), hasLength(count));
      // debt_id неизменяем
      expect(
        await problem(
          repo.updateRepayment(_repayment(10, debt: 2, amount: 30000)),
        ),
        'Долг погашения нельзя менять',
      );
      await expectLater(
        repo.updateRepayment(_repayment(77, debt: 1)),
        throwsA(isA<StateError>()),
      );

      await repo.deleteRepayment(uuid(11));
      expect((await ops()).last.type, 'delete');
      expect((await repo.debtState(uuid(1)))!.remaining, 70000);
      expect(await repo.repayments(), hasLength(1));
      await repo.restoreRepayment(uuid(11));
      expect((await repo.debtState(uuid(1)))!.remaining, 60000);
    });

    test('погашения идут по дате; чтение по долгам', () async {
      await repo.createDebt(_debt(1));
      await repo.createDebt(_debt(2));
      await repo.createRepayment(_repayment(10, debt: 1, on: '2026-10-03'));
      await repo.createRepayment(_repayment(11, debt: 1));
      await repo.createRepayment(_repayment(12, debt: 2, on: '2026-10-02'));
      expect((await repo.repayments()).map((r) => r.id), [
        uuid(11),
        uuid(12),
        uuid(10),
      ]);
      expect((await repo.repayments(debtId: uuid(1))).map((r) => r.id), [
        uuid(11),
        uuid(10),
      ]);
      expect(await repo.watchRepayments(debtId: uuid(2)).first, hasLength(1));
      expect(await repo.watchDebts().first, hasLength(2));
    });
  });

  group('движение денег', () {
    Future<int> balance(int account) async =>
        (await repo.balances()).of(uuid(account));

    test('«мне вернули» через счёт: доход с debt_id, баланс растёт, доход '
        'месяца не меняется', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(_debt(1));
      // контроль: обычный доход месяца виден в итогах
      await repo.createTransaction(
        FinanceTransaction(
          id: uuid(50),
          kind: TransactionKind.income,
          accountId: uuid(1),
          amount: 20000,
          occurredAt: DateTime.utc(2026, 10, 2, 9),
        ),
      );
      final id = await repo.addRepayment(
        debtId: uuid(1),
        amount: 250000,
        repaidOn: '2026-10-05',
        accountId: uuid(1),
        note: ' первая часть ',
      );
      final r = (await repo.getRepayment(id))!;
      expect(r.note, 'первая часть');
      final tx = (await repo.getTransaction(r.transactionId!))!;
      expect(tx.kind, TransactionKind.income);
      expect(tx.debtId, uuid(1));
      expect(tx.accountId, uuid(1));
      expect(tx.amount, 250000);
      expect(tx.merchant, 'Эмир');
      expect(tx.comment, 'первая часть');
      expect(tx.source, TransactionSource.manual);
      expect(tx.status, TransactionStatus.confirmed);
      // сегодня по Москве — момент «сейчас»
      expect(tx.occurredAt, clock.now);
      expect(await balance(1), 1000000 + 20000 + 250000);
      final feed = TransactionFeed.of(await repo.transactions());
      expect(feed.items, hasLength(2));
      expect(feed.months['2026-10']!.income, 20000, reason: 'без возврата');
      expect(feed.months['2026-10']!.expense, 0);
      expect((await repo.debtState(uuid(1)))!.remaining, 500000);
    });

    test('«я вернул» через счёт: расход с debt_id; расход месяца не меняется; '
        'другой день — полдень по Москве', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(
        _debt(1, direction: DebtDirection.iOwe, who: 'Bender', amount: 300000),
      );
      final id = await repo.addRepayment(
        debtId: uuid(1),
        amount: 100000,
        repaidOn: '2026-10-01',
        accountId: uuid(1),
      );
      final tx = (await repo.getTransaction(
        (await repo.getRepayment(id))!.transactionId!,
      ))!;
      expect(tx.kind, TransactionKind.expense);
      expect(tx.debtId, uuid(1));
      expect(tx.occurredAt, DateTime.utc(2026, 10, 1, 9));
      expect(tx.moscowDay, '2026-10-01');
      expect(await balance(1), 900000);
      final feed = TransactionFeed.of(await repo.transactions());
      expect(feed.items, hasLength(1));
      expect(feed.months, isEmpty, reason: 'в аналитике нет расхода');
    });

    test('«списать без движения денег»: погашение без операции, баланс '
        'не меняется', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(_debt(1, amount: 200000));
      final id = await repo.addRepayment(
        debtId: uuid(1),
        amount: 200000,
        repaidOn: '2026-10-05',
        note: 'простил',
      );
      expect((await repo.getRepayment(id))!.transactionId, isNull);
      expect(await repo.transactions(), isEmpty);
      expect(await balance(1), 1000000);
      expect((await repo.debtState(uuid(1)))!.status, DebtStatus.closed);
    });

    test('операция займа при создании долга: «мне должны» — расход, '
        '«я должен» — доход; «расход/доход» месяца не меняются', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(
        _debt(1, amount: 500000, date: '2026-10-05'),
        loanAccountId: uuid(1),
      );
      await repo.createDebt(
        _debt(
          2,
          direction: DebtDirection.iOwe,
          who: 'Банк',
          amount: 300000,
          date: '2026-09-20',
        ),
        loanAccountId: uuid(1),
      );
      expect(await balance(1), 1000000 - 500000 + 300000);
      final txs = await repo.transactions();
      expect(txs, hasLength(2));
      final gave = txs.firstWhere((t) => t.debtId == uuid(1));
      expect(gave.kind, TransactionKind.expense);
      expect(gave.amount, 500000);
      expect(gave.merchant, 'Эмир');
      expect(gave.occurredAt, clock.now);
      final took = txs.firstWhere((t) => t.debtId == uuid(2));
      expect(took.kind, TransactionKind.income);
      expect(took.occurredAt, DateTime.utc(2026, 9, 20, 9));
      final feed = TransactionFeed.of(txs);
      expect(feed.months, isEmpty);
      // долги не закрыты: остатки полные
      final o = await repo.debtsOverview();
      expect(o.owedToMe, 500000);
      expect(o.iOwe, 300000);
      // одна очередь: долг, затем его операция (в одной транзакции БД)
      expect((await ops()).map((o) => o.table).toList(), [
        'accounts',
        'debts',
        'transactions',
        'debts',
        'transactions',
      ]);
    });

    test('займ с несуществующим или удалённым счётом отменяет всё', () async {
      await repo.createAccount(_account(1));
      expect(
        await problem(repo.createDebt(_debt(1), loanAccountId: uuid(9))),
        'Счёт не найден',
      );
      await repo.deleteAccount(uuid(1));
      expect(
        await problem(repo.createDebt(_debt(1), loanAccountId: uuid(1))),
        'Счёт не найден',
      );
      expect(await repo.debts(), isEmpty);
      expect(await repo.getDebt(uuid(1)), isNull, reason: 'откат транзакции');
      // погашение через удалённый счёт тоже отменяется целиком
      await repo.createDebt(_debt(2));
      expect(
        await problem(
          repo.addRepayment(
            debtId: uuid(2),
            amount: 1000,
            repaidOn: '2026-10-05',
            accountId: uuid(1),
          ),
        ),
        'Счёт не найден',
      );
      expect(await repo.repayments(), isEmpty);
    });

    test('transaction_id должен указывать на операцию этого долга: иначе '
        'repayment_transaction_mismatch', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(_debt(1));
      await repo.createDebt(_debt(2));
      // обычная операция без debt_id
      await repo.createTransaction(
        FinanceTransaction(
          id: uuid(50),
          kind: TransactionKind.income,
          accountId: uuid(1),
          amount: 1000,
          occurredAt: DateTime.utc(2026, 10, 2, 9),
        ),
      );
      // операция другого долга
      final other = await repo.addRepayment(
        debtId: uuid(2),
        amount: 1000,
        repaidOn: '2026-10-05',
        accountId: uuid(1),
      );
      final otherTx = (await repo.getRepayment(other))!.transactionId!;
      for (final tx in [uuid(50), otherTx]) {
        final message = await problem(
          repo.createRepayment(_repayment(10, debt: 1, transaction: tx)),
        );
        expect(message, contains('repayment_transaction_mismatch'));
      }
      expect(
        await problem(
          repo.createRepayment(_repayment(10, debt: 1, transaction: uuid(99))),
        ),
        'Операция погашения не найдена',
      );
      expect(await repo.repayments(debtId: uuid(1)), isEmpty);
      // существующая операция этого же долга подходит
      await repo.createTransaction(
        FinanceTransaction(
          id: uuid(51),
          kind: TransactionKind.income,
          accountId: uuid(1),
          amount: 3000,
          occurredAt: DateTime.utc(2026, 10, 2, 9),
          debtId: uuid(1),
        ),
      );
      await repo.createRepayment(
        _repayment(11, debt: 1, amount: 3000, transaction: uuid(51)),
      );
      expect((await repo.getRepayment(uuid(11)))!.transactionId, uuid(51));
    });

    test(
      'правка погашения двигает привязанную операцию: сумма и день',
      () async {
        await repo.createAccount(_account(1));
        await repo.createDebt(_debt(1, amount: 500000));
        final id = await repo.addRepayment(
          debtId: uuid(1),
          amount: 100000,
          repaidOn: '2026-10-05',
          accountId: uuid(1),
        );
        final txId = (await repo.getRepayment(id))!.transactionId!;
        await repo.updateRepayment(
          (await repo.getRepayment(id))!
              .copyWith(amount: 150000, repaidOn: '2026-10-03'),
        );
        final tx = (await repo.getTransaction(txId))!;
        expect(tx.amount, 150000);
        expect(tx.moscowDay, '2026-10-03');
        expect(tx.occurredAt, DateTime.utc(2026, 10, 3, 9));
        expect(await balance(1), 1150000);
        expect((await repo.debtState(uuid(1)))!.remaining, 350000);
        // привязка не меняется, расхождения нет
        expect((await repo.getRepayment(id))!.transactionId, txId);
      },
    );

    test('удаление погашения и долга оставляет операции счёта', () async {
      await repo.createAccount(_account(1));
      await repo.createDebt(_debt(1, amount: 500000));
      final id = await repo.addRepayment(
        debtId: uuid(1),
        amount: 100000,
        repaidOn: '2026-10-05',
        accountId: uuid(1),
      );
      await repo.deleteRepayment(id);
      expect(await repo.transactions(), hasLength(1));
      expect(await balance(1), 1100000);
      // правка удалённого погашения не трогает операцию
      await repo.restoreRepayment(id);
      await repo.deleteDebt(uuid(1));
      expect(await repo.transactions(), hasLength(1));
      expect(await balance(1), 1100000);
    });
  });
}
