import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

/// Счета, категории, операции и точки сверки: локальные записи через
/// [SyncStore] (строка + HLC + outbox в одной транзакции) и расчёты по
/// видимым строкам (spec Этапа 5, разделы 2 и 4).
///
/// Видимость (spec 2): строка видна, если она жива и живы все её родители;
/// операция-перевод видна только когда живы **оба** счёта. Удаление счёта —
/// одна операция `delete` счёта: операции обеих сторон перевода и точки
/// сверки уходят в корзину каскадом на сервере и скрываются локально
/// видимостью, отдельных операций клиент не пишет.
class FinanceRepository {
  FinanceRepository(
    this._store, {
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? uuid7,
       _now = now ?? DateTime.now;

  final SyncStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  static const String accountsTable = 'accounts';
  static const String categoriesTable = 'categories';
  static const String transactionsTable = 'transactions';
  static const String checkpointsTable = 'balance_checkpoints';

  /// Идентификатор новой строки (UUIDv7).
  String newId() => _newId();

  DateTime get _nowUtc => _now().toUtc();

  // ---- общее ---------------------------------------------------------------

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  bool _differs(Object? a, Object? b) => a != b;

  /// Только изменившиеся колонки.
  Json _changed(Json before, Json after) => {
    for (final e in after.entries)
      if (_differs(before[e.key], e.value)) e.key: e.value,
  };

  Future<Json?> _liveRow(String table, String id) async {
    final row = await _store.getRow(table, id);
    return row == null || row['deleted_at'] != null ? null : row;
  }

  // ---- счета ---------------------------------------------------------------

  Future<Account?> getAccount(String id) async {
    final row = await _store.getRow(accountsTable, id);
    return row == null ? null : Account.fromRow(row);
  }

  /// Видимые счета в порядке создания; архивные — по [includeArchived].
  Future<List<Account>> accounts({bool includeArchived = false}) async => [
    for (final r in await _store.visibleRows(
      accountsTable,
      orderBy: 't.created_at, t.id',
    ))
      if (includeArchived || r['archived'] != true) Account.fromRow(r),
  ];

  Stream<List<Account>> watchAccounts({bool includeArchived = false}) => _store
      .watchVisibleRows(accountsTable, orderBy: 't.created_at, t.id')
      .map(
        (rows) => [
          for (final r in rows)
            if (includeArchived || r['archived'] != true) Account.fromRow(r),
        ],
      );

  Account _cleanAccount(Account a) => Account(
    id: a.id,
    name: a.name.trim(),
    kind: a.kind,
    bank: _blankToNull(a.bank),
    cardLast4: _blankToNull(a.cardLast4),
    openingBalance: a.openingBalance,
    openingDate: a.openingDate,
    includeInTotal: a.includeInTotal,
    creditLimit: a.creditLimit,
    archived: a.archived,
  );

  /// Создаёт счёт; `account.id` задаёт вызывающий ([newId]).
  Future<String> createAccount(Account account) async {
    final clean = _cleanAccount(account);
    ensureValid(accountProblem(clean));
    await _store.create(accountsTable, clean.id, clean.toFields());
    return clean.id;
  }

  /// Правка счёта: уходят только изменившиеся колонки.
  Future<void> updateAccount(Account next) async {
    final clean = _cleanAccount(next);
    ensureValid(accountProblem(clean));
    await _store.transaction(() async {
      final current = await getAccount(clean.id);
      if (current == null) throw StateError('Счёта ${clean.id} нет');
      final fields = _changed(current.toFields(), clean.toFields());
      if (fields.isEmpty) return;
      await _store.update(accountsTable, clean.id, fields);
    });
  }

  /// Архивация скрывает счёт из списков, на расчёты не влияет (spec 1.1).
  Future<void> archiveAccount(String id, {bool archived = true}) async {
    final account = await getAccount(id);
    if (account == null || account.archived == archived) return;
    await _store.update(accountsTable, id, {'archived': archived});
  }

  /// Удаляет счёт: одна операция `delete`; операции по `account_id` и
  /// `to_account_id` и точки сверки уходят в корзину каскадом на сервере.
  Future<void> deleteAccount(String id) => _store.softDelete(accountsTable, id);

  Future<void> restoreAccount(String id) => _store.restore(accountsTable, id);

  // ---- категории -----------------------------------------------------------

  Future<FinanceCategory?> getCategory(String id) async {
    final row = await _store.getRow(categoriesTable, id);
    return row == null ? null : FinanceCategory.fromRow(row);
  }

  /// Живые категории по названию.
  Future<List<FinanceCategory>> categories({CategoryKind? kind}) async => [
    for (final r in await _store.visibleRows(
      categoriesTable,
      orderBy: 't.name, t.id',
    ))
      if (kind == null || r['kind'] == kind.wire) FinanceCategory.fromRow(r),
  ];

  Stream<List<FinanceCategory>> watchCategories({CategoryKind? kind}) => _store
      .watchVisibleRows(categoriesTable, orderBy: 't.name, t.id')
      .map(
        (rows) => [
          for (final r in rows)
            if (kind == null || r['kind'] == kind.wire)
              FinanceCategory.fromRow(r),
        ],
      );

  FinanceCategory _cleanCategory(FinanceCategory c) => FinanceCategory(
    id: c.id,
    name: c.name.trim(),
    kind: c.kind,
    parentId: c.parentId,
    icon: _blankToNull(c.icon),
    color: _blankToNull(c.color),
    systemKey: c.systemKey,
  );

  Future<void> _checkCategoryParent(FinanceCategory c) async {
    ensureValid(categoryProblem(c));
    if (c.parentId == null) return;
    final parentRow = await _liveRow(categoriesTable, c.parentId!);
    final hasChildren = (await _store.visibleRows(
      categoriesTable,
      where: 't.parent_id = ?',
      args: [c.id],
    )).isNotEmpty;
    ensureValid(
      categoryParentProblem(
        c,
        parentRow == null ? null : FinanceCategory.fromRow(parentRow),
        hasChildren: hasChildren,
      ),
    );
  }

  /// Создаёт категорию; подкатегория — с живым родителем верхнего уровня
  /// того же вида.
  Future<String> createCategory(FinanceCategory category) async {
    final clean = _cleanCategory(category);
    await _store.transaction(() async {
      await _checkCategoryParent(clean);
      await _store.create(categoriesTable, clean.id, clean.toFields());
    });
    return clean.id;
  }

  /// Правка категории; `system_key` неизменяем.
  Future<void> updateCategory(FinanceCategory next) async {
    final clean = _cleanCategory(next);
    await _store.transaction(() async {
      final current = await getCategory(clean.id);
      if (current == null) throw StateError('Категории ${clean.id} нет');
      if (current.systemKey != clean.systemKey) {
        throw const ValidationError(
          'Ключ предустановленной категории нельзя менять',
        );
      }
      await _checkCategoryParent(clean);
      final fields = _changed(current.toFields(), clean.toFields())
        ..remove('system_key');
      if (fields.isEmpty) return;
      await _store.update(categoriesTable, clean.id, fields);
    });
  }

  /// Удаление категории ничего не уносит: операции остаются (в аналитике
  /// они идут в «без категории»), подкатегории становятся верхнего уровня
  /// (spec 2).
  Future<void> deleteCategory(String id) =>
      _store.softDelete(categoriesTable, id);

  Future<void> restoreCategory(String id) =>
      _store.restore(categoriesTable, id);

  /// Засев предустановленных категорий (spec 3.2): только после первой
  /// полной синхронизации ([requireFirstSync]) и только для ключей, для
  /// которых в локальной базе **нет строки с таким id вообще** (ни живой, ни
  /// в корзине) — удалённая пользователем категория не воскресает.
  /// Возвращает число созданных строк.
  Future<int> ensurePresetCategories({bool requireFirstSync = true}) async {
    if (requireFirstSync && await _store.lastSuccessAt() == null) return 0;
    return await _store.transaction(() async {
      var created = 0;
      for (final p in presetCategories) {
        if (await _store.getRow(categoriesTable, p.id) != null) continue;
        await _store.create(
          categoriesTable,
          p.id,
          FinanceCategory(
            id: p.id,
            name: p.name,
            kind: CategoryKind.parse(p.kind),
            parentId: p.parentId,
            icon: p.icon,
            systemKey: p.key,
          ).toFields(),
        );
        created++;
      }
      return created;
    });
  }

  // ---- операции ------------------------------------------------------------

  Future<FinanceTransaction?> getTransaction(String id) async {
    final row = await _store.getRow(transactionsTable, id);
    return row == null ? null : FinanceTransaction.fromRow(row);
  }

  Future<Map<String, String?>> _categoryParents() async => {
    for (final r in await _store.visibleRows(categoriesTable))
      r['id']! as String: r['parent_id'] as String?,
  };

  /// Видимые операции с фильтром (новые сверху). Видимость: операция жива и
  /// живы её счета (у перевода — оба).
  Future<List<FinanceTransaction>> transactions({
    TransactionFilter filter = const TransactionFilter(),
  }) async => filterTransactions(
    await _store.visibleRows(transactionsTable),
    filter,
    categoryParents: await _categoryParents(),
  );

  Stream<List<FinanceTransaction>> watchTransactions({
    TransactionFilter filter = const TransactionFilter(),
  }) => _store
      .watchVisibleRows(transactionsTable)
      .asyncMap(
        (rows) async => filterTransactions(
          rows,
          filter,
          categoryParents: await _categoryParents(),
        ),
      );

  FinanceTransaction _cleanTransaction(FinanceTransaction t) =>
      FinanceTransaction(
        id: t.id,
        kind: t.kind,
        accountId: t.accountId,
        toAccountId: t.toAccountId,
        amount: t.amount,
        occurredAt: t.occurredAt,
        categoryId: t.categoryId,
        merchant: _blankToNull(t.merchant),
        comment: _blankToNull(t.comment),
        source: t.source,
        status: t.status,
        externalId: t.externalId,
        dedupHash: t.dedupHash,
        workPaymentId: t.workPaymentId,
        debtId: t.debtId,
      );

  /// Счета операции существуют и не в корзине; категория того же вида.
  Future<void> _checkTransactionLinks(FinanceTransaction t) async {
    for (final id in [t.accountId, ?t.toAccountId]) {
      if (await _liveRow(accountsTable, id) == null) {
        throw const ValidationError('Счёт не найден');
      }
    }
    final categoryId = t.categoryId;
    if (categoryId != null) {
      final category = await _liveRow(categoriesTable, categoryId);
      if (category != null && category['kind'] != t.kind.wire) {
        throw const ValidationError('Категория другого вида');
      }
    }
  }

  /// Создаёт операцию; `source = manual` и `status = confirmed` — значения
  /// по умолчанию [FinanceTransaction] (срез 5a создаёт только такие).
  Future<String> createTransaction(FinanceTransaction transaction) async {
    final clean = _cleanTransaction(transaction);
    ensureValid(transactionProblem(clean));
    await _store.transaction(() async {
      await _checkTransactionLinks(clean);
      await _store.create(transactionsTable, clean.id, clean.toFields());
    });
    return clean.id;
  }

  /// Правка операции. Связанная группа `kind`, `to_account_id`,
  /// `category_id`, `work_payment_id`, `debt_id`, `source` уходит целиком,
  /// чтобы слияние с другого устройства не собрало недопустимую
  /// комбинацию (перевод с категорией и т. п.).
  Future<void> updateTransaction(FinanceTransaction next) async {
    final clean = _cleanTransaction(next);
    ensureValid(transactionProblem(clean));
    await _store.transaction(() async {
      final current = await getTransaction(clean.id);
      if (current == null) throw StateError('Операции ${clean.id} нет');
      await _checkTransactionLinks(clean);
      final before = current.toFields();
      final after = clean.toFields();
      final fields = _changed(before, after);
      const shape = [
        'kind',
        'to_account_id',
        'category_id',
        'work_payment_id',
        'debt_id',
        'source',
      ];
      if (shape.any(fields.containsKey)) {
        for (final k in shape) {
          fields[k] = after[k];
        }
      }
      if (fields.isEmpty) return;
      await _store.update(transactionsTable, clean.id, fields);
    });
  }

  Future<void> deleteTransaction(String id) =>
      _store.softDelete(transactionsTable, id);

  Future<void> restoreTransaction(String id) =>
      _store.restore(transactionsTable, id);

  // ---- точки сверки ----------------------------------------------------------

  /// Точки сверки видимых счетов по возрастанию момента; [accountId] —
  /// только этого счёта.
  Future<List<BalanceCheckpoint>> checkpoints({String? accountId}) async => [
    for (final r in await _store.visibleRows(
      checkpointsTable,
      where: accountId == null ? null : 't.account_id = ?',
      args: [?accountId],
      orderBy: 't.checked_at, t.id',
    ))
      BalanceCheckpoint.fromRow(r),
  ];

  Stream<List<BalanceCheckpoint>> watchCheckpoints({String? accountId}) =>
      _store
          .watchVisibleRows(
            checkpointsTable,
            where: accountId == null ? null : 't.account_id = ?',
            args: [?accountId],
            orderBy: 't.checked_at, t.id',
          )
          .map((rows) => [for (final r in rows) BalanceCheckpoint.fromRow(r)]);

  /// Создаёт точку сверки; `account_id` неизменяем.
  Future<String> createCheckpoint(BalanceCheckpoint checkpoint) async {
    final clean = BalanceCheckpoint(
      id: checkpoint.id,
      accountId: checkpoint.accountId,
      checkedAt: checkpoint.checkedAt,
      actualBalance: checkpoint.actualBalance,
      source: checkpoint.source,
      note: _blankToNull(checkpoint.note),
    );
    ensureValid(checkpointProblem(clean));
    await _store.transaction(() async {
      if (await _liveRow(accountsTable, clean.accountId) == null) {
        throw const ValidationError('Счёт не найден');
      }
      await _store.create(checkpointsTable, clean.id, clean.toFields());
    });
    return clean.id;
  }

  Future<void> deleteCheckpoint(String id) =>
      _store.softDelete(checkpointsTable, id);

  Future<void> restoreCheckpoint(String id) =>
      _store.restore(checkpointsTable, id);

  /// Сверка баланса (spec 4.4): точка `source = manual` с фактическим
  /// остатком [actualBalance] на момент [at] (по умолчанию — сейчас).
  /// Отдельных операций-корректировок не создаётся; возвращается
  /// вычисленная корректировка этой точки.
  Future<BalanceAdjustment> reconcile({
    required String accountId,
    required int actualBalance,
    DateTime? at,
    String? note,
  }) async {
    final moment = DateTime.fromMillisecondsSinceEpoch(
      (at ?? _nowUtc).toUtc().millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    final account = await _liveRow(accountsTable, accountId);
    if (account == null) throw const ValidationError('Счёт не найден');
    if (moment.millisecondsSinceEpoch ~/ 1000 <
        openingSeconds(account['opening_date']! as String)) {
      throw const ValidationError('Сверка раньше открытия счёта');
    }
    final id = _newId();
    await createCheckpoint(
      BalanceCheckpoint(
        id: id,
        accountId: accountId,
        checkedAt: moment,
        actualBalance: actualBalance,
        note: note,
      ),
    );
    final lines = await adjustmentsOf(accountId);
    return lines.singleWhere((l) => l.checkpointId == id);
  }

  // ---- расчёты ---------------------------------------------------------------

  /// Балансы счетов и общий на момент [at] (`null` — сейчас, все данные) по
  /// видимым строкам.
  Future<FinanceBalances> balances({String? at}) async =>
      FinanceBalances.compute(
        await _store.visibleRows(accountsTable),
        await _store.visibleRows(transactionsTable),
        await _store.visibleRows(checkpointsTable),
        at: at,
      );

  /// Корректировки сверок счёта по возрастанию момента (spec 4.4).
  Future<List<BalanceAdjustment>> adjustmentsOf(String accountId) async {
    final account = await _liveRow(accountsTable, accountId);
    if (account == null) return const [];
    final lines = adjustments(
      account,
      await _store.visibleRows(transactionsTable),
      await _store.visibleRows(checkpointsTable),
    );
    return [for (final l in lines) BalanceAdjustment.fromJson(l)];
  }
}

final financeRepositoryProvider = Provider<FinanceRepository>(
  (ref) => FinanceRepository(
    ref.watch(syncStoreProvider),
    now: ref.watch(clockProvider),
  ),
);
