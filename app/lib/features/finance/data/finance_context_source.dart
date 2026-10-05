import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart' show receivables;
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Маска суммы в превью при включённом режиме «скрыть суммы».
const String maskedAmount = '••• ₽';

/// «Финансы» как источник контекста для чата ИИ (агент «Финансы»): общий
/// баланс и счета, доход и расход за период с разбивкой по категориям,
/// цели с формулой, долги и ожидаемые поступления из «Работы». Расчёты —
/// те же чистые функции, что в интерфейсе и на сервере (общие векторы).
///
/// Суммы — данные чувствительные: источник помечен [sensitive], поэтому
/// чат с ним не уходит в облако (`sensitive_context_forbidden`, spec
/// Этапа 3, 1.3 и 5.2) и работает только с локальной моделью.
///
/// Фильтр `period` относится к доходу, расходу и категориям: `month` —
/// текущий месяц по Москве, `quarter` — три последних месяца, `all` — всё
/// время.
class FinanceContextSource extends ContextSource {
  const FinanceContextSource();

  @override
  String get id => 'finance';

  @override
  String get label => 'Финансы';

  @override
  String get description =>
      'Счета и баланс, доход и расход, цели, долги (суммы — только для '
      'локальной модели)';

  @override
  bool get sensitive => true;

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'period',
      label: 'Период для дохода и расхода',
      options: {
        'month': 'Текущий месяц',
        'quarter': 'Три месяца',
        'all': 'Всё время',
      },
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'period': 'month'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['period']) {
    'quarter' => 'доход и расход за три месяца',
    'all' => 'доход и расход за всё время',
    _ => 'доход и расход за месяц',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    String money(int kopecks) =>
        env.hideAmounts ? maskedAmount : formatAmountClamped(kopecks);
    final accounts = [
      for (final r in await env.readRows('accounts')) Account.fromRow(r),
    ];
    final categories = [
      for (final r in await env.readRows('categories')) FinCategory.fromRow(r),
    ];
    final txs = [
      for (final r in await env.readRows('transactions'))
        FinTransaction.fromRow(r),
    ];
    final checkpoints = [
      for (final r in await env.readRows('balance_checkpoints'))
        BalanceCheckpoint.fromRow(r),
    ];
    final debts = [
      for (final r in await env.readRows('debts')) Debt.fromRow(r),
    ];
    final repayments = [
      for (final r in await env.readRows('debt_repayments'))
        DebtRepayment.fromRow(r),
    ];
    final goals = [
      for (final r in await env.readRows('goals')) Goal.fromRow(r),
    ];
    final projects = [
      for (final r in await env.readRows('projects')) WorkProject.fromRow(r),
    ];
    final people = {
      for (final r in await env.readRows('people'))
        r['id']! as String: WorkPerson.fromRow(r).name,
    };
    final crs = [
      for (final r in await env.readRows('change_requests'))
        ChangeRequest.fromRow(r),
    ];
    final allocations = [
      for (final r in await env.readRows('payment_allocations'))
        Allocation.fromRow(r),
    ];
    if (accounts.isEmpty && goals.isEmpty && debts.isEmpty && txs.isEmpty) {
      return const [];
    }

    final out = <String>[];
    final balances = accountBalances(accounts, txs, checkpoints);
    out.add('- Общий баланс: ${money(balances.total)}');
    for (final a in accounts) {
      if (a.archived) continue;
      final parts = [
        'счёт «${a.name}»',
        a.kind.label.toLowerCase(),
        money(balances.of(a.id)),
        if (!a.includeInTotal) 'не в общем балансе',
      ];
      out.add('- ${parts.join(' · ')}');
    }

    final today = moscowDay(env.now);
    final month = today.substring(0, 7);
    final (period, caption) = switch (filter['period']) {
      'all' => (null, 'за всё время'),
      'quarter' => (
        DatePeriod(
          from: '${monthsBack(month, 3).first}-01',
          to: monthEnd(month),
        ),
        'за три месяца',
      ),
      _ => (monthPeriod(month), 'за месяц'),
    };
    final totals = monthlyTotals(txs, period: period);
    var income = 0;
    var expense = 0;
    for (final m in totals) {
      income += m.income;
      expense += m.expense;
    }
    out.add(
      '- Доход $caption: ${money(income)} · расход: '
      '${money(expense)} · итог: ${money(income - expense)}',
    );
    final breakdown = categoryBreakdown(
      txs,
      categories,
      TxKind.expense,
      period: period,
    );
    if (breakdown.groups.isNotEmpty) {
      final names = {for (final c in categories) c.id: c.name};
      final parts = [
        for (final g in breakdown.groups.take(6))
          '${names[g.categoryId] ?? 'Без категории'} ${money(g.total)}',
      ];
      out.add('- Расходы по категориям $caption: ${parts.join(', ')}');
    }

    final summary = debtsSummary(debts, repayments, today: today);
    out.add(
      '- Мне должны (открытые долги): ${money(summary.owedToMe)} · '
      'я должен: ${money(summary.iOwe)}',
    );
    for (final d in debts) {
      final s = summary.stateOf(d.id)!;
      if (s.status == DebtStatus.closed) continue;
      final who = people[d.personId] ?? d.counterparty ?? 'не указан';
      out.add(
        '- Долг · ${d.direction.label.toLowerCase()} · $who: осталось '
        '${money(s.remaining)} из ${money(d.amount)}'
        '${d.dueDate == null ? '' : ' · срок ${d.dueDate}'}'
        '${s.overdue ? ' (просрочен)' : ''}',
      );
    }

    final owed = receivables(projects, crs, allocations);
    out.add('- Ожидаемые поступления из «Работы»: ${money(owed.total)}');

    for (final g in goals) {
      if (g.archived) continue;
      final p = goalProgress(
        g,
        accounts: accounts,
        transactions: txs,
        checkpoints: checkpoints,
        debts: debts,
        repayments: repayments,
        projects: projects,
        changeRequests: crs,
        allocations: allocations,
      );
      final parts = [
        'цель «${g.name}»',
        'есть ${money(p.have)} из ${money(p.target)} (${formatPercentBp(p.progressBp)})',
        if (p.reached)
          'цель достигнута, запас ${money(p.surplus)}'
        else
          'не хватает ${money(p.missing)}',
        if (g.deadlineDate != null) 'срок ${g.deadlineDate}',
      ];
      out.add('- ${parts.join(' · ')}');
    }
    return out;
  }
}
