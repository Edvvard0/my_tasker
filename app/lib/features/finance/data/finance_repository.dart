import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';

/// Счета, категории, операции, сверки, долги и цели: локальные записи
/// через [SyncStore] (строка + HLC + outbox в одной транзакции). Проверки —
/// как на сервере, плюс правила нескольких строк, которые сервер не
/// проверяет (глубина категорий, погашение не больше остатка).
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
  static const String debtsTable = 'debts';
  static const String repaymentsTable = 'debt_repayments';
  static const String goalsTable = 'goals';

  DateTime get _nowUtc {
    final t = _now().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      (t.millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true,
    );
  }

  /// Новый UUIDv7 для строки.
  String newId() => _newId();

  /// Изменившиеся колонки (в правку уходят только они).
  Json _changes(Json before, Json after) => {
    for (final e in after.entries)
      if (_differs(before[e.key], e.value)) e.key: e.value,
  };

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) return a.toString() != b.toString();
    return a != b;
  }

  // ---- счета --------------------------------------------------------------

  Future<Account?> getAccount(String id) async {
    final row = await _store.getRow(accountsTable, id);
    return row == null ? null : Account.fromRow(row);
  }

  Future<String> createAccount(Account account) async {
    final clean = account.copyWith(
      name: account.name.trim(),
      bank: _blankToNull(account.bank),
    );
    ensureValid(accountProblem(clean));
    await _store.create(accountsTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateAccount(Account next) async {
    final clean = next.copyWith(
      name: next.name.trim(),
      bank: _blankToNull(next.bank),
    );
    ensureValid(accountProblem(clean));
    await _store.transaction(() async {
      final current = await getAccount(clean.id);
      if (current == null) throw StateError('Счёта ${clean.id} нет');
      final fields = _changes(current.toFields(), clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(accountsTable, clean.id, fields);
      }
    });
  }

  /// Архив только скрывает счёт из списков, на расчёты не влияет.
  Future<void> setAccountArchived(String id, {required bool archived}) =>
      _store.update(accountsTable, id, {'archived': archived});

  /// Удаление счёта уносит в корзину его операции (и переводы на него) и
  /// точки сверки — каскад делает сервер, клиент скрывает видимостью.
  Future<void> deleteAccount(String id) => _store.softDelete(accountsTable, id);

  Future<void> restoreAccount(String id) => _store.restore(accountsTable, id);

  // ---- категории -------------------------------------------------------------

  Future<FinCategory?> getCategory(String id) async {
    final row = await _store.getRow(categoriesTable, id);
    return row == null ? null : FinCategory.fromRow(row);
  }

  Future<void> _checkCategory(FinCategory category) async {
    final parentId = category.parentId;
    final parent = parentId == null ? null : await getCategory(parentId);
    ensureValid(categoryProblem(category, parent: parent));
    if (parentId != null && parentId == category.id) {
      throw const ValidationError('Категория не может быть своим родителем');
    }
  }

  Future<String> createCategory(FinCategory category) async {
    final clean = category.copyWith(name: category.name.trim());
    await _checkCategory(clean);
    await _store.create(categoriesTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateCategory(FinCategory next) async {
    final clean = next.copyWith(name: next.name.trim());
    await _checkCategory(clean);
    await _store.transaction(() async {
      final current = await getCategory(clean.id);
      if (current == null) throw StateError('Категории ${clean.id} нет');
      final fields = _changes(current.toFields(), clean.toFields())
        ..remove('system_key');
      if (fields.isNotEmpty) {
        await _store.update(categoriesTable, clean.id, fields);
      }
    });
  }

  /// Удаление категории не трогает операции: их `category_id` остаётся, в
  /// аналитике такие деньги идут в «без категории»; подкатегории
  /// показываются как категории верхнего уровня (spec 2).
  Future<void> deleteCategory(String id) =>
      _store.softDelete(categoriesTable, id);

  Future<void> restoreCategory(String id) =>
      _store.restore(categoriesTable, id);

  /// Засев предустановленных категорий (spec 3.2): только ключи, для
  /// которых в локальной базе нет строки с таким `id` вообще (ни живой, ни
  /// в корзине) — удалённая пользователем категория не воскресает.
  /// Возвращает, сколько категорий создано.
  Future<int> seedPresetCategories() async {
    var created = 0;
    await _store.transaction(() async {
      for (final preset in categoryPresets) {
        if (await _store.getRow(categoriesTable, preset.id) != null) continue;
        await _store.create(categoriesTable, preset.id, preset.toFields());
        created++;
      }
    });
    return created;
  }

  // ---- операции -------------------------------------------------------------

  Future<FinTransaction?> getTransaction(String id) async {
    final row = await _store.getRow(transactionsTable, id);
    return row == null ? null : FinTransaction.fromRow(row);
  }

  Future<void> _requireAccounts(FinTransaction tx) async {
    for (final id in [tx.accountId, ?tx.toAccountId]) {
      final row = await _store.getRow(accountsTable, id);
      if (row == null || row['deleted_at'] != null) {
        throw const ValidationError('Счёт не найден: возможно, его удалили');
      }
    }
  }

  FinTransaction _cleanTransaction(FinTransaction tx) => tx.copyWith(
    merchant: _blankToNull(tx.merchant),
    comment: _blankToNull(tx.comment),
  );

  /// Создаёт операцию или перевод (перевод — одна строка с двумя
  /// счетами, spec 4.1).
  Future<String> createTransaction(FinTransaction tx) async {
    final clean = _cleanTransaction(tx);
    ensureValid(transactionProblem(clean));
    await _requireAccounts(clean);
    await _store.create(transactionsTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateTransaction(FinTransaction next) async {
    final clean = _cleanTransaction(next);
    ensureValid(transactionProblem(clean));
    await _requireAccounts(clean);
    await _store.transaction(() async {
      final current = await getTransaction(clean.id);
      if (current == null) throw StateError('Операции ${clean.id} нет');
      final fields = _changes(current.toFields(), clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(transactionsTable, clean.id, fields);
      }
    });
  }

  /// Подтверждение черновика: с этого момента операция входит во все
  /// расчёты по своему `occurred_at` (spec 4.3).
  Future<void> confirmTransaction(String id) =>
      _store.update(transactionsTable, id, {'status': TxStatus.confirmed.wire});

  Future<void> deleteTransaction(String id) =>
      _store.softDelete(transactionsTable, id);

  Future<void> restoreTransaction(String id) =>
      _store.restore(transactionsTable, id);

  /// «Деньги по проекту пришли на карту» (spec 7.1): доход со ссылкой на
  /// платёж Работы; платёж можно разделить между счетами несколькими
  /// такими операциями.
  Future<String> reflectWorkPayment({
    required String paymentId,
    required String accountId,
    required int amount,
    required DateTime occurredAt,
    String? merchant,
  }) async {
    final presetId = categoryPresets
        .firstWhere((p) => p.key == 'income.projects')
        .id;
    final category = await _store.getRow(categoriesTable, presetId);
    final live = category != null && category['deleted_at'] == null;
    return await createTransaction(
      FinTransaction(
        id: _newId(),
        kind: TxKind.income,
        accountId: accountId,
        amount: amount,
        occurredAt: occurredAt,
        categoryId: live ? presetId : null,
        merchant: merchant,
        source: TxSource.workPayment,
        workPaymentId: paymentId,
      ),
    );
  }

  // ---- сверка баланса ---------------------------------------------------------

  /// Сверка = точка с фактическим балансом из банка. Корректировка —
  /// вычисляемая величина: операций сверка не создаёт (spec 4.4).
  Future<String> reconcile({
    required String accountId,
    required int actualBalance,
    DateTime? checkedAt,
    String? note,
  }) async {
    final cp = BalanceCheckpoint(
      id: _newId(),
      accountId: accountId,
      checkedAt: checkedAt ?? _nowUtc,
      actualBalance: actualBalance,
      note: _blankToNull(note),
    );
    ensureValid(checkpointProblem(cp));
    final account = await getAccount(accountId);
    if (account == null) {
      throw const ValidationError('Счёт не найден: возможно, его удалили');
    }
    await _store.create(checkpointsTable, cp.id, cp.toFields());
    return cp.id;
  }

  Future<void> deleteCheckpoint(String id) =>
      _store.softDelete(checkpointsTable, id);

  // ---- долги --------------------------------------------------------------------

  Future<Debt?> getDebt(String id) async {
    final row = await _store.getRow(debtsTable, id);
    return row == null ? null : Debt.fromRow(row);
  }

  Debt _cleanDebt(Debt d) => d.copyWith(
    counterparty: _blankToNull(d.counterparty),
    comment: _blankToNull(d.comment),
  );

  /// Создаёт долг; с [accountId] ещё и операцию, которой деньги двигались
  /// (выдал в долг — расход, взял в долг — доход; обе с `debt_id`, так что
  /// в «доход/расход» месяца не входят, spec 5.1).
  Future<String> createDebt(Debt debt, {String? accountId}) async {
    final clean = _cleanDebt(debt);
    ensureValid(debtProblem(clean));
    await _store.transaction(() async {
      await _store.create(debtsTable, clean.id, clean.toFields());
      if (accountId != null) {
        await createTransaction(
          FinTransaction(
            id: _newId(),
            kind: clean.direction == DebtDirection.owedToMe
                ? TxKind.expense
                : TxKind.income,
            accountId: accountId,
            amount: clean.amount,
            occurredAt: momentForDate(clean.debtDate, _nowUtc),
            merchant: _blankToNull(clean.counterparty),
            debtId: clean.id,
          ),
        );
      }
    });
    return clean.id;
  }

  Future<void> updateDebt(Debt next) async {
    final clean = _cleanDebt(next);
    ensureValid(debtProblem(clean));
    await _store.transaction(() async {
      final current = await getDebt(clean.id);
      if (current == null) throw StateError('Долга ${clean.id} нет');
      final fields = _changes(current.toFields(), clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(debtsTable, clean.id, fields);
      }
    });
  }

  /// Удаление долга уносит погашения (каскад сервера); операции с
  /// `debt_id` остаются: деньги реально двигались.
  Future<void> deleteDebt(String id) => _store.softDelete(debtsTable, id);

  Future<void> restoreDebt(String id) => _store.restore(debtsTable, id);

  Future<List<DebtRepayment>> repaymentsOf(String debtId) async => [
    for (final r in await _store.visibleRows(
      repaymentsTable,
      where: 't.debt_id = ?',
      args: [debtId],
      orderBy: 't.repaid_on, t.created_at, t.id',
    ))
      DebtRepayment.fromRow(r),
  ];

  /// Погашение частью или целиком; сумма не больше остатка (клиент
  /// проверяет при вводе). С [accountId] деньги двигаются операцией (мне
  /// вернули — доход, я вернул — расход) с `debt_id`, погашение ссылается
  /// на неё; без счёта — «простил», «зачли».
  Future<String> repayDebt({
    required Debt debt,
    required int amount,
    required String repaidOn,
    String? accountId,
    String? note,
  }) async {
    final id = _newId();
    final repayment = DebtRepayment(
      id: id,
      debtId: debt.id,
      amount: amount,
      repaidOn: repaidOn,
      note: _blankToNull(note),
    );
    ensureValid(repaymentProblem(repayment));
    await _store.transaction(() async {
      final state = debtState(debt, await repaymentsOf(debt.id));
      if (amount > state.remaining) {
        throw const ValidationError('Погашение больше остатка долга');
      }
      String? txId;
      if (accountId != null) {
        txId = await createTransaction(
          FinTransaction(
            id: _newId(),
            kind: debt.direction == DebtDirection.owedToMe
                ? TxKind.income
                : TxKind.expense,
            accountId: accountId,
            amount: amount,
            occurredAt: momentForDate(repaidOn, _nowUtc),
            merchant: _blankToNull(debt.counterparty),
            debtId: debt.id,
          ),
        );
      }
      final fields = DebtRepayment(
        id: id,
        debtId: debt.id,
        amount: amount,
        repaidOn: repaidOn,
        transactionId: txId,
        note: repayment.note,
      ).toFields();
      await _store.create(repaymentsTable, id, fields);
    });
    return id;
  }

  Future<void> deleteRepayment(String id) =>
      _store.softDelete(repaymentsTable, id);

  // ---- цели -----------------------------------------------------------------------

  Future<Goal?> getGoal(String id) async {
    final row = await _store.getRow(goalsTable, id);
    return row == null ? null : Goal.fromRow(row);
  }

  Future<String> createGoal(Goal goal) async {
    final clean = goal.copyWith(name: goal.name.trim());
    ensureValid(goalProblem(clean));
    await _store.create(goalsTable, clean.id, clean.toFields());
    return clean.id;
  }

  Future<void> updateGoal(Goal next) async {
    final clean = next.copyWith(name: next.name.trim());
    ensureValid(goalProblem(clean));
    await _store.transaction(() async {
      final current = await getGoal(clean.id);
      if (current == null) throw StateError('Цели ${clean.id} нет');
      final fields = _changes(current.toFields(), clean.toFields());
      if (fields.isNotEmpty) {
        await _store.update(goalsTable, clean.id, fields);
      }
    });
  }

  Future<void> setGoalArchived(String id, {required bool archived}) =>
      _store.update(goalsTable, id, {'archived': archived});

  Future<void> deleteGoal(String id) => _store.softDelete(goalsTable, id);

  Future<void> restoreGoal(String id) => _store.restore(goalsTable, id);

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

final financeRepositoryProvider = Provider<FinanceRepository>(
  (ref) => FinanceRepository(
    ref.watch(syncStoreProvider),
    now: ref.watch(clockProvider),
  ),
);
