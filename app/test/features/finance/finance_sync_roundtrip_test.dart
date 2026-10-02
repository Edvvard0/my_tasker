import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

/// Таблицы Финансов через общий клиентский стек синхронизации и фейковый
/// сервер: «сделал офлайн — появилась сеть — данные на втором устройстве».
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

  Account account(int n, String name, {int opening = 100000}) => Account(
    id: uuid(n),
    name: name,
    kind: AccountKind.debitCard,
    openingBalance: opening,
    openingDate: '2026-01-01',
  );

  FinanceTransaction tx(
    int n, {
    required int from,
    int? to,
    int amount = 1000,
    TransactionKind kind = TransactionKind.expense,
  }) => FinanceTransaction(
    id: uuid(n),
    kind: kind,
    accountId: uuid(from),
    toAccountId: to == null ? null : uuid(to),
    amount: amount,
    occurredAt: DateTime.utc(2026, 10, 4, 12),
  );

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
  }

  test(
    'офлайн: счета, операции и сверка доезжают до второго устройства',
    () async {
      phone.device.remote.faults.offline = true;
      await phone.finance.createAccount(account(1, 'Карта'));
      await phone.finance.createAccount(account(2, 'Наличные', opening: 0));
      await phone.finance.createCategory(
        const FinanceCategory(
          id: '01900000-0000-7000-8000-000000000020',
          name: 'Еда',
          kind: CategoryKind.expense,
        ),
      );
      await phone.finance.createTransaction(
        tx(
          10,
          from: 1,
          amount: 45050,
        ).copyWith(categoryId: uuid(20), merchant: 'Магнит'),
      );
      await phone.finance.createTransaction(
        tx(11, from: 1, to: 2, amount: 5000, kind: TransactionKind.transfer),
      );
      await phone.finance.reconcile(accountId: uuid(1), actualBalance: 90000);
      expect(await phone.device.sync(), SyncOutcome.offline);
      phone.device.remote.faults.offline = false;
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);

      final accounts = await pc.finance.accounts();
      expect(accounts.map((a) => a.name), ['Карта', 'Наличные']);
      final transactions = await pc.finance.transactions();
      expect(transactions, hasLength(2));
      final expense = transactions.singleWhere((t) => t.id == uuid(10));
      expect(expense.amount, 45050);
      expect(expense.merchant, 'Магнит');
      expect(expense.source, TransactionSource.manual);
      expect(expense.status, TransactionStatus.confirmed);
      expect(expense.occurredAt, DateTime.utc(2026, 10, 4, 12));
      final transfer = transactions.singleWhere((t) => t.id == uuid(11));
      expect(transfer.toAccountId, uuid(2));
      final cps = await pc.finance.checkpoints();
      expect(cps.single.actualBalance, 90000);
      // баланс считается одинаково на обоих устройствах
      final a = await phone.finance.balances();
      final b = await pc.finance.balances();
      expect(b.byAccount, a.byAccount);
      expect(b.total, a.total);
      expect(b.of(uuid(2)), 5000);
    },
  );

  test(
    'удаление счёта одной операцией каскадом скрывает операции и перевод',
    () async {
      await phone.finance.createAccount(account(1, 'Карта'));
      await phone.finance.createAccount(account(2, 'Наличные', opening: 0));
      await phone.finance.createTransaction(tx(10, from: 1));
      await phone.finance.createTransaction(tx(11, from: 2, amount: 300));
      await phone.finance.createTransaction(
        tx(12, from: 1, to: 2, amount: 5000, kind: TransactionKind.transfer),
      );
      await phone.finance.createTransaction(
        tx(13, from: 2, to: 1, amount: 700, kind: TransactionKind.transfer),
      );
      await phone.finance.reconcile(accountId: uuid(1), actualBalance: 1);
      await syncBoth();
      expect(await pc.finance.transactions(), hasLength(4));

      // удаляем счёт 1 на телефоне
      await phone.finance.deleteAccount(uuid(1));
      final queue = await phone.device.store.outbox();
      expect(queue, hasLength(1), reason: 'одна операция delete родителя');
      expect(queue.single.type, 'delete');
      expect(queue.single.table, 'accounts');
      await syncBoth();

      // сервер унёс в корзину операции обеих сторон перевода и точку сверки
      final rows = server.snapshot('transactions');
      expect(rows[uuid(10)]!['deleted_at'], isNotNull);
      expect(rows[uuid(12)]!['deleted_at'], isNotNull);
      expect(rows[uuid(13)]!['deleted_at'], isNotNull);
      expect(rows[uuid(11)]!['deleted_at'], isNull);
      expect(
        server.snapshot('balance_checkpoints').values.single['deleted_at'],
        isNotNull,
      );
      // на втором устройстве видна только операция счёта 2
      expect((await pc.finance.transactions()).map((t) => t.id), [uuid(11)]);
      expect(await pc.finance.checkpoints(), isEmpty);
      final balances = await pc.finance.balances();
      expect(balances.of(uuid(2)), -300);
      expect(balances.total, -300);

      // восстановление счёта возвращает всё, что ушло вместе с ним
      await phone.finance.restoreAccount(uuid(1));
      await syncBoth();
      expect(await pc.finance.transactions(), hasLength(4));
      expect(await pc.finance.checkpoints(), hasLength(1));
    },
  );

  test(
    'удаление счёта-получателя скрывает перевод, пока счёт в корзине',
    () async {
      await phone.finance.createAccount(account(1, 'Карта'));
      await phone.finance.createAccount(account(2, 'Копилка', opening: 0));
      await phone.finance.createTransaction(
        tx(12, from: 1, to: 2, amount: 5000, kind: TransactionKind.transfer),
      );
      await syncBoth();
      expect((await pc.finance.balances()).total, 100000 - 5000 + 5000);
      await pc.finance.deleteAccount(uuid(2));
      await syncBoth();
      expect(await phone.finance.transactions(), isEmpty);
      // деньги не «уходят в никуда»: перевод не учитывается ни на одном счёте
      expect((await phone.finance.balances()).of(uuid(1)), 100000);
    },
  );

  test('предустановленные категории: два устройства — один набор', () async {
    await phone.finance.ensurePresetCategories(requireFirstSync: false);
    await pc.finance.ensurePresetCategories(requireFirstSync: false);
    await syncBoth();
    expect(server.snapshot('categories'), hasLength(28));
    expect(await phone.finance.categories(), hasLength(28));
    expect(await pc.finance.categories(), hasLength(28));
    expect(
      server.snapshot('categories').keys,
      containsAll([presetCategoryId('expense.groceries')]),
    );
    // после полной синхронизации ничего не создаётся повторно
    expect(await phone.finance.ensurePresetCategories(), 0);

    // удалил на одном — не воскресает на другом после синхронизации
    await phone.finance.deleteCategory(presetCategoryId('expense.other'));
    await syncBoth();
    expect(await pc.finance.ensurePresetCategories(), 0);
    expect(await pc.finance.categories(), hasLength(27));
  });

  test(
    'правки разных полей одной операции с двух устройств сливаются',
    () async {
      await phone.finance.createAccount(account(1, 'Карта'));
      await phone.finance.createTransaction(tx(10, from: 1));
      await syncBoth();
      clock.advance(const Duration(minutes: 5));
      await phone.finance.updateTransaction(
        (await phone.finance.getTransaction(uuid(10)))!.copyWith(amount: 2500),
      );
      await pc.finance.updateTransaction(
        (await pc.finance.getTransaction(uuid(10)))!
            .copyWith(merchant: 'Лента'),
      );
      await syncBoth();
      final t = (await phone.finance.getTransaction(uuid(10)))!;
      expect(t.amount, 2500);
      expect(t.merchant, 'Лента');
      final feed = TransactionFeed.of(await pc.finance.transactions());
      expect(feed.months['2026-10']!.expense, 2500);
    },
  );
}
