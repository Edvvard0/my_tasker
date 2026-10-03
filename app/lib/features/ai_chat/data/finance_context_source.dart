import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';

/// Строка вместо данных, пока раздел «Финансы» закрыт замком.
const String financeLockedLine =
    '- Раздел «Финансы» заблокирован: данные не включены. Разблокируйте '
    'раздел, чтобы ассистент их увидел.';

/// Первая строка, когда суммы не отправляются.
const String financeAmountsWithheldLine =
    '- Суммы не включены: включён режим «скрыть суммы», и отправку сумм '
    'вы не разрешили. Ниже только структура: названия и количество.';

/// Финансы (Этап 5) как источник контекста для агента «Финансы»: балансы по
/// счетам, доходы и расходы за период по категориям, прогресс целей, долги.
///
/// Считает те же доменные функции, что и экраны (`FinanceBalances`,
/// `AnalyticsReport`, `GoalsOverview`, `DebtsOverview`), — расчётов здесь нет.
///
/// Данные Финансов чувствительные: источник помечен «только локально» и не
/// уходит в облако. Приватность клиента: пока раздел закрыт замком, данных
/// нет вообще; при включённом «скрыть суммы» суммы не попадают в текст,
/// пока пользователь не подтвердит их отправку в превью ([access]).
///
/// Фильтр `period`: `month`, `quarter`, `half`, `year` — окна аналитики.
class FinanceContextSource extends ContextSource {
  const FinanceContextSource({required this.access});

  /// Что сейчас можно положить в контекст: открыт ли раздел и разрешены ли
  /// суммы. Читается при каждой сборке (свежее состояние).
  final FinanceAiAccess Function() access;

  @override
  String get id => 'finance';

  @override
  String get label => 'Финансы';

  @override
  String get description =>
      'Балансы счетов, доходы и расходы по категориям, цели, долги';

  @override
  bool get sensitive => true;

  static const Map<String, AnalyticsPreset> _presets = {
    'month': AnalyticsPreset.month,
    'quarter': AnalyticsPreset.quarter,
    'half': AnalyticsPreset.half,
    'year': AnalyticsPreset.year,
  };

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'period',
      label: 'Период',
      options: {
        'month': 'Месяц',
        'quarter': '3 месяца',
        'half': '6 месяцев',
        'year': 'Год',
      },
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'period': 'month'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['period']) {
    'quarter' => 'за 3 месяца',
    'half' => 'за 6 месяцев',
    'year' => 'за год',
    _ => 'за месяц',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final access = this.access();
    if (!access.unlocked) return const [financeLockedLine];

    final accounts = await env.readRows(FinanceRepository.accountsTable);
    final categories = await env.readRows(FinanceRepository.categoriesTable);
    final transactions = await env.readRows(
      FinanceRepository.transactionsTable,
    );
    final checkpoints = await env.readRows(FinanceRepository.checkpointsTable);
    final debts = await env.readRows(FinanceRepository.debtsTable);
    final repayments = await env.readRows(FinanceRepository.repaymentsTable);
    final goals = await env.readRows(FinanceRepository.goalsTable);

    final today = moscowDateOfSeconds(
      env.now.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
    );
    final report = AnalyticsReport.compute(
      preset: _presets['${filter['period']}'] ?? AnalyticsPreset.month,
      today: today,
      accounts: accounts,
      categories: categories,
      transactions: transactions,
      checkpoints: checkpoints,
    );
    final goalsOverview = GoalsOverview.compute(
      goals: goals,
      accounts: accounts,
      transactions: transactions,
      checkpoints: checkpoints,
      debts: debts,
      repayments: repayments,
    );
    final debtsOverview = DebtsOverview.compute(
      debts,
      repayments,
      today: today,
    );

    final names = {
      for (final c in categories) c['id']! as String: c['name']! as String,
    };
    final showAmounts = access.amounts;
    // Итоги и балансы — вычисляемые: могут выйти за предел одной суммы.
    String money(int kopecks) => formatAmountSafe(kopecks);

    final out = <String>[
      if (!showAmounts) financeAmountsWithheldLine,
      ..._accounts(
        accounts,
        report.balances,
        showAmounts: showAmounts,
        money: money,
      ),
      ..._breakdown(
        'Расходы',
        report.expenses,
        report.period,
        names,
        showAmounts: showAmounts,
        money: money,
      ),
      ..._breakdown(
        'Доходы',
        report.incomes,
        report.period,
        names,
        showAmounts: showAmounts,
        money: money,
      ),
      ..._goals(goalsOverview, showAmounts: showAmounts, money: money),
      ..._debts(debtsOverview, showAmounts: showAmounts, money: money),
    ];
    return out;
  }

  List<String> _accounts(
    List<Map<String, Object?>> rows,
    FinanceBalances balances, {
    required bool showAmounts,
    required String Function(int) money,
  }) {
    final list = [for (final r in rows) Account.fromRow(r)]
        .where((a) => !a.archived)
        .toList();
    if (list.isEmpty) return const ['Счета: нет'];
    return [
      if (showAmounts)
        'Счета (общий баланс ${money(balances.total)}):'
      else
        'Счета:',
      for (final a in list)
        '- ${[a.name, a.kind.label.toLowerCase(), if (!a.includeInTotal) 'не в общем балансе', if (showAmounts) money(balances.of(a.id))].join(' · ')}',
    ];
  }

  List<String> _breakdown(
    String title,
    CategoryBreakdown breakdown,
    AnalyticsPeriod period,
    Map<String, String> names, {
    required bool showAmounts,
    required String Function(int) money,
  }) {
    final range = '${period.from ?? 'с начала'} — ${period.to ?? 'сегодня'}';
    if (breakdown.isEmpty) return ['$title за период ($range): нет операций'];
    final total = showAmounts ? ': ${money(breakdown.total)}' : '';
    return [
      '$title за период ($range)$total, по категориям:',
      for (final g in breakdown.groups)
        '- ${[names[g.categoryId] ?? 'Без категории', if (showAmounts) money(g.total), '${g.count} оп.'].join(' · ')}',
    ];
  }

  List<String> _goals(
    GoalsOverview overview, {
    required bool showAmounts,
    required String Function(int) money,
  }) {
    final active = overview.active;
    if (active.isEmpty) return const ['Цели: нет'];
    return [
      'Цели:',
      for (final s in active)
        '- ${[
          s.goal.name,
          if (showAmounts) ...['${s.progress.percentText} %', 'накоплено ${money(s.progress.have)} из ${money(s.progress.target)}', if (s.progress.reached) 'достигнута'],
          if (s.goal.deadlineDate != null) 'срок ${s.goal.deadlineDate}',
        ].join(' · ')}',
    ];
  }

  List<String> _debts(
    DebtsOverview overview, {
    required bool showAmounts,
    required String Function(int) money,
  }) {
    if (overview.isEmpty) return const ['Долги: нет'];
    final open = [
      for (final s in overview.debts)
        if (!s.isClosed) s,
    ];
    return [
      if (showAmounts)
        'Долги (мне должны ${money(overview.owedToMe)}, '
            'я должен ${money(overview.iOwe)}):'
      else
        'Долги:',
      for (final s in open)
        '- ${[s.debt.who, s.debt.direction.label.toLowerCase(), if (showAmounts) 'остаток ${money(s.remaining)} из ${money(s.debt.amount)}', if (s.overdue) 'просрочен', if (s.debt.dueDate != null) 'срок ${s.debt.dueDate}'].join(' · ')}',
      if (open.isEmpty) '- открытых долгов нет',
    ];
  }
}
