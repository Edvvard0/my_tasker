import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart' show Receivables;

StreamProvider<List<T>> _rows<T>(
  String table,
  T Function(Map<String, Object?>) parse, {
  String? orderBy,
}) => StreamProvider<List<T>>(
  (ref) => ref
      .watch(syncStoreProvider)
      .watchVisibleRows(table, orderBy: orderBy)
      .map((rows) => [for (final r in rows) parse(r)]),
);

/// Счета в порядке создания (постоянная очередность карточек, spec 12.7).
final StreamProvider<List<Account>> accountsProvider = _rows<Account>(
  'accounts',
  Account.fromRow,
  orderBy: 't.created_at, t.id',
);

final StreamProvider<List<FinCategory>> financeCategoriesProvider =
    _rows<FinCategory>(
      'categories',
      FinCategory.fromRow,
      orderBy: 't.created_at, t.id',
    );

final StreamProvider<List<FinTransaction>> transactionsProvider =
    _rows<FinTransaction>(
      'transactions',
      FinTransaction.fromRow,
      orderBy: 't.occurred_at DESC, t.id',
    );

final StreamProvider<List<BalanceCheckpoint>> checkpointsProvider =
    _rows<BalanceCheckpoint>(
      'balance_checkpoints',
      BalanceCheckpoint.fromRow,
      orderBy: 't.checked_at, t.id',
    );

final StreamProvider<List<Debt>> debtsProvider = _rows<Debt>(
  'debts',
  Debt.fromRow,
  orderBy: 't.debt_date DESC, t.id',
);

final StreamProvider<List<DebtRepayment>> repaymentsProvider =
    _rows<DebtRepayment>(
      'debt_repayments',
      DebtRepayment.fromRow,
      orderBy: 't.repaid_on, t.created_at, t.id',
    );

final StreamProvider<List<Goal>> goalsProvider = _rows<Goal>(
  'goals',
  Goal.fromRow,
  orderBy: 't.created_at, t.id',
);

/// Категория в дереве: категория верхнего уровня и её подкатегории.
@immutable
class CategoryNode {
  const CategoryNode({required this.category, required this.children});

  final FinCategory category;
  final List<FinCategory> children;
}

/// Снимок «Финансов» с готовыми расчётами. Расчёты — чистые функции
/// `finance_calc.dart` (общие векторы с сервером); здесь только кэш.
@immutable
class FinanceData {
  FinanceData({
    required this.accounts,
    required this.categories,
    required this.transactions,
    required this.checkpoints,
    required this.debts,
    required this.repayments,
    required this.goals,
    required this.work,
    required this.now,
  });

  final List<Account> accounts;
  final List<FinCategory> categories;

  /// Свежие первыми.
  final List<FinTransaction> transactions;
  final List<BalanceCheckpoint> checkpoints;
  final List<Debt> debts;
  final List<DebtRepayment> repayments;
  final List<Goal> goals;

  /// Снимок «Работы»: проекты, заказчики, платежи для ожидаемых
  /// поступлений.
  final WorkData work;

  /// «Сейчас» (UTC).
  final DateTime now;

  late final String today = moscowDay(now);
  late final String thisMonth = today.substring(0, 7);

  late final Map<String, Account> accountById = {
    for (final a in accounts) a.id: a,
  };
  late final Map<String, FinCategory> categoryById = {
    for (final c in categories) c.id: c,
  };
  late final Map<String, Debt> debtById = {for (final d in debts) d.id: d};

  /// Счета без архива (архив только скрывает счёт из списков).
  late final List<Account> activeAccounts = [
    for (final a in accounts)
      if (!a.archived) a,
  ];

  late final BalanceReport balances = accountBalances(
    accounts,
    transactions,
    checkpoints,
  );

  late final DebtsSummary debtSummary = debtsSummary(
    debts,
    repayments,
    today: today,
  );

  /// Ожидаемые поступления из Работы — дебиторка Этапа 4.
  Receivables get receivables => work.receivablesAll;

  late final List<PaymentCoverage> paymentCoverage = workPaymentCoverage(
    work.payments,
    transactions,
  );

  late final List<FinanceProblem> problems = integrityProblems(
    categories: categories,
    transactions: transactions,
    debts: debts,
    repayments: repayments,
    payments: work.payments,
  );

  /// Баланс счёта (без данных — `0`).
  int balanceOf(String accountId) => balances.of(accountId);

  /// Сумма балансов кредитных карт: «потрачено сверх» — отрицательное.
  late final int creditCardsBalance = () {
    var sum = 0;
    for (final a in accounts) {
      if (a.kind == AccountKind.creditCard && !a.archived) {
        sum += balances.of(a.id);
      }
    }
    return sum;
  }();

  final Map<String, GoalProgress> _progress = {};

  /// Формула «Есть» цели (кэшируется).
  GoalProgress progressOf(Goal goal) => _progress[goal.id] ??= goalProgress(
    goal,
    accounts: accounts,
    transactions: transactions,
    checkpoints: checkpoints,
    debts: debts,
    repayments: repayments,
    projects: work.projects,
    changeRequests: work.changeRequests,
    allocations: work.allocations,
  );

  /// Корректировки счёта по точкам сверки (по возрастанию).
  List<Adjustment> adjustmentsOf(Account account) =>
      adjustments(account, transactions, checkpoints);

  /// Операции счёта: и по `account_id`, и входящие переводы.
  List<FinTransaction> transactionsOf(String accountId) => [
    for (final t in transactions)
      if (t.accountId == accountId || t.toAccountId == accountId) t,
  ];

  List<DebtRepayment> repaymentsOf(String debtId) => [
    for (final r in repayments)
      if (r.debtId == debtId) r,
  ];

  /// Категории вида [kind] деревом: верхний уровень (в том числе
  /// подкатегории удалённого родителя) с подкатегориями.
  List<CategoryNode> categoryTree(CategoryKind kind) {
    final nodes = <CategoryNode>[];
    for (final c in categories) {
      if (c.kind != kind) continue;
      final parent = c.parentId == null ? null : categoryById[c.parentId];
      if (parent != null) continue;
      nodes.add(
        CategoryNode(
          category: c,
          children: [
            for (final k in categories)
              if (k.parentId == c.id) k,
          ],
        ),
      );
    }
    return nodes;
  }

  /// Название категории вместе с родителем: «Транспорт › Такси».
  String categoryTitle(String? id) {
    final c = id == null ? null : categoryById[id];
    if (c == null) return 'Без категории';
    final parent = c.parentId == null ? null : categoryById[c.parentId];
    return parent == null ? c.name : '${parent.name} › ${c.name}';
  }

  String accountName(String? id) =>
      (id == null ? null : accountById[id]?.name) ?? 'Счёт удалён';

  /// Имя контрагента долга: человек из «Работы» или текст.
  String debtorName(Debt debt) {
    final person = debt.personId == null
        ? null
        : work.personById[debt.personId];
    return person?.name ?? debt.counterparty ?? 'Не указан';
  }

  /// Название операции для списков: мерчант, иначе категория, иначе вид.
  String transactionTitle(FinTransaction tx) {
    final merchant = tx.merchant;
    if (merchant != null && merchant.isNotEmpty) return merchant;
    if (tx.kind == TxKind.transfer) {
      return '${accountName(tx.accountId)} → ${accountName(tx.toAccountId)}';
    }
    if (tx.categoryId != null && categoryById.containsKey(tx.categoryId)) {
      return categoryTitle(tx.categoryId);
    }
    return tx.kind.label;
  }

  /// Не отражено на счетах из платежа Работы.
  PaymentCoverage? coverageOf(String paymentId) {
    for (final c in paymentCoverage) {
      if (c.paymentId == paymentId) return c;
    }
    return null;
  }
}

/// «Повторить» после ошибки: перезапускает только потоки, которые упали, а
/// не все подряд (остальные уже загружены).
void retryFailedFinanceStreams(WidgetRef ref) {
  if (ref.read(accountsProvider).hasError) ref.invalidate(accountsProvider);
  if (ref.read(financeCategoriesProvider).hasError) {
    ref.invalidate(financeCategoriesProvider);
  }
  if (ref.read(transactionsProvider).hasError) {
    ref.invalidate(transactionsProvider);
  }
  if (ref.read(checkpointsProvider).hasError) {
    ref.invalidate(checkpointsProvider);
  }
  if (ref.read(debtsProvider).hasError) ref.invalidate(debtsProvider);
  if (ref.read(repaymentsProvider).hasError) {
    ref.invalidate(repaymentsProvider);
  }
  if (ref.read(goalsProvider).hasError) ref.invalidate(goalsProvider);
  if (ref.read(workDataProvider).hasError) ref.invalidate(workDataProvider);
}

/// Снимок «Финансов»: пока хотя бы один поток загружается — загрузка,
/// ошибка любого — ошибка экрана.
final Provider<AsyncValue<FinanceData>> financeDataProvider =
    Provider<AsyncValue<FinanceData>>((ref) {
      final accounts = ref.watch(accountsProvider);
      final categories = ref.watch(financeCategoriesProvider);
      final transactions = ref.watch(transactionsProvider);
      final checkpoints = ref.watch(checkpointsProvider);
      final debts = ref.watch(debtsProvider);
      final repayments = ref.watch(repaymentsProvider);
      final goals = ref.watch(goalsProvider);
      final work = ref.watch(workDataProvider);
      final now = ref.watch(nowProvider);
      final all = <AsyncValue<Object?>>[
        accounts,
        categories,
        transactions,
        checkpoints,
        debts,
        repayments,
        goals,
        work,
      ];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        FinanceData(
          accounts: accounts.requireValue,
          categories: categories.requireValue,
          transactions: transactions.requireValue,
          checkpoints: checkpoints.requireValue,
          debts: debts.requireValue,
          repayments: repayments.requireValue,
          goals: goals.requireValue,
          work: work.requireValue,
          now: now,
        ),
      );
    });

/// Засев предустановленных категорий (spec 3.2): после первой полной
/// синхронизации (и не во время повторной полной загрузки), однократно для
/// каждого ключа. Перезапускается по окончании каждого цикла синхронизации.
final FutureProvider<void> financeBootstrapProvider = FutureProvider<void>((
  ref,
) async {
  ref.watch(syncStatusProvider.select((s) => s.run.isBusy));
  final store = ref.watch(syncStoreProvider);
  if (await store.lastSuccessAt() == null) return;
  // Пока идёт полная повторная загрузка, строк в базе может ещё не быть.
  if (await store.needsResync()) return;
  await ref.read(financeRepositoryProvider).seedPresetCategories();
});

/// Фильтры ленты операций (02, лента с фильтрами).
@immutable
class TxFilter {
  const TxFilter({
    this.kind,
    this.accountId,
    this.categoryId,
    this.onlyUnconfirmed = false,
    this.query = '',
    this.month,
  });

  final TxKind? kind;
  final String? accountId;

  /// Категория верхнего уровня: включает подкатегории.
  final String? categoryId;

  /// Черновики и «требует проверки».
  final bool onlyUnconfirmed;

  /// Поиск по контрагенту и комментарию (без учёта регистра ASCII и
  /// кириллицы).
  final String query;

  /// Московский месяц `YYYY-MM`; `null` — всё время.
  final String? month;

  bool get isEmpty =>
      kind == null &&
      accountId == null &&
      categoryId == null &&
      !onlyUnconfirmed &&
      query.isEmpty &&
      month == null;

  TxFilter copyWith({
    Object? kind = _unset,
    Object? accountId = _unset,
    Object? categoryId = _unset,
    bool? onlyUnconfirmed,
    String? query,
    Object? month = _unset,
  }) => TxFilter(
    kind: identical(kind, _unset) ? this.kind : kind as TxKind?,
    accountId: identical(accountId, _unset)
        ? this.accountId
        : accountId as String?,
    categoryId: identical(categoryId, _unset)
        ? this.categoryId
        : categoryId as String?,
    onlyUnconfirmed: onlyUnconfirmed ?? this.onlyUnconfirmed,
    query: query ?? this.query,
    month: identical(month, _unset) ? this.month : month as String?,
  );
}

const Object _unset = Object();

class TxFilterNotifier extends Notifier<TxFilter> {
  @override
  TxFilter build() => const TxFilter();

  // Метод Notifier, а не сеттер: вызывается из обработчиков нажатий.
  // ignore: use_setters_to_change_properties
  void set(TxFilter filter) => state = filter;

  void reset() => state = const TxFilter();
}

final NotifierProvider<TxFilterNotifier, TxFilter> txFilterProvider =
    NotifierProvider<TxFilterNotifier, TxFilter>(TxFilterNotifier.new);

/// Операции под фильтр (свежие первыми).
List<FinTransaction> applyTxFilter(FinanceData data, TxFilter filter) {
  final needle = foldMerchant(filter.query);
  final categoryIds = <String>{};
  final root = filter.categoryId;
  if (root != null) {
    categoryIds.add(root);
    for (final c in data.categories) {
      if (c.parentId == root) categoryIds.add(c.id);
    }
  }
  return [
    for (final t in data.transactions)
      if ((filter.kind == null || t.kind == filter.kind) &&
          (filter.accountId == null ||
              t.accountId == filter.accountId ||
              t.toAccountId == filter.accountId) &&
          (root == null || categoryIds.contains(t.categoryId)) &&
          (!filter.onlyUnconfirmed || !t.isConfirmed) &&
          (filter.month == null ||
              moscowDay(t.occurredAt).startsWith(filter.month!)) &&
          (needle.isEmpty ||
              foldMerchant('${t.merchant ?? ''} ${t.comment ?? ''}')
                  .contains(needle)))
        t,
  ];
}

/// Состояние аналитики: сколько месяцев показывать, выбранный месяц и вид
/// категорий.
@immutable
class AnalyticsState {
  const AnalyticsState({
    this.months = 6,
    this.month,
    this.kind = TxKind.expense,
  });

  /// 6 или 12 месяцев в столбиках.
  final int months;

  /// Выбранный месяц `YYYY-MM`; `null` — текущий.
  final String? month;
  final TxKind kind;

  AnalyticsState copyWith({
    int? months,
    Object? month = _unset,
    TxKind? kind,
  }) => AnalyticsState(
    months: months ?? this.months,
    month: identical(month, _unset) ? this.month : month as String?,
    kind: kind ?? this.kind,
  );
}

class AnalyticsNotifier extends Notifier<AnalyticsState> {
  @override
  AnalyticsState build() => const AnalyticsState();

  // Метод Notifier, а не сеттер: вызывается из обработчиков нажатий.
  // ignore: use_setters_to_change_properties
  void set(AnalyticsState next) => state = next;
}

final NotifierProvider<AnalyticsNotifier, AnalyticsState>
analyticsStateProvider = NotifierProvider<AnalyticsNotifier, AnalyticsState>(
  AnalyticsNotifier.new,
);
