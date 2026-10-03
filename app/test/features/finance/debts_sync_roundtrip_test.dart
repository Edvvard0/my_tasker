import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

/// Долги и погашения через общий клиентский стек синхронизации и фейковый
/// сервер: «создал офлайн — сеть появилась — всё на втором устройстве»;
/// удаление долга одной операцией и каскад сервера.
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
    String next() => uuid(1000 + ++counter);
    phone = await FinanceDevice.create(server, clock: clock, newId: next);
    pc = await FinanceDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Account account() => Account(
    id: uuid(1),
    name: 'Карта',
    kind: AccountKind.debitCard,
    openingBalance: 1000000,
    openingDate: '2026-01-01',
  );

  Debt debt(int n, String who, {int amount = 750000}) => Debt(
    id: uuid(n),
    direction: DebtDirection.owedToMe,
    counterparty: who,
    amount: amount,
    debtDate: '2026-09-01',
    dueDate: '2026-10-04',
  );

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
  }

  test('офлайн: долг, погашение и операция доезжают до второго устройства; '
      'состояние и баланс совпадают', () async {
    phone.device.remote.faults.offline = true;
    await phone.finance.createAccount(account());
    await phone.finance.createDebt(debt(10, 'Эмир'));
    final repaymentId = await phone.finance.addRepayment(
      debtId: uuid(10),
      amount: 250000,
      repaidOn: '2026-10-03',
      accountId: uuid(1),
      note: 'часть',
    );
    await phone.finance.addRepayment(
      debtId: uuid(10),
      amount: 50000,
      repaidOn: '2026-10-04',
    );
    expect(await phone.device.sync(), SyncOutcome.offline);
    phone.device.remote.faults.offline = false;
    expect(await phone.device.sync(), SyncOutcome.success);
    expect(await pc.device.sync(), SyncOutcome.success);

    final debts = await pc.finance.debts();
    expect(debts.single.counterparty, 'Эмир');
    expect(debts.single.dueDate, '2026-10-04');
    final repayments = await pc.finance.repayments(debtId: uuid(10));
    expect(repayments, hasLength(2));
    final linked = repayments.singleWhere((r) => r.id == repaymentId);
    expect(linked.note, 'часть');
    expect(linked.amount, 250000);
    // операция счёта пришла с debt_id, ссылка погашения на неё цела
    final tx = (await pc.finance.getTransaction(linked.transactionId!))!;
    expect(tx.debtId, uuid(10));
    expect(tx.kind, TransactionKind.income);
    expect(tx.source, TransactionSource.manual);
    expect(tx.status, TransactionStatus.confirmed);

    final a = await phone.finance.debtsOverview(today: '2026-10-05');
    final b = await pc.finance.debtsOverview(today: '2026-10-05');
    expect(b.byId(uuid(10))!.remaining, 450000);
    expect(b.byId(uuid(10))!.status, DebtStatus.partial);
    expect(b.byId(uuid(10))!.overdue, isTrue);
    expect(b.owedToMe, a.owedToMe);
    expect((await pc.finance.balances()).total, 1250000);
    // «доход» месяца не появился: операция с debt_id вне аналитики
    expect(TransactionFeed.of(await pc.finance.transactions()).months, isEmpty);
  });

  test('удаление долга — одна операция; сервер уносит погашения, '
      'операции с debt_id остаются', () async {
    await phone.finance.createAccount(account());
    await phone.finance.createDebt(debt(10, 'Эмир'));
    await phone.finance.createDebt(debt(11, 'Настя', amount: 260000));
    await phone.finance.addRepayment(
      debtId: uuid(10),
      amount: 100000,
      repaidOn: '2026-10-03',
      accountId: uuid(1),
    );
    await phone.finance.addRepayment(
      debtId: uuid(10),
      amount: 50000,
      repaidOn: '2026-10-04',
    );
    await phone.finance.addRepayment(
      debtId: uuid(11),
      amount: 60000,
      repaidOn: '2026-10-04',
    );
    await syncBoth();
    expect(await pc.finance.repayments(), hasLength(3));

    await phone.finance.deleteDebt(uuid(10));
    final queue = await phone.device.store.outbox();
    expect(queue, hasLength(1), reason: 'одна операция delete родителя');
    expect(queue.single.type, 'delete');
    expect(queue.single.table, 'debts');
    await syncBoth();

    // сервер унёс погашения долга; операция счёта жива
    final reps = server.snapshot('debt_repayments');
    final deleted = reps.values.where((r) => r['deleted_at'] != null);
    expect(deleted, hasLength(2));
    expect(
      reps.values.singleWhere((r) => r['deleted_at'] == null)['debt_id'],
      uuid(11),
    );
    final txs = server.snapshot('transactions');
    expect(txs.values.single['deleted_at'], isNull);
    expect(txs.values.single['debt_id'], uuid(10));
    // второе устройство: долг и его погашения скрыты, операция остаётся
    expect((await pc.finance.debts()).map((d) => d.id), [uuid(11)]);
    expect((await pc.finance.repayments()).map((r) => r.debtId), [uuid(11)]);
    expect(await pc.finance.transactions(), hasLength(1));
    expect((await pc.finance.balances()).total, 1100000);
    expect((await pc.finance.debtsOverview()).owedToMe, 200000);

    // восстановление долга возвращает его погашения
    await phone.finance.restoreDebt(uuid(10));
    await syncBoth();
    expect(await pc.finance.debts(), hasLength(2));
    expect(await pc.finance.repayments(), hasLength(3));
  });

  test(
    'правки разных полей долга и погашения с двух устройств сливаются',
    () async {
      await phone.finance.createDebt(debt(10, 'Эмир'));
      await phone.finance.createRepayment(
        DebtRepayment(
          id: uuid(20),
          debtId: uuid(10),
          amount: 100000,
          repaidOn: '2026-10-03',
        ),
      );
      await syncBoth();
      clock.advance(const Duration(minutes: 5));
      await phone.finance.updateDebt(
        (await phone.finance.getDebt(uuid(10)))!.copyWith(amount: 800000),
      );
      await pc.finance.updateDebt(
        (await pc.finance.getDebt(uuid(10)))!.copyWith(comment: 'на ремонт'),
      );
      await pc.finance.updateRepayment(
        (await pc.finance.getRepayment(uuid(20)))!.copyWith(note: 'нал'),
      );
      await syncBoth();
      final d = (await phone.finance.getDebt(uuid(10)))!;
      expect(d.amount, 800000);
      expect(d.comment, 'на ремонт');
      expect((await phone.finance.getRepayment(uuid(20)))!.note, 'нал');
      expect((await pc.finance.debtState(uuid(10)))!.remaining, 700000);
    },
  );
}
