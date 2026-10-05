/// Расчёты «Финансов» (spec Этапа 5, разделы 4–8). Чистые функции, один в
/// один с эталоном `backend/src/tasker/finance/reference.py`; поведение
/// закреплено общими векторами `shared-test-vectors/finance/*.json`.
///
/// Деньги — целые копейки и **никогда не округляются**: суммы только
/// складываются и вычитаются. Деление одно — доля цели
/// ([progressBasisPoints]), вниз. «Месяц» и «день» — по Москве (UTC+3).
/// Считается только подтверждённое (spec 4.3).
library;

import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart'
    show DatePeriod, moscowDate, moscowOffset, receivables;
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Период отчёта — [DatePeriod] «Работы»: границы — московские даты
/// включительно, `null` — без ограничения.
export 'package:my_tasker/features/work/domain/work_calc.dart'
    show DatePeriod, monthPeriod;

// ------------------------------------------------------------------ время

/// Первый момент московской даты `YYYY-MM-DD`: 00:00 по UTC+3 = 21:00Z
/// предыдущих суток.
DateTime openingInstant(String day) => _civil(day).subtract(moscowOffset);

/// Последняя целая секунда московской даты (23:59:59 по UTC+3).
DateTime endOfDay(String day) =>
    openingInstant(day).add(const Duration(days: 1, seconds: -1));

/// Последняя дата месяца `YYYY-MM`.
String monthEnd(String month) {
  final year = int.parse(month.substring(0, 4));
  final number = int.parse(month.substring(5, 7));
  final last = DateTime.utc(year, number + 1).subtract(const Duration(days: 1));
  return '${_pad(last.year, 4)}-${_pad(last.month, 2)}-${_pad(last.day, 2)}';
}

/// Список месяцев `YYYY-MM` по возрастанию: [count] последних, считая
/// [last] (пропуски месяцев без операций заполняются).
List<String> monthsBack(String last, int count) {
  var year = int.parse(last.substring(0, 4));
  var month = int.parse(last.substring(5, 7));
  final out = <String>[];
  for (var i = 0; i < count; i++) {
    out.add(
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}',
    );
    month--;
    if (month == 0) {
      month = 12;
      year--;
    }
  }
  return out.reversed.toList();
}

DateTime _civil(String day) => DateTime.utc(
  int.parse(day.substring(0, 4)),
  int.parse(day.substring(5, 7)),
  int.parse(day.substring(8, 10)),
);

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// Московская дата момента (`YYYY-MM-DD`).
String moscowDay(DateTime instant) => moscowDate(instant);

/// Момент для выбранной московской даты: сегодня — [now] (до секунды),
/// другой день — полдень по Москве (09:00Z): дата и месяц те же.
DateTime momentForDate(String day, DateTime now) {
  if (moscowDay(now) == day) {
    return DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true,
    );
  }
  final date = _civil(day);
  return DateTime.utc(date.year, date.month, date.day, 9);
}

/// Момент [at] раньше открытия счёта: операция не изменит его баланс (всё до
/// открытия уже входит в начальный остаток). Нужна для предупреждения при
/// вводе «задним числом».
bool isBeforeOpening(Account account, DateTime at) =>
    at.isBefore(openingInstant(account.openingDate));

/// Операция [at] на счёте [accountId] не изменит баланс: она не позже
/// точки сверки, а точка — истина на свой момент (spec 4.2). Нужна для
/// предупреждения при вводе «задним числом».
bool isBeforeLastCheckpoint(
  String accountId,
  DateTime at,
  Iterable<BalanceCheckpoint> checkpoints,
) {
  for (final cp in checkpoints) {
    if (cp.accountId == accountId && !cp.checkedAt.isBefore(at)) return true;
  }
  return false;
}

// ------------------------------------------------------------------ текст

final RegExp _spaces = RegExp('[ \t\n\r ]+');

/// Сжимает пробельные символы (пробел, табуляция, `\n`, `\r`, NBSP) в
/// один пробел и обрезает края.
String collapseSpaces(String text) =>
    text.replaceAll(_spaces, ' ').replaceAll(RegExp(r'^ +| +$'), '');

/// Ключ мерчанта: пробелы схлопнуты, понижены только заглавные ASCII и
/// кириллица (`toLowerCase` в разных средах даёт разное, spec 5.2).
String foldMerchant(String text) {
  final out = StringBuffer();
  for (final c in collapseSpaces(text).runes) {
    if ((c >= 0x41 && c <= 0x5A) || (c >= 0x410 && c <= 0x42F)) {
      out.writeCharCode(c + 32);
    } else if (c == 0x401) {
      out.writeCharCode(0x451);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Сравнение строк по кодовым точкам (как `str` в Python).
int compareCodePoints(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (true) {
    final hasLeft = left.moveNext();
    final hasRight = right.moveNext();
    if (!hasLeft || !hasRight) {
      return hasLeft ? 1 : (hasRight ? -1 : 0);
    }
    if (left.current != right.current) {
      return left.current < right.current ? -1 : 1;
    }
  }
}

/// Ключ уникальности банковской операции в пределах счёта (spec 7.2) или
/// `null`: у идентификатора и хеша разные ключи.
String? dedupKey(FinTransaction tx) {
  if (tx.externalId != null) return 'ext|${tx.accountId}|${tx.externalId}';
  if (tx.dedupHash != null) return 'hash|${tx.accountId}|${tx.dedupHash}';
  return null;
}

/// Доля цели в сотых долях процента, вниз; `0` при `have <= 0`.
int progressBasisPoints(int have, int target) =>
    target <= 0 || have <= 0 ? 0 : have * 10000 ~/ target;

// ------------------------------------------------------------------ балансы

/// Влияние операции на баланс счёта (со знаком); не подтверждённая — `0`.
int effect(FinTransaction tx, String accountId) {
  if (!tx.isConfirmed) return 0;
  switch (tx.kind) {
    case TxKind.income:
      return tx.accountId == accountId ? tx.amount : 0;
    case TxKind.expense:
      return tx.accountId == accountId ? -tx.amount : 0;
    case TxKind.transfer:
      var total = 0;
      if (tx.accountId == accountId) total -= tx.amount;
      if (tx.toAccountId == accountId) total += tx.amount;
      return total;
  }
}

int _compareCheckpoints(BalanceCheckpoint a, BalanceCheckpoint b) {
  final byTime = a.checkedAt.compareTo(b.checkedAt);
  return byTime != 0 ? byTime : compareCodePoints(a.id, b.id);
}

/// Баланс счёта на момент [at] (`null` — сейчас, все данные), spec 4.2.
///
/// Опорная точка — позднейшая из открытия (начало московских суток
/// `opening_date`) и точек сверки счёта до [at]; при равных моментах точка
/// сверки сильнее, среди точек — большая пара `(checked_at, id)`.
/// Баланс = опорная сумма + влияние подтверждённых операций после опорной
/// точки (после точки сверки — строго, от открытия — включительно) до
/// [at] включительно. До открытия на счёте `0`.
int balanceAt(
  Account account,
  Iterable<FinTransaction> transactions,
  Iterable<BalanceCheckpoint> checkpoints, {
  DateTime? at,
}) {
  final opened = openingInstant(account.openingDate);
  if (at != null && at.isBefore(opened)) return 0;
  BalanceCheckpoint? best;
  for (final cp in checkpoints) {
    if (cp.accountId != account.id) continue;
    if (at != null && cp.checkedAt.isAfter(at)) continue;
    if (best == null || _compareCheckpoints(cp, best) > 0) best = cp;
  }
  var start = opened;
  var amount = account.openingBalance;
  var strict = false;
  if (best != null && !best.checkedAt.isBefore(opened)) {
    start = best.checkedAt;
    amount = best.actualBalance;
    strict = true;
  }
  var balance = amount;
  for (final tx in transactions) {
    final when = tx.occurredAt;
    final skipped = strict ? !when.isAfter(start) : when.isBefore(start);
    if (skipped || (at != null && when.isAfter(at))) continue;
    balance += effect(tx, account.id);
  }
  return balance;
}

/// Баланс одного счёта в отчёте.
@immutable
class AccountBalance {
  const AccountBalance({
    required this.id,
    required this.balance,
    required this.inTotal,
  });

  final String id;
  final int balance;
  final bool inTotal;
}

/// Балансы счетов (в порядке входа) и общий баланс.
@immutable
class BalanceReport {
  const BalanceReport({required this.accounts, required this.total});

  static const empty = BalanceReport(accounts: [], total: 0);

  final List<AccountBalance> accounts;

  /// Сумма балансов счетов с флагом «в общем балансе» (архив не влияет).
  final int total;

  /// Баланс счёта; `0` для неизвестного.
  int of(String accountId) {
    for (final a in accounts) {
      if (a.id == accountId) return a.balance;
    }
    return 0;
  }
}

/// Баланс на момент [at] по каждому счёту и общий баланс.
BalanceReport accountBalances(
  Iterable<Account> accounts,
  Iterable<FinTransaction> transactions,
  Iterable<BalanceCheckpoint> checkpoints, {
  DateTime? at,
}) {
  final lines = [
    for (final a in accounts)
      AccountBalance(
        id: a.id,
        balance: balanceAt(a, transactions, checkpoints, at: at),
        inTotal: a.includeInTotal,
      ),
  ];
  var total = 0;
  for (final l in lines) {
    if (l.inTotal) total += l.balance;
  }
  return BalanceReport(accounts: lines, total: total);
}

/// Точка динамики: общий баланс на конец московской даты.
@immutable
class DynamicsPoint {
  const DynamicsPoint({required this.date, required this.total});

  final String date;
  final int total;
}

/// Общий баланс на конец каждой московской даты (в порядке входа, 4.5).
List<DynamicsPoint> balanceDynamics(
  Iterable<Account> accounts,
  Iterable<FinTransaction> transactions,
  Iterable<BalanceCheckpoint> checkpoints,
  Iterable<String> dates,
) => [
  for (final day in dates)
    DynamicsPoint(
      date: day,
      total: accountBalances(
        accounts,
        transactions,
        checkpoints,
        at: endOfDay(day),
      ).total,
    ),
];

/// Корректировка: что ожидали «у нас» перед точкой сверки и расхождение.
@immutable
class Adjustment {
  const Adjustment({
    required this.checkpointId,
    required this.checkedAt,
    required this.actual,
    required this.expected,
  });

  final String checkpointId;
  final DateTime checkedAt;
  final int actual;
  final int expected;

  /// Положительная — в банке больше, чем «у нас». Это вычисляемая
  /// величина: строк-операций сверка не создаёт (spec 4.4).
  int get adjustment => actual - expected;
}

/// Корректировки счёта по точкам сверки (по возрастанию `(checked_at, id)`;
/// точки раньше открытия не показываются): ожидаемое считается от
/// открытия и **более ранних** точек.
List<Adjustment> adjustments(
  Account account,
  Iterable<FinTransaction> transactions,
  Iterable<BalanceCheckpoint> checkpoints,
) {
  final opened = openingInstant(account.openingDate);
  final mine = [
    for (final cp in checkpoints)
      if (cp.accountId == account.id) cp,
  ]..sort(_compareCheckpoints);
  final out = <Adjustment>[];
  for (var index = 0; index < mine.length; index++) {
    final cp = mine[index];
    if (cp.checkedAt.isBefore(opened)) continue;
    out.add(
      Adjustment(
        checkpointId: cp.id,
        checkedAt: cp.checkedAt,
        actual: cp.actualBalance,
        expected: balanceAt(
          account,
          transactions,
          mine.sublist(0, index),
          at: cp.checkedAt,
        ),
      ),
    );
  }
  return out;
}

// ------------------------------------------------------------------ аналитика

/// Подтверждённый доход или расход без перевода и без движения по долгу.
bool countsInAnalytics(FinTransaction tx) =>
    tx.isConfirmed &&
    (tx.kind == TxKind.income || tx.kind == TxKind.expense) &&
    tx.debtId == null;

bool _inPeriod(String day, DatePeriod? period) =>
    period == null || period.contains(day);

/// Итоги московского месяца.
@immutable
class MonthTotals {
  const MonthTotals({
    required this.month,
    required this.income,
    required this.expense,
  });

  /// `YYYY-MM`.
  final String month;
  final int income;
  final int expense;

  int get net => income - expense;
}

/// Доход и расход по московским месяцам (по возрастанию; месяцы без
/// операций в аналитике в список не попадают — пропуски заполняет
/// интерфейс).
List<MonthTotals> monthlyTotals(
  Iterable<FinTransaction> transactions, {
  Iterable<String>? accountIds,
  DatePeriod? period,
}) {
  final only = accountIds?.toSet();
  final income = <String, int>{};
  final expense = <String, int>{};
  for (final tx in transactions) {
    if (!countsInAnalytics(tx)) continue;
    if (only != null && !only.contains(tx.accountId)) continue;
    final day = moscowDay(tx.occurredAt);
    if (!_inPeriod(day, period)) continue;
    final month = day.substring(0, 7);
    final into = tx.kind == TxKind.income ? income : expense;
    into[month] = (into[month] ?? 0) + tx.amount;
  }
  final months = {...income.keys, ...expense.keys}.toList()..sort();
  return [
    for (final m in months)
      MonthTotals(month: m, income: income[m] ?? 0, expense: expense[m] ?? 0),
  ];
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

/// Группа разбивки: категория верхнего уровня (или «без категории» —
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

  /// `own` плюс суммы подкатегорий.
  final int total;

  /// Операции прямо на категории группы.
  final int own;
  final int count;
  final List<CategoryChild> children;
}

/// Разбивка по категориям.
@immutable
class CategoryBreakdown {
  const CategoryBreakdown({required this.total, required this.groups});

  final int total;
  final List<CategoryGroup> groups;
}

class _GroupBuilder {
  int total = 0;
  int own = 0;
  int count = 0;
  final Map<String, (int, int)> children = {};
}

/// Суммы вида [kind] (`expense`/`income`) по категориям верхнего уровня с
/// подкатегориями (spec 5.2). [categories] — живые категории: отсутствующая
/// или удалённая категория — группа «без категории». Порядок групп:
/// `total` убыв., «без категории» последней, затем id; детей: `total`
/// убыв., затем id.
CategoryBreakdown categoryBreakdown(
  Iterable<FinTransaction> transactions,
  Iterable<FinCategory> categories,
  TxKind kind, {
  DatePeriod? period,
}) {
  final parentOf = {for (final c in categories) c.id: c.parentId};
  final groups = <String?, _GroupBuilder>{};
  var grand = 0;
  for (final tx in transactions) {
    if (!countsInAnalytics(tx) || tx.kind != kind) continue;
    if (!_inPeriod(moscowDay(tx.occurredAt), period)) continue;
    var cid = tx.categoryId;
    if (cid != null && !parentOf.containsKey(cid)) cid = null;
    final parent = cid == null ? null : parentOf[cid];
    final top = parent != null && parentOf.containsKey(parent) ? parent : cid;
    final group = groups.putIfAbsent(top, _GroupBuilder.new)
      ..total += tx.amount
      ..count += 1;
    grand += tx.amount;
    if (top == cid) {
      group.own += tx.amount;
    } else {
      final row = group.children[cid!] ?? (0, 0);
      group.children[cid] = (row.$1 + tx.amount, row.$2 + 1);
    }
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final byTotal = groups[b]!.total.compareTo(groups[a]!.total);
      if (byTotal != 0) return byTotal;
      if ((a == null) != (b == null)) return a == null ? 1 : -1;
      return compareCodePoints(a ?? '', b ?? '');
    });
  return CategoryBreakdown(
    total: grand,
    groups: [
      for (final key in keys)
        CategoryGroup(
          categoryId: key,
          total: groups[key]!.total,
          own: groups[key]!.own,
          count: groups[key]!.count,
          children: [
            for (final e
                in groups[key]!.children.entries.toList()..sort((a, b) {
                  final byTotal = b.value.$1.compareTo(a.value.$1);
                  return byTotal != 0
                      ? byTotal
                      : compareCodePoints(a.key, b.key);
                }))
              CategoryChild(
                categoryId: e.key,
                total: e.value.$1,
                count: e.value.$2,
              ),
          ],
        ),
    ],
  );
}

/// Мерчант в рейтинге.
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

/// Мерчанты по сумме (ключ группы — [foldMerchant]; показывается
/// написание самой ранней операции по `(occurred_at, id)`); пустые
/// мерчанты пропускаются. Порядок: `total` убыв., `count` убыв., ключ.
List<MerchantTotal> topMerchants(
  Iterable<FinTransaction> transactions, {
  TxKind kind = TxKind.expense,
  DatePeriod? period,
  int limit = 10,
}) {
  final ordered =
      [
        for (final tx in transactions)
          if (countsInAnalytics(tx) && tx.kind == kind) tx,
      ]..sort((a, b) {
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        return byTime != 0 ? byTime : compareCodePoints(a.id, b.id);
      });
  final found = <String, (String, int, int)>{};
  for (final tx in ordered) {
    final name = collapseSpaces(tx.merchant ?? '');
    if (name.isEmpty || !_inPeriod(moscowDay(tx.occurredAt), period)) continue;
    final key = foldMerchant(name);
    final row = found[key];
    found[key] = row == null
        ? (name, tx.amount, 1)
        : (row.$1, row.$2 + tx.amount, row.$3 + 1);
  }
  final ranked = found.entries.toList()
    ..sort((a, b) {
      final byTotal = b.value.$2.compareTo(a.value.$2);
      if (byTotal != 0) return byTotal;
      final byCount = b.value.$3.compareTo(a.value.$3);
      return byCount != 0 ? byCount : compareCodePoints(a.key, b.key);
    });
  return [
    for (final e in ranked.take(limit))
      MerchantTotal(merchant: e.value.$1, total: e.value.$2, count: e.value.$3),
  ];
}

// ------------------------------------------------------------------ долги

/// Состояние долга (spec 6.1).
@immutable
class DebtState {
  const DebtState({
    required this.id,
    required this.direction,
    required this.amount,
    required this.repaid,
    required this.remaining,
    required this.overpaid,
    required this.status,
    required this.overdue,
  });

  final String id;
  final DebtDirection direction;
  final int amount;
  final int repaid;
  final int remaining;
  final int overpaid;
  final DebtStatus status;
  final bool overdue;
}

/// Погашено, остаток, статус (открыт / частично / закрыт) и просрочка:
/// `overdue` — задан [today] и срок строго раньше, статус не «закрыт».
DebtState debtState(
  Debt debt,
  Iterable<DebtRepayment> repayments, {
  String? today,
}) {
  var repaid = 0;
  for (final r in repayments) {
    if (r.debtId == debt.id) repaid += r.amount;
  }
  final status = repaid >= debt.amount
      ? DebtStatus.closed
      : (repaid > 0 ? DebtStatus.partial : DebtStatus.open);
  final due = debt.dueDate;
  return DebtState(
    id: debt.id,
    direction: debt.direction,
    amount: debt.amount,
    repaid: repaid,
    remaining: repaid >= debt.amount ? 0 : debt.amount - repaid,
    overpaid: repaid > debt.amount ? repaid - debt.amount : 0,
    status: status,
    overdue:
        today != null &&
        due != null &&
        status != DebtStatus.closed &&
        due.compareTo(today) < 0,
  );
}

/// Итоги долгов: открытые остатки по направлениям и состояния (порядок
/// входа).
@immutable
class DebtsSummary {
  const DebtsSummary({
    required this.owedToMe,
    required this.iOwe,
    required this.debts,
  });

  static const empty = DebtsSummary(owedToMe: 0, iOwe: 0, debts: []);

  final int owedToMe;
  final int iOwe;
  final List<DebtState> debts;

  DebtState? stateOf(String debtId) {
    for (final d in debts) {
      if (d.id == debtId) return d;
    }
    return null;
  }
}

DebtsSummary debtsSummary(
  Iterable<Debt> debts,
  Iterable<DebtRepayment> repayments, {
  String? today,
}) {
  final states = [
    for (final d in debts) debtState(d, repayments, today: today),
  ];
  var owed = 0;
  var owe = 0;
  for (final s in states) {
    if (s.direction == DebtDirection.owedToMe) {
      owed += s.remaining;
    } else {
      owe += s.remaining;
    }
  }
  return DebtsSummary(owedToMe: owed, iOwe: owe, debts: states);
}

// ------------------------------------------------------------------ цели

/// Подписанное значение слагаемого формулы.
@immutable
class GoalTermValue {
  const GoalTermValue({required this.kind, required this.value});

  final GoalTermKind kind;

  /// Со знаком слагаемого.
  final int value;
}

/// Результат формулы «Есть» (spec 6.2).
@immutable
class GoalProgress {
  const GoalProgress({
    required this.have,
    required this.target,
    required this.terms,
  });

  final int have;
  final int target;
  final List<GoalTermValue> terms;

  /// «Не хватает»: со знаком (отрицательное — цель достигнута с запасом).
  int get missing => target - have;
  bool get reached => missing <= 0;
  int get surplus => missing < 0 ? -missing : 0;

  /// Доля в сотых долях процента, вниз; больше 10 000 при перевыполнении
  /// (полосу обрезает интерфейс).
  int get progressBp => progressBasisPoints(have, target);
}

/// Считает формулу цели: каждое слагаемое неотрицательно, знак делает его
/// прибавкой или вычетом. Слагаемые независимы: один счёт в двух
/// слагаемых учтётся дважды.
GoalProgress goalProgress(
  Goal goal, {
  required Iterable<Account> accounts,
  required Iterable<FinTransaction> transactions,
  required Iterable<BalanceCheckpoint> checkpoints,
  required Iterable<Debt> debts,
  required Iterable<DebtRepayment> repayments,
  required Iterable<WorkProject> projects,
  required Iterable<ChangeRequest> changeRequests,
  required Iterable<Allocation> allocations,
}) {
  final balances = {
    for (final a in accounts) a.id: balanceAt(a, transactions, checkpoints),
  };
  var inTotal = 0;
  for (final a in accounts) {
    if (a.includeInTotal) inTotal += balances[a.id]!;
  }
  final summary = debtsSummary(debts, repayments);
  final owed = receivables(projects, changeRequests, allocations);
  final lines = <GoalTermValue>[];
  for (final term in goal.formula) {
    final int value;
    switch (term.kind) {
      case GoalTermKind.accounts:
        var sum = 0;
        for (final id in term.accountIds.toSet()) {
          sum += balances[id] ?? 0;
        }
        value = sum;
      case GoalTermKind.allAccounts:
        value = inTotal;
      case GoalTermKind.debtsToMe:
        value = summary.owedToMe;
      case GoalTermKind.myDebts:
        value = summary.iOwe;
      case GoalTermKind.receivables:
        final chosen = term.clientIds;
        if (chosen == null) {
          value = owed.total;
        } else {
          var sum = 0;
          for (final c in owed.clients) {
            if (c.clientId != null && chosen.contains(c.clientId)) {
              sum += c.remaining;
            }
          }
          value = sum;
        }
    }
    lines.add(
      GoalTermValue(kind: term.kind, value: term.plus ? value : -value),
    );
  }
  var have = 0;
  for (final l in lines) {
    have += l.value;
  }
  return GoalProgress(have: have, target: goal.targetAmount, terms: lines);
}

// ------------------------------------------------------------------ Работа

/// Сколько платежа Работы уже отражено доходами на счетах.
@immutable
class PaymentCoverage {
  const PaymentCoverage({
    required this.paymentId,
    required this.amount,
    required this.linked,
  });

  final String paymentId;
  final int amount;

  /// Сумма подтверждённых доходов с `work_payment_id` = платёж.
  final int linked;

  /// Со знаком: положительное — «ещё не отражено», отрицательное —
  /// привязано больше суммы платежа.
  int get unlinked => amount - linked;
}

/// Покрытие платежей Работы доходами Финансов (spec 7.1), порядок входа.
List<PaymentCoverage> workPaymentCoverage(
  Iterable<Payment> payments,
  Iterable<FinTransaction> transactions,
) {
  final linked = <String, int>{};
  for (final tx in transactions) {
    final id = tx.workPaymentId;
    if (tx.isConfirmed && tx.kind == TxKind.income && id != null) {
      linked[id] = (linked[id] ?? 0) + tx.amount;
    }
  }
  return [
    for (final p in payments)
      PaymentCoverage(
        paymentId: p.id,
        amount: p.amount,
        linked: linked[p.id] ?? 0,
      ),
  ];
}

// ------------------------------------------------------------------ целостность

/// Предупреждение о том, что сервер не отклоняет построчно (spec 8).
@immutable
class FinanceProblem {
  const FinanceProblem({
    required this.code,
    required this.id,
    required this.excess,
  });

  /// `category_parent_invalid`, `category_kind_mismatch`,
  /// `duplicate_external_id`, `repayment_transaction_mismatch`,
  /// `over_repaid`, `work_payment_over_linked`.
  final String code;
  final String id;
  final int? excess;
}

(DateTime, String) _earlier((DateTime, String) a, (DateTime, String) b) {
  final byTime = a.$1.compareTo(b.$1);
  if (byTime != 0) return byTime < 0 ? a : b;
  return compareCodePoints(a.$2, b.$2) <= 0 ? a : b;
}

/// Нарушения целостности; порядок — по `code`, затем `id`.
List<FinanceProblem> integrityProblems({
  required Iterable<FinCategory> categories,
  required Iterable<FinTransaction> transactions,
  required Iterable<Debt> debts,
  required Iterable<DebtRepayment> repayments,
  required Iterable<Payment> payments,
}) {
  final found = <FinanceProblem>[];
  final byId = {for (final c in categories) c.id: c};
  for (final c in categories) {
    final parent = c.parentId == null ? null : byId[c.parentId];
    if (parent != null &&
        (byId.containsKey(parent.parentId) || parent.kind != c.kind)) {
      found.add(
        FinanceProblem(code: 'category_parent_invalid', id: c.id, excess: null),
      );
    }
  }
  final first = <String, (DateTime, String)>{};
  for (final tx in transactions) {
    final key = dedupKey(tx);
    if (key == null) continue;
    final mine = (tx.occurredAt, tx.id);
    final known = first[key];
    first[key] = known == null ? mine : _earlier(known, mine);
  }
  for (final tx in transactions) {
    final key = dedupKey(tx);
    if (key != null) {
      final head = first[key]!;
      if (head.$1 != tx.occurredAt || head.$2 != tx.id) {
        found.add(
          FinanceProblem(
            code: 'duplicate_external_id',
            id: tx.id,
            excess: null,
          ),
        );
      }
    }
    final category = tx.categoryId == null ? null : byId[tx.categoryId];
    if (category != null && tx.kind.wire != category.kind.wire) {
      found.add(
        FinanceProblem(code: 'category_kind_mismatch', id: tx.id, excess: null),
      );
    }
  }
  final debtOf = {for (final tx in transactions) tx.id: tx.debtId};
  for (final r in repayments) {
    final link = r.transactionId;
    if (link != null && debtOf.containsKey(link) && debtOf[link] != r.debtId) {
      found.add(
        FinanceProblem(
          code: 'repayment_transaction_mismatch',
          id: r.id,
          excess: null,
        ),
      );
    }
  }
  for (final d in debts) {
    final state = debtState(d, repayments);
    if (state.overpaid > 0) {
      found.add(
        FinanceProblem(code: 'over_repaid', id: d.id, excess: state.overpaid),
      );
    }
  }
  for (final line in workPaymentCoverage(payments, transactions)) {
    if (line.unlinked < 0) {
      found.add(
        FinanceProblem(
          code: 'work_payment_over_linked',
          id: line.paymentId,
          excess: -line.unlinked,
        ),
      );
    }
  }
  found.sort((a, b) {
    final byCode = compareCodePoints(a.code, b.code);
    return byCode != 0 ? byCode : compareCodePoints(a.id, b.id);
  });
  return found;
}
