import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/finance/finance_calc.dart' as calc;
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';

/// Период аналитики: готовые варианты, как сегмент над графиком (02, 5.3.1).
enum AnalyticsPreset {
  month('Месяц', 1),
  quarter('3 мес', 3),
  half('6 мес', 6),
  year('Год', 12),
  all('Всё', null);

  const AnalyticsPreset(this.label, this.months);

  final String label;

  /// Сколько последних месяцев (с текущим); `null` — всё время.
  final int? months;
}

/// Московские даты `YYYY-MM-DD` включительно; `null` в границе — без неё.
@immutable
class AnalyticsPeriod {
  const AnalyticsPeriod({this.from, this.to});

  /// Период варианта [preset] на московскую дату [today]: с первого числа
  /// месяца (текущий месяц и [AnalyticsPreset.months]` - 1` предыдущих) по
  /// конец текущего месяца.
  factory AnalyticsPeriod.of(AnalyticsPreset preset, String today) {
    final months = preset.months;
    if (months == null) return const AnalyticsPeriod();
    final current = today.substring(0, 7);
    return AnalyticsPeriod(
      from: '${addMonths(current, 1 - months)}-01',
      to: monthEnd(current),
    );
  }

  final String? from;
  final String? to;

  /// Период в виде аргумента доменных функций.
  Map<String, Object?> toJson() => {'from': from, 'to': to};
}

/// `YYYY-MM` со сдвигом на [delta] месяцев.
String addMonths(String month, int delta) {
  final year = int.parse(month.substring(0, 4));
  final number = int.parse(month.substring(5, 7));
  final index = year * 12 + (number - 1) + delta;
  final y = index ~/ 12;
  final m = index % 12 + 1;
  return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
}

/// Месяцы от [first] до [last] включительно (`YYYY-MM`).
List<String> monthRange(String first, String last) {
  final out = <String>[];
  for (var m = first; m.compareTo(last) <= 0; m = addMonths(m, 1)) {
    out.add(m);
  }
  return out;
}

/// Подкатегория в группе разбивки.
@immutable
class CategoryChild {
  const CategoryChild({
    required this.categoryId,
    required this.total,
    required this.count,
  });

  final String categoryId;
  final int total;
  final int count;
}

/// Группа разбивки: категория верхнего уровня (или «без категории» при
/// `categoryId == null`) с подкатегориями.
@immutable
class CategoryGroup {
  const CategoryGroup({
    required this.categoryId,
    required this.total,
    required this.own,
    required this.count,
    required this.children,
  });

  final String? categoryId;
  final int total;

  /// Операции прямо на категории группы.
  final int own;
  final int count;
  final List<CategoryChild> children;
}

/// Разбивка по категориям (`category_breakdown`, spec 5.2).
@immutable
class CategoryBreakdown {
  const CategoryBreakdown({required this.total, required this.groups});

  factory CategoryBreakdown.fromJson(Json json) => CategoryBreakdown(
    total: json['total']! as int,
    groups: [
      for (final g in (json['groups']! as List<Object?>).cast<Json>())
        CategoryGroup(
          categoryId: g['category_id'] as String?,
          total: g['total']! as int,
          own: g['own']! as int,
          count: g['count']! as int,
          children: [
            for (final c in (g['children']! as List<Object?>).cast<Json>())
              CategoryChild(
                categoryId: c['category_id']! as String,
                total: c['total']! as int,
                count: c['count']! as int,
              ),
          ],
        ),
    ],
  );

  final int total;
  final List<CategoryGroup> groups;

  bool get isEmpty => groups.isEmpty;
}

/// Мерчант в топе (`top_merchants`).
@immutable
class MerchantTotal {
  const MerchantTotal({
    required this.merchant,
    required this.total,
    required this.count,
  });

  final String merchant;
  final int total;
  final int count;
}

/// Общий баланс на конец даты (`balance_dynamics`).
@immutable
class BalancePoint {
  const BalancePoint({required this.date, required this.total});

  /// Московская дата `YYYY-MM-DD`.
  final String date;
  final int total;
}

/// Сколько точек динамики баланса показываем: последние концы месяцев и
/// «сегодня».
const int maxDynamicsPoints = 24;

/// Всё, что показывает экран «Аналитика» за период (spec 5): итоги по
/// месяцам с заполненными пропусками, разбивки, топ мерчантов, остатки по
/// счетам и динамика общего баланса. Считают доменные функции `core/finance`
/// по **видимым** строкам.
@immutable
class AnalyticsReport {
  const AnalyticsReport({
    required this.preset,
    required this.period,
    required this.today,
    required this.months,
    required this.expenses,
    required this.incomes,
    required this.merchantsExpense,
    required this.merchantsIncome,
    required this.balances,
    required this.dynamics,
  });

  factory AnalyticsReport.compute({
    required AnalyticsPreset preset,
    required String today,
    required List<Json> accounts,
    required List<Json> categories,
    required List<Json> transactions,
    required List<Json> checkpoints,
  }) {
    final period = AnalyticsPeriod.of(preset, today);
    final json = period.toJson();
    final totals = calc.monthlyTotals(transactions, period: json);
    final byMonth = {
      for (final t in totals)
        t['month']! as String: MonthTotals(
          month: t['month']! as String,
          income: t['income']! as int,
          expense: t['expense']! as int,
        ),
    };
    final currentMonth = today.substring(0, 7);
    final firstMonth = period.from != null
        ? period.from!.substring(0, 7)
        : (byMonth.isEmpty ? null : byMonth.keys.first);
    final lastData = byMonth.keys.lastOrNull;
    final lastMonth = period.to != null
        ? period.to!.substring(0, 7)
        : (lastData != null && lastData.compareTo(currentMonth) > 0
              ? lastData
              : currentMonth);
    final months = firstMonth == null
        ? const <MonthTotals>[]
        : [
            for (final m in monthRange(firstMonth, lastMonth))
              byMonth[m] ?? MonthTotals(month: m, income: 0, expense: 0),
          ];

    List<MerchantTotal> merchants(String kind) => [
      for (final m in calc.topMerchants(transactions, kind: kind, period: json))
        MerchantTotal(
          merchant: m['merchant']! as String,
          total: m['total']! as int,
          count: m['count']! as int,
        ),
    ];

    // Динамика: концы месяцев (с месяца перед началом периода) и «сегодня».
    var start = period.from?.substring(0, 7);
    if (start == null) {
      final seen = <String>[
        for (final a in accounts)
          (a['opening_date']! as String).substring(0, 7),
        for (final t in transactions) moscowMonth(t['occurred_at']! as String),
      ]..sort();
      start = seen.isEmpty ? currentMonth : seen.first;
    }
    final dates = <String>[
      for (final m in monthRange(addMonths(start, -1), currentMonth))
        if (monthEnd(m).compareTo(today) < 0) monthEnd(m),
    ];
    final shown = dates.length > maxDynamicsPoints - 1
        ? dates.sublist(dates.length - (maxDynamicsPoints - 1))
        : dates;
    final points = [...shown, today];
    final dynamics = calc.balanceDynamics(
      accounts,
      transactions,
      checkpoints,
      points,
    );

    return AnalyticsReport(
      preset: preset,
      period: period,
      today: today,
      months: months,
      expenses: CategoryBreakdown.fromJson(
        calc.categoryBreakdown(
          transactions,
          categories,
          'expense',
          period: json,
        ),
      ),
      incomes: CategoryBreakdown.fromJson(
        calc.categoryBreakdown(
          transactions,
          categories,
          'income',
          period: json,
        ),
      ),
      merchantsExpense: merchants('expense'),
      merchantsIncome: merchants('income'),
      balances: FinanceBalances.compute(accounts, transactions, checkpoints),
      dynamics: [
        for (final p in dynamics)
          BalancePoint(date: p['date']! as String, total: p['total']! as int),
      ],
    );
  }

  final AnalyticsPreset preset;
  final AnalyticsPeriod period;

  /// Московская «сегодня».
  final String today;

  /// Итоги по каждому месяцу периода, пропуски заполнены нулями.
  final List<MonthTotals> months;
  final CategoryBreakdown expenses;
  final CategoryBreakdown incomes;
  final List<MerchantTotal> merchantsExpense;
  final List<MerchantTotal> merchantsIncome;
  final FinanceBalances balances;
  final List<BalancePoint> dynamics;

  int get income => months.fold(0, (s, m) => s + m.income);
  int get expense => months.fold(0, (s, m) => s + m.expense);

  /// Итог периода: доход − расход, со знаком.
  int get net => income - expense;

  /// В периоде нет ни одной операции в аналитике.
  bool get hasOperations => months.any((m) => m.income > 0 || m.expense > 0);
}
