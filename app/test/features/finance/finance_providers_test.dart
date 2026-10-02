import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/fakes.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

/// Хранилище, у которого поток одной таблицы падает.
class _BrokenStore extends SyncStore {
  _BrokenStore(SyncStore inner, this.broken)
    : super(db: inner.db, registry: inner.registry, nowMs: inner.nowMs);

  final String broken;

  @override
  Stream<List<Json>> watchVisibleRows(
    String table, {
    String? where,
    List<Object?> args = const [],
    String? orderBy,
  }) => table == broken
      ? Stream<List<Json>>.error(StateError('сбой $table'))
      : super.watchVisibleRows(
          table,
          where: where,
          args: args,
          orderBy: orderBy,
        );
}

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice d;
  late ProviderContainer container;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    d = await FinanceDevice.create(
      server,
      clock: clock,
      newId: () => uuid(900 + ++counter),
    );
    container = ProviderContainer(
      overrides: [
        syncStoreProvider.overrideWithValue(d.device.store),
        syncEngineProvider.overrideWithValue(d.device.engine),
        connectivityMonitorProvider.overrideWithValue(FakeConnectivity()),
        clockProvider.overrideWithValue(() => d.device.clock.now),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await d.close();
    await server.dispose();
  });

  /// Ждёт, пока провайдер отдаст данные, удовлетворяющие [ok].
  Future<T> until<T>(
    ProviderListenable<AsyncValue<T>> provider,
    bool Function(T value) ok,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 400; i++) {
      final v = container.read(provider);
      if (v.hasValue && ok(v.requireValue)) return v.requireValue;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Провайдер не отдал ожидаемых данных: ${container.read(provider)}');
  }

  Account account(int n, String name, {int opening = 0, bool inTotal = true}) =>
      Account(
        id: uuid(n),
        name: name,
        kind: AccountKind.debitCard,
        openingBalance: opening,
        openingDate: '2026-01-01',
        includeInTotal: inTotal,
      );

  FinanceTransaction tx(
    int n,
    int from, {
    int amount = 1000,
    TransactionKind kind = TransactionKind.expense,
    int? to,
    DateTime? at,
    String? category,
    String? merchant,
  }) => FinanceTransaction(
    id: uuid(n),
    kind: kind,
    accountId: uuid(from),
    toAccountId: to == null ? null : uuid(to),
    amount: amount,
    occurredAt: at ?? DateTime.utc(2026, 10, 4, 12),
    categoryId: category,
    merchant: merchant,
  );

  FinanceRepository repo() => d.finance;

  test('провайдер репозитория строится из syncStoreProvider', () {
    expect(container.read(financeRepositoryProvider), isA<FinanceRepository>());
  });

  test('счета: все и активные, живые обновления', () async {
    expect(
      await until(accountsProvider, (l) => l.isEmpty),
      isEmpty,
      reason: 'пустое состояние — данные, а не загрузка',
    );
    await repo().createAccount(account(1, 'Карта'));
    await repo().createAccount(account(2, 'Старый'));
    await repo().archiveAccount(uuid(2));
    final all = await until(accountsProvider, (l) => l.length == 2);
    expect(all.map((a) => a.name), ['Карта', 'Старый']);
    final active = await until(activeAccountsProvider, (l) => l.length == 1);
    expect(active.single.name, 'Карта');
  });

  test('категории', () async {
    await repo().createCategory(
      FinanceCategory(id: uuid(5), name: 'Еда', kind: CategoryKind.expense),
    );
    final list = await until(categoriesProvider, (l) => l.length == 1);
    expect(list.single.name, 'Еда');
  });

  test('балансы: по счетам, общий, один счёт', () async {
    await repo().createAccount(account(1, 'Карта', opening: 100000));
    await repo().createAccount(
      account(2, 'Копилка', opening: 5000, inTotal: false),
    );
    await repo().createTransaction(tx(10, 1, amount: 3000));
    await repo().createTransaction(
      tx(11, 1, amount: 2000, to: 2, kind: TransactionKind.transfer),
    );
    final b = await until(
      financeBalancesProvider,
      (b) => b.byAccount.length == 2,
    );
    expect(b.of(uuid(1)), 100000 - 3000 - 2000);
    expect(b.of(uuid(2)), 5000 + 2000);
    expect(b.total, 95000, reason: 'копилка вне общего баланса');
    expect(await until(totalBalanceProvider, (t) => t == 95000), 95000);
    expect(
      await until(accountBalanceProvider(uuid(2)), (t) => t == 7000),
      7000,
    );
    // сверка двигает баланс
    await repo().reconcile(accountId: uuid(1), actualBalance: 80000);
    expect(await until(totalBalanceProvider, (t) => t == 80000), 80000);
  });

  test('сверки: точки и корректировки счёта', () async {
    await repo().createAccount(account(1, 'Карта', opening: 100000));
    await repo().createTransaction(tx(10, 1, amount: 3000));
    final adj = await repo().reconcile(
      accountId: uuid(1),
      actualBalance: 90000,
    );
    expect(adj.adjustment, -7000);
    final cps = await until(
      checkpointsOfProvider(uuid(1)),
      (l) => l.length == 1,
    );
    expect(cps.single.actualBalance, 90000);
    expect(
      (await until(checkpointsProvider, (l) => l.length == 1)).single.id,
      cps.single.id,
    );
    final lines = await until(
      accountAdjustmentsProvider(uuid(1)),
      (l) => l.length == 1,
    );
    expect(lines.single.expected, 97000);
    expect(lines.single.adjustment, -7000);
    expect(
      await until(accountAdjustmentsProvider(uuid(77)), (l) => l.isEmpty),
      isEmpty,
    );
    expect(
      await until(checkpointsOfProvider(uuid(77)), (l) => l.isEmpty),
      isEmpty,
    );
  });

  test(
    'лента: фильтр, порядок и итоги месяцев для липких заголовков',
    () async {
      await repo().createAccount(account(1, 'Карта', opening: 100000));
      await repo().createAccount(account(2, 'Наличные'));
      await repo().createTransaction(
        tx(10, 1, at: DateTime.utc(2026, 9, 10, 9), merchant: 'А'),
      );
      await repo().createTransaction(
        tx(
          11,
          1,
          amount: 5000,
          kind: TransactionKind.income,
          at: DateTime.utc(2026, 10, 1, 9),
        ),
      );
      await repo().createTransaction(
        tx(12, 2, amount: 700, at: DateTime.utc(2026, 10, 2, 9), merchant: 'Б'),
      );
      await repo().createTransaction(
        tx(
          13,
          1,
          amount: 9999,
          to: 2,
          kind: TransactionKind.transfer,
          at: DateTime.utc(2026, 10, 3, 9),
        ),
      );
      final all = await until(
        transactionFeedProvider(const TransactionFilter()),
        (f) => f.items.length == 4,
      );
      expect(all.items.map((t) => t.id), [
        uuid(13),
        uuid(12),
        uuid(11),
        uuid(10),
      ]);
      expect(
        all.months['2026-10'],
        const MonthTotals(month: '2026-10', income: 5000, expense: 700),
      );
      expect(all.months['2026-10']!.net, 4300);
      expect(all.months['2026-09']!.expense, 1000);
      expect(all.totalsFor(all.items.first).month, '2026-10');
      final empty = FinanceTransaction(
        id: 'x',
        kind: TransactionKind.transfer,
        accountId: 'a',
        toAccountId: 'b',
        amount: 1,
        occurredAt: DateTime.utc(2027, 1, 5),
      );
      expect(all.totalsFor(empty).net, 0);
      expect(all.months.values.first.toString(), contains('MonthTotals'));

      final one = await until(
        transactionFeedProvider(TransactionFilter(accountId: uuid(2))),
        (f) => f.items.length == 2,
      );
      expect(one.items.map((t) => t.id), [uuid(13), uuid(12)]);
      expect(
        one.months['2026-10']!.expense,
        700,
        reason: 'перевод не в итогах',
      );
    },
  );

  test('состояние фильтра ленты', () async {
    final notifier = container.read(transactionFilterProvider.notifier);
    expect(container.read(transactionFilterProvider).isEmpty, isTrue);
    notifier
      ..setAccount(uuid(1))
      ..setCategory(uuid(2))
      ..setKind(TransactionKind.income)
      ..setPeriod(from: '2026-10-01', to: '2026-10-31')
      ..setQuery('кофе');
    var f = container.read(transactionFilterProvider);
    expect(f.accountId, uuid(1));
    expect(f.categoryId, uuid(2));
    expect(f.kind, TransactionKind.income);
    expect((f.from, f.to), ('2026-10-01', '2026-10-31'));
    expect(f.query, 'кофе');
    notifier.setWithoutCategory(value: true);
    f = container.read(transactionFilterProvider);
    expect(f.withoutCategory, isTrue);
    expect(f.categoryId, isNull);
    notifier.setCategory(uuid(3));
    expect(container.read(transactionFilterProvider).withoutCategory, isFalse);
    notifier.setWithoutCategory(value: false);
    expect(container.read(transactionFilterProvider).categoryId, uuid(3));
    expect(
      container.read(transactionFilterProvider) ==
          container.read(transactionFilterProvider).copyWith(),
      isTrue,
    );
    expect(
      container.read(transactionFilterProvider).hashCode,
      container.read(transactionFilterProvider).copyWith().hashCode,
    );
    notifier.reset();
    expect(container.read(transactionFilterProvider).isEmpty, isTrue);

    await repo().createAccount(account(1, 'Карта', opening: 1000));
    await repo().createTransaction(tx(10, 1, merchant: 'Кофе'));
    await repo().createTransaction(tx(11, 1, merchant: 'Хлеб'));
    notifier.setQuery('хлеб');
    final feed = await until(
      filteredTransactionFeedProvider,
      (f) => f.items.length == 1,
    );
    expect(feed.items.single.id, uuid(11));
  });

  test('провайдеры сообщают об ошибках и состоянии загрузки', () async {
    // до первого события поток ещё не отдал данных
    expect(container.read(financeBalancesProvider).isLoading, isTrue);
    expect(
      container.read(accountAdjustmentsProvider(uuid(1))).isLoading,
      isTrue,
    );
    expect(
      container
          .read(transactionFeedProvider(const TransactionFilter()))
          .isLoading,
      isTrue,
    );
  });

  test('засев категорий ждёт первой синхронизации', () async {
    final sub = container.listen(financeBootstrapProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(financeBootstrapProvider.future), 0);
    expect(await repo().categories(), isEmpty);
    expect(await d.device.sync(), isNotNull);
    for (var i = 0; i < 400; i++) {
      if ((await repo().categories()).length == 28) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await repo().categories(), hasLength(28));
  });

  for (final broken in [
    'accounts',
    'transactions',
    'balance_checkpoints',
    'categories',
  ]) {
    test('ошибка потока $broken доходит до провайдеров', () async {
      final failing = ProviderContainer(
        overrides: [
          syncStoreProvider.overrideWithValue(
            _BrokenStore(d.device.store, broken),
          ),
        ],
      );
      addTearDown(failing.dispose);
      Future<bool> fails<T>(ProviderListenable<AsyncValue<T>> p) async {
        final sub = failing.listen(p, (_, _) {});
        addTearDown(sub.close);
        for (var i = 0; i < 400; i++) {
          if (failing.read(p).hasError) return true;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return false;
      }

      final isFeedBroken = broken == 'transactions' || broken == 'categories';
      final affectsBalances = broken != 'categories';
      if (affectsBalances) {
        expect(await fails(financeBalancesProvider), isTrue);
        expect(await fails(accountAdjustmentsProvider(uuid(1))), isTrue);
      }
      if (isFeedBroken) {
        expect(
          await fails(transactionFeedProvider(const TransactionFilter())),
          isTrue,
        );
      }
    });
  }
}
