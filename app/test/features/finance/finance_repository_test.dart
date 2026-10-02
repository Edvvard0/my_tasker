import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

Account _account(
  int n, {
  String name = 'Карта',
  AccountKind kind = AccountKind.debitCard,
  int opening = 100000,
  bool inTotal = true,
  bool archived = false,
}) => Account(
  id: uuid(n),
  name: name,
  kind: kind,
  openingBalance: opening,
  openingDate: '2026-01-01',
  includeInTotal: inTotal,
  archived: archived,
);

FinanceTransaction _tx(
  int n, {
  required int account,
  TransactionKind kind = TransactionKind.expense,
  int? to,
  int amount = 1000,
  DateTime? at,
  String? category,
  String? merchant,
  String? comment,
}) => FinanceTransaction(
  id: uuid(n),
  kind: kind,
  accountId: uuid(account),
  toAccountId: to == null ? null : uuid(to),
  amount: amount,
  occurredAt: at ?? DateTime.utc(2026, 10, 4, 12),
  categoryId: category,
  merchant: merchant,
  comment: comment,
);

FinanceCategory _category(
  int n,
  String name, {
  CategoryKind kind = CategoryKind.expense,
  int? parent,
}) => FinanceCategory(
  id: uuid(n),
  name: name,
  kind: kind,
  parentId: parent == null ? null : uuid(parent),
);

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice d;
  late FinanceRepository repo;
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
    repo = d.finance;
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  Future<List<OutboxOp>> ops() => d.device.store.outbox();

  group('счета', () {
    test(
      'создание, чтение, порядок по созданию; название обрезается',
      () async {
        await repo.createAccount(_account(2, name: '  Вторая '));
        clock.advance(const Duration(seconds: 1));
        await repo.createAccount(_account(1, name: 'Первая'));
        expect(repo.newId(), uuid(901));
        final all = await repo.accounts();
        expect(all.map((a) => a.name), ['Вторая', 'Первая']);
        final got = (await repo.getAccount(uuid(2)))!;
        expect(got.kind, AccountKind.debitCard);
        expect(got.openingBalance, 100000);
        expect(got.bank, isNull);
        expect(await repo.getAccount('нет'), isNull);
      },
    );

    test('пустые необязательные строки становятся null', () async {
      await repo.createAccount(
        _account(1).copyWith(bank: '  ', cardLast4: ' 1234 '),
      );
      final got = (await repo.getAccount(uuid(1)))!;
      expect(got.bank, isNull);
      expect(got.cardLast4, '1234');
    });

    test('правка отправляет только изменившиеся колонки', () async {
      await repo.createAccount(_account(1));
      await d.device
          .sync(); // создание уже ушло: правка идёт отдельной операцией
      final before = (await ops()).length;
      await repo.updateAccount(
        (await repo.getAccount(uuid(1)))!.copyWith(name: 'Новая'),
      );
      final all = await ops();
      expect(all, hasLength(before + 1));
      expect(all.last.fields, {'name': 'Новая'});
      // без изменений операции нет
      await repo.updateAccount((await repo.getAccount(uuid(1)))!);
      expect(await ops(), hasLength(before + 1));
      await expectLater(
        repo.updateAccount(_account(77)),
        throwsA(isA<StateError>()),
      );
    });

    test('архивация скрывает счёт из списка, но не из расчётов', () async {
      await repo.createAccount(_account(1, opening: 5000));
      await repo.createAccount(_account(2, opening: 7000));
      await repo.archiveAccount(uuid(1));
      expect((await repo.accounts()).map((a) => a.id), [uuid(2)]);
      expect(await repo.accounts(includeArchived: true), hasLength(2));
      final balances = await repo.balances();
      expect(balances.total, 12000);
      await repo.archiveAccount(uuid(1), archived: false);
      expect(await repo.accounts(), hasLength(2));
      final count = (await ops()).length;
      await repo.archiveAccount(uuid(1), archived: false); // уже так
      await repo.archiveAccount('нет');
      expect(await ops(), hasLength(count));
    });

    test('значения проверяются до записи в outbox', () async {
      final bad = <Account>[
        _account(1, name: '   '),
        _account(1, name: 'x' * 101),
        _account(1).copyWith(bank: 'b' * 101),
        _account(1).copyWith(cardLast4: '12'),
        _account(1, kind: AccountKind.cash).copyWith(cardLast4: '1234'),
        _account(1).copyWith(creditLimit: 5),
        _account(1, kind: AccountKind.creditCard).copyWith(creditLimit: -1),
        _account(1, opening: 100000000000000),
        _account(1).copyWith(openingDate: '2026-02-30'),
      ];
      for (final a in bad) {
        await expectLater(
          repo.createAccount(a),
          throwsA(isA<ValidationError>()),
          reason: a.name,
        );
      }
      expect(await ops(), isEmpty);
    });

    test('удаление счёта — одна операция delete, дети скрываются', () async {
      await repo.createAccount(_account(1));
      await repo.createAccount(_account(2));
      await repo.createTransaction(_tx(10, account: 1));
      await repo.createTransaction(
        _tx(11, kind: TransactionKind.transfer, account: 2, to: 1),
      );
      await repo.createTransaction(_tx(12, account: 2));
      final bef = (await ops()).length;
      await repo.deleteAccount(uuid(1));
      final added = (await ops()).skip(bef).toList();
      expect(added, hasLength(1));
      expect(added.single.type, 'delete');
      expect(added.single.table, 'accounts');
      // перевод 2 -> 1 и расход по 1 не видны, расход по 2 виден
      final seen = await repo.transactions();
      expect(seen.map((t) => t.id), [uuid(12)]);
      expect((await repo.balances()).total, 100000 - 1000);
      await repo.restoreAccount(uuid(1));
      expect(await repo.transactions(), hasLength(3));
    });
  });

  group('категории', () {
    test('создание, подкатегория, фильтр по виду', () async {
      await repo.createCategory(_category(1, 'Еда'));
      await repo.createCategory(_category(2, 'Кафе', parent: 1));
      await repo.createCategory(
        _category(3, 'Зарплата', kind: CategoryKind.income),
      );
      final all = await repo.categories();
      expect(all.map((c) => c.name), ['Еда', 'Зарплата', 'Кафе']);
      expect(
        (await repo.categories(kind: CategoryKind.income)).single.name,
        'Зарплата',
      );
      expect(((await repo.getCategory(uuid(2)))!).parentId, uuid(1));
      expect(await repo.getCategory('нет'), isNull);
    });

    test('родитель: только верхний уровень того же вида', () async {
      await repo.createCategory(_category(1, 'Еда'));
      await repo.createCategory(_category(2, 'Кафе', parent: 1));
      await repo.createCategory(
        _category(3, 'Зарплата', kind: CategoryKind.income),
      );
      for (final bad in [
        _category(4, 'Уровень три', parent: 2),
        _category(4, 'Другой вид', kind: CategoryKind.income, parent: 1),
        _category(4, 'Нет родителя', parent: 99),
        _category(4, 'Сам себе', parent: 4),
        _category(4, ' '),
      ]) {
        await expectLater(
          repo.createCategory(bad),
          throwsA(isA<ValidationError>()),
          reason: bad.name,
        );
      }
      // у категории с подкатегориями родителя быть не может
      await repo.createCategory(_category(5, 'Прочее'));
      await expectLater(
        repo.updateCategory(
          ((await repo.getCategory(uuid(1)))!).copyWith(parentId: uuid(5)),
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('правка: только изменившиеся колонки; ключ неизменяем', () async {
      await repo.createCategory(_category(1, 'Еда'));
      await d.device.sync();
      final bef = (await ops()).length;
      await repo.updateCategory(
        ((await repo.getCategory(uuid(1)))!)
            .copyWith(name: 'Продукты', icon: 'x', color: '#aabbcc'),
      );
      expect((await ops()).last.fields, {
        'name': 'Продукты',
        'icon': 'x',
        'color': '#aabbcc',
      });
      await repo.updateCategory((await repo.getCategory(uuid(1)))!);
      expect(await ops(), hasLength(bef + 1));
      await expectLater(
        repo.updateCategory(
          FinanceCategory(
            id: uuid(1),
            name: 'Еда',
            kind: CategoryKind.expense,
            systemKey: 'expense.other',
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.updateCategory(_category(55, 'Нет')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.createCategory(_category(6, 'Цвет').copyWith(color: 'red')),
        throwsA(isA<ValidationError>()),
      );
    });

    test('удаление категории ничего не уносит', () async {
      await repo.createAccount(_account(1));
      await repo.createCategory(_category(1, 'Еда'));
      await repo.createCategory(_category(2, 'Кафе', parent: 1));
      await repo.createTransaction(_tx(10, account: 1, category: uuid(1)));
      await repo.deleteCategory(uuid(1));
      expect((await repo.categories()).map((c) => c.id), [uuid(2)]);
      final t = (await repo.getTransaction(uuid(10)))!;
      expect(t.categoryId, uuid(1));
      expect(await repo.transactions(), hasLength(1));
      await repo.restoreCategory(uuid(1));
      expect(await repo.categories(), hasLength(2));
    });

    test('засев: только после первой синхронизации и не воскрешает', () async {
      expect(await repo.ensurePresetCategories(), 0);
      expect(await repo.categories(), isEmpty);

      expect(await repo.ensurePresetCategories(requireFirstSync: false), 28);
      final all = await repo.categories();
      expect(all, hasLength(28));
      final taxi = all.singleWhere(
        (c) => c.systemKey == 'expense.transport.taxi',
      );
      expect(taxi.id, presetCategoryId('expense.transport.taxi'));
      expect(taxi.parentId, presetCategoryId('expense.transport'));
      expect(taxi.icon, 'local_taxi');
      expect(await repo.ensurePresetCategories(requireFirstSync: false), 0);

      // пользователь удалил категорию: она не воскресает, даже в корзине
      await repo.deleteCategory(presetCategoryId('income.other'));
      expect(await repo.ensurePresetCategories(requireFirstSync: false), 0);
      expect(await repo.categories(), hasLength(27));

      // после успешной синхронизации — с настройкой по умолчанию
      expect(await d.device.sync(), isNotNull);
      expect(await repo.ensurePresetCategories(), 0);
    });

    test('после первой полной синхронизации недостающие создаются', () async {
      expect(await d.device.sync(), isNotNull);
      expect(await repo.ensurePresetCategories(), 28);
    });
  });

  group('операции', () {
    late Future<void> Function() seed;

    setUp(() {
      seed = () async {
        await repo.createAccount(_account(1));
        await repo.createAccount(
          _account(2, name: 'Наличные', kind: AccountKind.cash, opening: 0),
        );
        await repo.createCategory(_category(20, 'Еда'));
        await repo.createCategory(_category(21, 'Кафе', parent: 20));
        await repo.createCategory(_category(22, 'Авто'));
        await repo.createCategory(
          _category(23, 'Зарплата', kind: CategoryKind.income),
        );
      };
    });

    test('создание: manual + confirmed, обрезка текстов', () async {
      await seed();
      await repo.createTransaction(
        _tx(10, account: 1, merchant: '  Магнит ', comment: ' '),
      );
      final t = (await repo.getTransaction(uuid(10)))!;
      expect(t.source, TransactionSource.manual);
      expect(t.status, TransactionStatus.confirmed);
      expect(t.merchant, 'Магнит');
      expect(t.comment, isNull);
      expect(t.occurredAt, DateTime.utc(2026, 10, 4, 12));
      expect(t.moscowDay, '2026-10-04');
      expect(t.isTransfer, isFalse);
      expect(await repo.getTransaction('нет'), isNull);
    });

    test('проверки значений и ссылок', () async {
      await seed();
      final cases = <FinanceTransaction>[
        _tx(10, account: 1, amount: 0),
        _tx(10, account: 1, amount: 100000000000000),
        _tx(10, account: 1, at: DateTime.utc(2014, 12, 31, 23)),
        _tx(10, account: 1, merchant: 'x' * 201),
        _tx(10, kind: TransactionKind.transfer, account: 1),
        _tx(10, kind: TransactionKind.transfer, account: 1, to: 1),
        _tx(10, account: 1, to: 2),
        _tx(10, account: 99), // счёта нет
        _tx(10, kind: TransactionKind.transfer, account: 1, to: 99),
        _tx(10, account: 1, category: uuid(23)), // категория другого вида
      ];
      for (final c in cases) {
        await expectLater(
          repo.createTransaction(c),
          throwsA(isA<ValidationError>()),
          reason: '${c.kind} ${c.amount} ${c.occurredAt}',
        );
      }
      // перевод с категорией, платёж у расхода, источник без платежа
      final tx = _tx(10, account: 1);
      for (final c in [
        FinanceTransaction(
          id: uuid(10),
          kind: TransactionKind.transfer,
          accountId: uuid(1),
          toAccountId: uuid(2),
          amount: 5,
          occurredAt: tx.occurredAt,
          categoryId: uuid(20),
        ),
        FinanceTransaction(
          id: uuid(10),
          kind: TransactionKind.expense,
          accountId: uuid(1),
          amount: 5,
          occurredAt: tx.occurredAt,
          workPaymentId: uuid(50),
        ),
        FinanceTransaction(
          id: uuid(10),
          kind: TransactionKind.income,
          accountId: uuid(1),
          amount: 5,
          occurredAt: tx.occurredAt,
          source: TransactionSource.workPayment,
        ),
      ]) {
        await expectLater(
          repo.createTransaction(c),
          throwsA(isA<ValidationError>()),
        );
      }
      expect(await repo.transactions(), isEmpty);
    });

    test('правка: связанная группа уходит целиком', () async {
      await seed();
      await repo.createTransaction(_tx(10, account: 1, category: uuid(20)));
      await d.device.sync();
      await repo.updateTransaction(
        ((await repo.getTransaction(uuid(10)))!)
            .copyWith(amount: 2500, merchant: 'Лента'),
      );
      expect((await ops()).last.fields, {'amount': 2500, 'merchant': 'Лента'});
      await d.device.sync();
      // расход -> перевод: kind, куда, категория и остальная группа вместе
      await repo.updateTransaction(
        ((await repo.getTransaction(uuid(10)))!).copyWith(
          kind: TransactionKind.transfer,
          toAccountId: uuid(2),
          categoryId: null,
        ),
      );
      final fields = (await ops()).last.fields!;
      expect(fields.keys.toSet(), {
        'kind',
        'to_account_id',
        'category_id',
        'work_payment_id',
        'debt_id',
        'source',
      });
      expect(fields['kind'], 'transfer');
      expect(fields['to_account_id'], uuid(2));
      // без изменений — без операции
      final count = (await ops()).length;
      await repo.updateTransaction((await repo.getTransaction(uuid(10)))!);
      expect(await ops(), hasLength(count));
      await expectLater(
        repo.updateTransaction(_tx(77, account: 1)),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.updateTransaction(
          ((await repo.getTransaction(uuid(10)))!).copyWith(amount: 0),
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('удаление и восстановление операции', () async {
      await seed();
      await repo.createTransaction(_tx(10, account: 1));
      await repo.deleteTransaction(uuid(10));
      expect(await repo.transactions(), isEmpty);
      await repo.restoreTransaction(uuid(10));
      expect(await repo.transactions(), hasLength(1));
    });

    test('фильтры: счёт, категория, вид, период, поиск', () async {
      await seed();
      Future<void> add(FinanceTransaction t) => repo.createTransaction(t);
      await add(
        _tx(
          10,
          account: 1,
          amount: 150000,
          category: uuid(20),
          merchant: 'Магнит',
          at: DateTime.utc(2026, 9, 30, 20, 59, 59), // 30 сентября МСК
        ),
      );
      await add(
        _tx(
          11,
          account: 1,
          amount: 45050,
          category: uuid(21),
          merchant: ' ПЯТЁРОЧКА  ',
          comment: 'К ужину',
          at: DateTime.utc(2026, 9, 30, 21), // 1 октября МСК
        ),
      );
      await add(_tx(12, account: 2, amount: 700, category: uuid(22)));
      await add(
        _tx(
          13,
          kind: TransactionKind.income,
          account: 2,
          amount: 9000000,
          category: uuid(23),
          at: DateTime.utc(2026, 10, 3, 10),
        ),
      );
      await add(
        _tx(
          14,
          kind: TransactionKind.transfer,
          account: 1,
          to: 2,
          amount: 5000,
          at: DateTime.utc(2026, 10, 2, 10),
        ),
      );
      Future<List<String>> ids(TransactionFilter f) async => [
        for (final t in await repo.transactions(filter: f)) t.id,
      ];
      // новые сверху
      expect(await ids(const TransactionFilter()), [
        uuid(12),
        uuid(13),
        uuid(14),
        uuid(11),
        uuid(10),
      ]);
      // счёт: и по account_id, и по to_account_id
      expect(await ids(TransactionFilter(accountId: uuid(2))), [
        uuid(12),
        uuid(13),
        uuid(14),
      ]);
      // категория включает подкатегории
      expect(await ids(TransactionFilter(categoryId: uuid(20))), [
        uuid(11),
        uuid(10),
      ]);
      expect(await ids(TransactionFilter(categoryId: uuid(21))), [uuid(11)]);
      expect(await ids(const TransactionFilter(withoutCategory: true)), [
        uuid(14),
      ]);
      expect(await ids(const TransactionFilter(kind: TransactionKind.income)), [
        uuid(13),
      ]);
      // период по московским датам, границы включительно
      expect(
        await ids(
          const TransactionFilter(from: '2026-10-01', to: '2026-10-02'),
        ),
        [uuid(14), uuid(11)],
      );
      expect(await ids(const TransactionFilter(to: '2026-09-30')), [uuid(10)]);
      // поиск: мерчант без регистра и лишних пробелов, комментарий, сумма
      expect(await ids(const TransactionFilter(query: 'пятёрочка')), [
        uuid(11),
      ]);
      expect(await ids(const TransactionFilter(query: 'ужину')), [uuid(11)]);
      expect(await ids(const TransactionFilter(query: '1 500')), [uuid(10)]);
      expect(await ids(const TransactionFilter(query: '450,50')), [uuid(11)]);
      expect(await ids(const TransactionFilter(query: 'нет такого')), isEmpty);
      // комбинация
      expect(
        await ids(
          TransactionFilter(accountId: uuid(1), kind: TransactionKind.expense),
        ),
        [uuid(11), uuid(10)],
      );
      expect(const TransactionFilter().isEmpty, isTrue);
      expect(const TransactionFilter(query: 'x').isEmpty, isFalse);
    });

    test('watchTransactions отдаёт новые данные', () async {
      await seed();
      final stream = repo.watchTransactions(
        filter: TransactionFilter(accountId: uuid(1)),
      );
      final seen = <int>[];
      final sub = stream.listen((l) => seen.add(l.length));
      await pumpEventQueue();
      await repo.createTransaction(_tx(10, account: 1));
      await pumpEventQueue();
      await repo.createTransaction(_tx(11, account: 2));
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.first, 0);
      expect(seen.last, 1);
    });
  });

  test(
    'watchAccounts, watchCategories и watchCheckpoints отдают данные',
    () async {
      final accounts = <int>[];
      final withArchived = <int>[];
      final categories = <int>[];
      final incomeOnly = <int>[];
      final checkpoints = <int>[];
      final subs = [
        repo.watchAccounts().listen((l) => accounts.add(l.length)),
        repo
            .watchAccounts(includeArchived: true)
            .listen((l) => withArchived.add(l.length)),
        repo.watchCategories().listen((l) => categories.add(l.length)),
        repo
            .watchCategories(kind: CategoryKind.income)
            .listen((l) => incomeOnly.add(l.length)),
        repo
            .watchCheckpoints(accountId: uuid(1))
            .listen((l) => checkpoints.add(l.length)),
      ];
      await pumpEventQueue();
      await repo.createAccount(_account(1));
      await repo.createAccount(_account(2));
      await repo.archiveAccount(uuid(2));
      await repo.createCategory(_category(20, 'Еда'));
      await repo.createCategory(
        _category(21, 'Зарплата', kind: CategoryKind.income),
      );
      await repo.reconcile(accountId: uuid(1), actualBalance: 5);
      await pumpEventQueue();
      for (final s in subs) {
        await s.cancel();
      }
      expect(accounts.last, 1);
      expect(withArchived.last, 2);
      expect(categories.last, 2);
      expect(incomeOnly.last, 1);
      expect(checkpoints.last, 1);
    },
  );

  group('сверка и балансы', () {
    test(
      'баланс счёта, общий баланс, корректировка (пример spec 4.2/4.4)',
      () async {
        await repo.createAccount(_account(1));
        await repo.createAccount(_account(2, opening: 0, inTotal: false));
        Future<void> add(FinanceTransaction t) => repo.createTransaction(t);
        await add(
          _tx(10, account: 1, amount: 10000, at: DateTime.utc(2026, 3, 1, 9)),
        );
        await add(
          _tx(11, account: 1, amount: 2000, at: DateTime.utc(2026, 3, 6, 9)),
        );
        await add(
          _tx(
            12,
            kind: TransactionKind.transfer,
            account: 2,
            to: 1,
            amount: 500,
            at: DateTime.utc(2026, 3, 7, 9),
          ),
        );
        clock.ms = DateTime.utc(2026, 3, 5, 9).millisecondsSinceEpoch;
        final adj = await repo.reconcile(
          accountId: uuid(1),
          actualBalance: 77000,
          note: ' по выписке ',
        );
        expect(adj.actual, 77000);
        expect(adj.expected, 90000);
        expect(adj.adjustment, -13000);
        final balances = await repo.balances();
        expect(balances.of(uuid(1)), 77000 - 2000 + 500);
        expect(balances.of(uuid(2)), -500);
        expect(balances.of('нет'), 0);
        expect(balances.total, 75500, reason: 'счёт 2 вне общего баланса');
        expect(
          (await repo.balances(at: '2026-03-01T23:00:00Z')).of(uuid(1)),
          90000,
        );
        final cps = await repo.checkpoints(accountId: uuid(1));
        expect(cps.single.source, CheckpointSource.manual);
        expect(cps.single.note, 'по выписке');
        expect(await repo.checkpoints(accountId: uuid(2)), isEmpty);
        expect(await repo.checkpoints(), hasLength(1));
        final lines = await repo.adjustmentsOf(uuid(1));
        expect(lines.single.checkpointId, cps.single.id);
        expect(await repo.adjustmentsOf('нет'), isEmpty);
      },
    );

    test('сверка: проверки', () async {
      await repo.createAccount(_account(1));
      await expectLater(
        repo.reconcile(accountId: uuid(9), actualBalance: 1),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.reconcile(
          accountId: uuid(1),
          actualBalance: 1,
          at: DateTime.utc(2025, 12, 31),
        ),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.reconcile(accountId: uuid(1), actualBalance: 100000000000000),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.createCheckpoint(
          BalanceCheckpoint(
            id: uuid(5),
            accountId: uuid(9),
            checkedAt: DateTime.utc(2026, 5),
            actualBalance: 1,
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await repo.checkpoints(), isEmpty);
    });

    test('удаление точки сверки возвращает расчёт по учёту', () async {
      await repo.createAccount(_account(1, opening: 1000));
      final adj = await repo.reconcile(accountId: uuid(1), actualBalance: 5000);
      expect((await repo.balances()).total, 5000);
      await repo.deleteCheckpoint(adj.checkpointId);
      expect((await repo.balances()).total, 1000);
    });

    test('точки удалённого счёта не видны', () async {
      await repo.createAccount(_account(1));
      await repo.reconcile(accountId: uuid(1), actualBalance: 5000);
      await repo.deleteAccount(uuid(1));
      expect(await repo.checkpoints(), isEmpty);
    });
  });
}
