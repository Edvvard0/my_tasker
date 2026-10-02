import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Балансы: по каждому счёту и общий (spec 4.2). Считаются доменными
/// функциями `core/finance` по **видимым** строкам.
@immutable
class FinanceBalances {
  const FinanceBalances({required this.byAccount, required this.total});

  /// Строит балансы из видимых строк (`at == null` — «сейчас», все данные).
  factory FinanceBalances.compute(
    List<Json> accounts,
    List<Json> transactions,
    List<Json> checkpoints, {
    String? at,
  }) {
    final result = accountBalances(accounts, transactions, checkpoints, at: at);
    return FinanceBalances(
      byAccount: {
        for (final line in (result['accounts']! as List<Object?>).cast<Json>())
          line['id']! as String: line['balance']! as int,
      },
      total: result['total']! as int,
    );
  }

  /// `id счёта -> баланс` (копейки); архивные счета тоже здесь.
  final Map<String, int> byAccount;

  /// Сумма балансов счетов с «учитывать в общем балансе».
  final int total;

  /// Баланс счёта; `0` для неизвестного.
  int of(String accountId) => byAccount[accountId] ?? 0;
}

/// Итоги месяца (spec 5.1): доход, расход и `net = доход − расход`.
@immutable
class MonthTotals {
  const MonthTotals({
    required this.month,
    required this.income,
    required this.expense,
  });

  /// `YYYY-MM` (московский месяц).
  final String month;
  final int income;
  final int expense;

  int get net => income - expense;

  @override
  bool operator ==(Object other) =>
      other is MonthTotals &&
      other.month == month &&
      other.income == income &&
      other.expense == expense;

  @override
  int get hashCode => Object.hash(month, income, expense);

  @override
  String toString() => 'MonthTotals($month, +$income, -$expense)';
}

/// Фильтр ленты операций. Период — московские даты `YYYY-MM-DD`
/// включительно; поиск — по сумме (`1500`, `1 500,50`) и по мерчанту или
/// комментарию (подстрока без учёта регистра).
@immutable
class TransactionFilter {
  const TransactionFilter({
    this.accountId,
    this.categoryId,
    this.withoutCategory = false,
    this.kind,
    this.from,
    this.to,
    this.query = '',
  });

  /// Операции счёта: по `account_id` **или** `to_account_id` (переводы
  /// видны с обеих сторон).
  final String? accountId;

  /// Операции категории и её подкатегорий.
  final String? categoryId;

  /// Только операции без категории (или с удалённой категорией).
  final bool withoutCategory;
  final TransactionKind? kind;
  final String? from;
  final String? to;
  final String query;

  bool get isEmpty =>
      accountId == null &&
      categoryId == null &&
      !withoutCategory &&
      kind == null &&
      from == null &&
      to == null &&
      query.trim().isEmpty;

  TransactionFilter copyWith({
    Object? accountId = _unset,
    Object? categoryId = _unset,
    bool? withoutCategory,
    Object? kind = _unset,
    Object? from = _unset,
    Object? to = _unset,
    String? query,
  }) => TransactionFilter(
    accountId: identical(accountId, _unset)
        ? this.accountId
        : accountId as String?,
    categoryId: identical(categoryId, _unset)
        ? this.categoryId
        : categoryId as String?,
    withoutCategory: withoutCategory ?? this.withoutCategory,
    kind: identical(kind, _unset) ? this.kind : kind as TransactionKind?,
    from: identical(from, _unset) ? this.from : from as String?,
    to: identical(to, _unset) ? this.to : to as String?,
    query: query ?? this.query,
  );

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter &&
      other.accountId == accountId &&
      other.categoryId == categoryId &&
      other.withoutCategory == withoutCategory &&
      other.kind == kind &&
      other.from == from &&
      other.to == to &&
      other.query == query;

  @override
  int get hashCode => Object.hash(
    accountId,
    categoryId,
    withoutCategory,
    kind,
    from,
    to,
    query,
  );
}

const Object _unset = Object();

/// Применяет [filter] к видимым строкам операций. [categoryParents] —
/// `id живой категории -> parent_id` (для фильтра по категории с
/// подкатегориями и «без категории»). Порядок результата: новые сверху
/// (`occurred_at`, затем `id` по убыванию).
List<FinanceTransaction> filterTransactions(
  List<Json> rows,
  TransactionFilter filter, {
  Map<String, String?> categoryParents = const {},
}) {
  final query = filter.query.trim();
  final folded = query.isEmpty ? '' : foldMerchant(query);
  final amount = query.isEmpty ? null : tryParseAmount(query);
  bool matches(Json r) {
    final account = filter.accountId;
    if (account != null &&
        r['account_id'] != account &&
        r['to_account_id'] != account) {
      return false;
    }
    if (filter.kind != null && r['kind'] != filter.kind!.wire) return false;
    final category = r['category_id'] as String?;
    final live = category != null && categoryParents.containsKey(category);
    if (filter.withoutCategory && live) return false;
    final wanted = filter.categoryId;
    if (wanted != null &&
        !(category == wanted ||
            (live && categoryParents[category] == wanted))) {
      return false;
    }
    if (filter.from != null || filter.to != null) {
      final day = moscowDate(r['occurred_at']! as String);
      if (!inPeriod(day, {'from': filter.from, 'to': filter.to})) return false;
    }
    if (query.isNotEmpty) {
      final merchant = foldMerchant((r['merchant'] as String?) ?? '');
      final comment = foldMerchant((r['comment'] as String?) ?? '');
      final byText = merchant.contains(folded) || comment.contains(folded);
      final byAmount = amount != null && (r['amount'] as int?) == amount.abs();
      if (!byText && !byAmount) return false;
    }
    return true;
  }

  final kept =
      [
        for (final r in rows)
          if (matches(r)) r,
      ]..sort((a, b) {
        final byTime = instantSeconds(b['occurred_at']! as String)
            .compareTo(instantSeconds(a['occurred_at']! as String));
        return byTime != 0
            ? byTime
            : (b['id']! as String).compareTo(a['id']! as String);
      });
  return [for (final r in kept) FinanceTransaction.fromRow(r)];
}

/// Лента операций с итогами месяцев для липких заголовков.
@immutable
class TransactionFeed {
  const TransactionFeed({required this.items, required this.months});

  /// Строит ленту: итоги считает `monthly_totals` по тем же операциям, что
  /// в списке (подтверждённые доход/расход без `debt_id`; переводы в итоги
  /// не входят).
  factory TransactionFeed.of(List<FinanceTransaction> items) {
    final totals = monthlyTotals([for (final t in items) t.toRow()]);
    return TransactionFeed(
      items: items,
      months: {
        for (final m in totals)
          m['month']! as String: MonthTotals(
            month: m['month']! as String,
            income: m['income']! as int,
            expense: m['expense']! as int,
          ),
      },
    );
  }

  /// Операции, новые сверху.
  final List<FinanceTransaction> items;

  /// `YYYY-MM -> итоги`; месяцы без доходов и расходов (только переводы)
  /// отсутствуют — для них заголовок показывает нули.
  final Map<String, MonthTotals> months;

  /// Итоги месяца операции [t] (нули, если в месяце нет доходов и расходов).
  MonthTotals totalsFor(FinanceTransaction t) {
    final month = t.moscowDay.substring(0, 7);
    return months[month] ?? MonthTotals(month: month, income: 0, expense: 0);
  }
}
