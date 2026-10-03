import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderFamily;
import 'package:my_tasker/core/finance/finance_calc.dart' as calc;
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart'
    show nowProvider;
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';

/// Провайдеры Финансов (срезы 5a–5c: счета, операции, долги, цели, аналитика). Все строки — **видимые** (spec Этапа 5,
/// раздел 2): живые и с живыми родителями; операция-перевод видна, только
/// когда живы оба счёта. Расчёты ведут доменные функции `core/finance`.

StreamProvider<List<Json>> _rows(String table, {String? orderBy}) =>
    StreamProvider<List<Json>>(
      (ref) => ref
          .watch(syncStoreProvider)
          .watchVisibleRows(table, orderBy: orderBy),
    );

/// Видимые строки (JSON-вид) — вход доменных расчётов.
final StreamProvider<List<Json>> accountRowsProvider = _rows(
  FinanceRepository.accountsTable,
  orderBy: 't.created_at, t.id',
);
final StreamProvider<List<Json>> categoryRowsProvider = _rows(
  FinanceRepository.categoriesTable,
  orderBy: 't.name, t.id',
);
final StreamProvider<List<Json>> transactionRowsProvider = _rows(
  FinanceRepository.transactionsTable,
);
final StreamProvider<List<Json>> checkpointRowsProvider = _rows(
  FinanceRepository.checkpointsTable,
  orderBy: 't.checked_at, t.id',
);
final StreamProvider<List<Json>> debtRowsProvider = _rows(
  FinanceRepository.debtsTable,
  orderBy: 't.created_at, t.id',
);

/// Погашения видимых долгов (родитель-долг жив).
final StreamProvider<List<Json>> repaymentRowsProvider = _rows(
  FinanceRepository.repaymentsTable,
  orderBy: 't.repaid_on, t.id',
);

/// Видимые цели в порядке создания (включая архивные).
final StreamProvider<List<Json>> goalRowsProvider = _rows(
  FinanceRepository.goalsTable,
  orderBy: 't.created_at, t.id',
);

AsyncValue<List<T>> _typed<T>(
  AsyncValue<List<Json>> rows,
  T Function(Json) parse,
) => rows.whenData((list) => [for (final r in list) parse(r)]);

/// Все видимые счета (включая архивные), в порядке создания.
final Provider<AsyncValue<List<Account>>> accountsProvider =
    Provider<AsyncValue<List<Account>>>(
      (ref) => _typed(ref.watch(accountRowsProvider), Account.fromRow),
    );

/// Счета без архивных — для списков и выбора в редакторе операции.
final Provider<AsyncValue<List<Account>>> activeAccountsProvider =
    Provider<AsyncValue<List<Account>>>(
      (ref) => ref
          .watch(accountsProvider)
          .whenData(
            (list) => [
              for (final a in list)
                if (!a.archived) a,
            ],
          ),
    );

/// Живые категории по названию.
final Provider<AsyncValue<List<FinanceCategory>>> categoriesProvider =
    Provider<AsyncValue<List<FinanceCategory>>>(
      (ref) => _typed(ref.watch(categoryRowsProvider), FinanceCategory.fromRow),
    );

/// Все видимые точки сверки по возрастанию момента.
final Provider<AsyncValue<List<BalanceCheckpoint>>> checkpointsProvider =
    Provider<AsyncValue<List<BalanceCheckpoint>>>(
      (ref) =>
          _typed(ref.watch(checkpointRowsProvider), BalanceCheckpoint.fromRow),
    );

/// Точки сверки одного счёта.
final ProviderFamily<AsyncValue<List<BalanceCheckpoint>>, String>
checkpointsOfProvider =
    Provider.family<AsyncValue<List<BalanceCheckpoint>>, String>(
      (ref, accountId) => ref
          .watch(checkpointsProvider)
          .whenData(
            (list) => [
              for (final c in list)
                if (c.accountId == accountId) c,
            ],
          ),
    );

/// Балансы по счетам и общий (spec 4.2) на «сейчас»: считаются по видимым
/// строкам; архивные счета входят в общий баланс по флагу
/// `include_in_total`.
final Provider<AsyncValue<FinanceBalances>>
financeBalancesProvider = Provider<AsyncValue<FinanceBalances>>((ref) {
  final accounts = ref.watch(accountRowsProvider);
  final transactions = ref.watch(transactionRowsProvider);
  final checkpoints = ref.watch(checkpointRowsProvider);
  for (final v in <AsyncValue<Object?>>[accounts, transactions, checkpoints]) {
    if (v.hasError && !v.hasValue) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
    }
  }
  if (!accounts.hasValue || !transactions.hasValue || !checkpoints.hasValue) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data(
    FinanceBalances.compute(
      accounts.requireValue,
      transactions.requireValue,
      checkpoints.requireValue,
    ),
  );
});

/// Общий баланс (копейки).
final Provider<AsyncValue<int>> totalBalanceProvider =
    Provider<AsyncValue<int>>(
      (ref) => ref.watch(financeBalancesProvider).whenData((b) => b.total),
    );

/// Баланс одного счёта (копейки).
final ProviderFamily<AsyncValue<int>, String> accountBalanceProvider =
    Provider.family<AsyncValue<int>, String>(
      (ref, accountId) =>
          ref.watch(financeBalancesProvider).whenData((b) => b.of(accountId)),
    );

/// Корректировки сверок счёта (spec 4.4), по возрастанию момента.
final ProviderFamily<AsyncValue<List<BalanceAdjustment>>, String>
accountAdjustmentsProvider =
    Provider.family<AsyncValue<List<BalanceAdjustment>>, String>((
      ref,
      accountId,
    ) {
      final accounts = ref.watch(accountRowsProvider);
      final transactions = ref.watch(transactionRowsProvider);
      final checkpoints = ref.watch(checkpointRowsProvider);
      if (!accounts.hasValue ||
          !transactions.hasValue ||
          !checkpoints.hasValue) {
        final failed = [
          accounts,
          transactions,
          checkpoints,
        ].where((v) => v.hasError && !v.hasValue);
        return failed.isEmpty
            ? const AsyncValue.loading()
            : AsyncValue.error(
                failed.first.error!,
                failed.first.stackTrace ?? StackTrace.empty,
              );
      }
      final account = accounts.requireValue
          .where((a) => a['id'] == accountId)
          .firstOrNull;
      if (account == null) return const AsyncValue.data([]);
      return AsyncValue.data([
        for (final line in calc.adjustments(
          account,
          transactions.requireValue,
          checkpoints.requireValue,
        ))
          BalanceAdjustment.fromJson(line),
      ]);
    });

/// Лента операций с фильтром: новые сверху + итоги месяцев для липких
/// заголовков.
final ProviderFamily<AsyncValue<TransactionFeed>, TransactionFilter>
transactionFeedProvider =
    Provider.family<AsyncValue<TransactionFeed>, TransactionFilter>((
      ref,
      filter,
    ) {
      final rows = ref.watch(transactionRowsProvider);
      final categories = ref.watch(categoryRowsProvider);
      if (rows.hasError && !rows.hasValue) {
        return AsyncValue.error(
          rows.error!,
          rows.stackTrace ?? StackTrace.empty,
        );
      }
      if (categories.hasError && !categories.hasValue) {
        return AsyncValue.error(
          categories.error!,
          categories.stackTrace ?? StackTrace.empty,
        );
      }
      if (!rows.hasValue || !categories.hasValue) {
        return const AsyncValue.loading();
      }
      return AsyncValue.data(
        TransactionFeed.of(
          filterTransactions(
            rows.requireValue,
            filter,
            categoryParents: {
              for (final c in categories.requireValue)
                c['id']! as String: c['parent_id'] as String?,
            },
          ),
        ),
      );
    });

/// Текущий фильтр ленты (состояние экрана).
class TransactionFilterNotifier extends Notifier<TransactionFilter> {
  @override
  TransactionFilter build() => const TransactionFilter();

  void setAccount(String? id) => state = state.copyWith(accountId: id);

  void setCategory(String? id) =>
      state = state.copyWith(categoryId: id, withoutCategory: false);

  void setWithoutCategory({required bool value}) => state = state.copyWith(
    withoutCategory: value,
    categoryId: value ? null : state.categoryId,
  );

  void setKind(TransactionKind? kind) => state = state.copyWith(kind: kind);

  /// Период — московские даты `YYYY-MM-DD` включительно (`null` — без границы).
  void setPeriod({String? from, String? to}) =>
      state = state.copyWith(from: from, to: to);

  void setQuery(String query) => state = state.copyWith(query: query);

  void reset() => state = const TransactionFilter();
}

final NotifierProvider<TransactionFilterNotifier, TransactionFilter>
transactionFilterProvider =
    NotifierProvider<TransactionFilterNotifier, TransactionFilter>(
      TransactionFilterNotifier.new,
    );

/// Лента по текущему фильтру [transactionFilterProvider].
final Provider<AsyncValue<TransactionFeed>> filteredTransactionFeedProvider =
    Provider<AsyncValue<TransactionFeed>>(
      (ref) => ref.watch(
        transactionFeedProvider(ref.watch(transactionFilterProvider)),
      ),
    );

/// Засев предустановленных категорий (spec 3.2): запускается после первой
/// полной синхронизации (`lastSuccessAt`) и повторяется, пока она не
/// состоялась. Результат — число созданных категорий. Следит за ним экран
/// «Финансы» (как `calendarBootstrapProvider`).
final FutureProvider<int> financeBootstrapProvider = FutureProvider<int>((ref) {
  ref.watch(syncStatusProvider.select((s) => s.run.lastSuccessAt));
  return ref.watch(financeRepositoryProvider).ensurePresetCategories();
});

/// Московская «сегодня» (`YYYY-MM-DD`) по часам приложения: от неё зависит
/// просрочка долгов (spec 6.1).
final Provider<String> moscowTodayProvider = Provider<String>(
  (ref) => moscowDateOfSeconds(
    ref.watch(nowProvider).millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond,
  ),
);

/// Состояния всех видимых долгов и остатки по направлениям
/// (`debts_summary`, spec 6.1).
final Provider<AsyncValue<DebtsOverview>> debtsOverviewProvider =
    Provider<AsyncValue<DebtsOverview>>((ref) {
      final debts = ref.watch(debtRowsProvider);
      final repayments = ref.watch(repaymentRowsProvider);
      for (final v in <AsyncValue<Object?>>[debts, repayments]) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (!debts.hasValue || !repayments.hasValue) {
        return const AsyncValue.loading();
      }
      return AsyncValue.data(
        DebtsOverview.compute(
          debts.requireValue,
          repayments.requireValue,
          today: ref.watch(moscowTodayProvider),
        ),
      );
    });

/// Карточка долга: состояние и история погашений; `null` в данных — долга
/// нет среди видимых (удалён, в корзине).
final ProviderFamily<AsyncValue<DebtDetail?>, String> debtDetailProvider =
    Provider.family<AsyncValue<DebtDetail?>, String>((ref, debtId) {
      final overview = ref.watch(debtsOverviewProvider);
      final repayments = ref.watch(repaymentRowsProvider);
      if (repayments.hasError && !repayments.hasValue) {
        return AsyncValue.error(
          repayments.error!,
          repayments.stackTrace ?? StackTrace.empty,
        );
      }
      if (!repayments.hasValue) return const AsyncValue.loading();
      return overview.whenData((o) {
        final state = o.byId(debtId);
        if (state == null) return null;
        return DebtDetail(
          state: state,
          repayments: repaymentsOfDebt(repayments.requireValue, debtId),
        );
      });
    });

/// Данные Работы для слагаемого `receivables` формулы цели. Клиента «Работы»
/// пока нет, поэтому пусто и ожидаемые поступления считаются как 0; когда
/// Работа появится, провайдер отдаст её строки (spec 6.2).
final Provider<WorkData> workDataProvider = Provider<WorkData>(
  (ref) => const WorkData.empty(),
);

/// Цели с прогрессом (`goal_progress`, spec 6.2) по видимым строкам.
final Provider<AsyncValue<GoalsOverview>> goalsOverviewProvider =
    Provider<AsyncValue<GoalsOverview>>((ref) {
      final inputs = <AsyncValue<List<Json>>>[
        ref.watch(goalRowsProvider),
        ref.watch(accountRowsProvider),
        ref.watch(transactionRowsProvider),
        ref.watch(checkpointRowsProvider),
        ref.watch(debtRowsProvider),
        ref.watch(repaymentRowsProvider),
      ];
      for (final v in inputs) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (inputs.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        GoalsOverview.compute(
          goals: inputs[0].requireValue,
          accounts: inputs[1].requireValue,
          transactions: inputs[2].requireValue,
          checkpoints: inputs[3].requireValue,
          debts: inputs[4].requireValue,
          repayments: inputs[5].requireValue,
          work: ref.watch(workDataProvider),
        ),
      );
    });

/// Карточка цели; `null` в данных — цели нет среди видимых.
final ProviderFamily<AsyncValue<GoalState?>, String> goalDetailProvider =
    Provider.family<AsyncValue<GoalState?>, String>(
      (ref, goalId) => ref
          .watch(goalsOverviewProvider)
          .whenData((overview) => overview.byId(goalId)),
    );

/// Выбранный период аналитики (состояние экрана).
class AnalyticsPresetNotifier extends Notifier<AnalyticsPreset> {
  @override
  AnalyticsPreset build() => AnalyticsPreset.quarter;

  // Метод, а не сеттер: обработчик выбора сегмента в экране.
  // ignore: use_setters_to_change_properties
  void select(AnalyticsPreset preset) => state = preset;
}

final NotifierProvider<AnalyticsPresetNotifier, AnalyticsPreset>
analyticsPresetProvider =
    NotifierProvider<AnalyticsPresetNotifier, AnalyticsPreset>(
      AnalyticsPresetNotifier.new,
    );

/// Аналитика за выбранный период (spec 5) по видимым строкам.
final Provider<AsyncValue<AnalyticsReport>> analyticsReportProvider =
    Provider<AsyncValue<AnalyticsReport>>((ref) {
      final inputs = <AsyncValue<List<Json>>>[
        ref.watch(accountRowsProvider),
        ref.watch(categoryRowsProvider),
        ref.watch(transactionRowsProvider),
        ref.watch(checkpointRowsProvider),
      ];
      for (final v in inputs) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (inputs.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        AnalyticsReport.compute(
          preset: ref.watch(analyticsPresetProvider),
          today: ref.watch(moscowTodayProvider),
          accounts: inputs[0].requireValue,
          categories: inputs[1].requireValue,
          transactions: inputs[2].requireValue,
          checkpoints: inputs[3].requireValue,
        ),
      );
    });
