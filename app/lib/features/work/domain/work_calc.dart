/// Расчёты «Работы» (spec Этапа 4, раздел 4). Чистые функции, один в один
/// с эталоном `backend/src/tasker/work/reference.py`; поведение закреплено
/// общими векторами `shared-test-vectors/work/*.json`.
///
/// Деньги — целые копейки и **никогда не округляются**: суммы только
/// складываются и вычитаются. Делений три (доля оплаты, доход в час,
/// стоимость времени по ставке), и все — с округлением вниз.
library;

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Москва = UTC+3 без перехода на летнее время (spec 4.8).
const Duration moscowOffset = Duration(hours: 3);

/// Статусы проекта, по которым возникает долг (spec 4.4).
const Set<ProjectStatus> debtStatuses = {
  ProjectStatus.active,
  ProjectStatus.paused,
  ProjectStatus.completed,
};

/// Доля оплаты в сотых долях процента, вниз; `0` при `total <= 0`.
int paidBasisPoints(int received, int total) =>
    total <= 0 ? 0 : received * 10000 ~/ total;

/// Копеек в час, вниз; `null` без часов.
int? perHour(int amount, int seconds) =>
    seconds <= 0 ? null : amount * 3600 ~/ seconds;

/// Стоимость времени по ставке, вниз до копейки.
int hourlyBillable(int rate, int seconds) => rate * seconds ~/ 3600;

int _wholeSeconds(DateTime t) => t.microsecondsSinceEpoch ~/ 1000000;

/// Секунды завершённой записи (доли секунды отбрасываются у каждого
/// момента до вычитания); `null`, пока таймер идёт.
int? entrySeconds(TimeEntry entry) {
  final end = entry.endedAt;
  if (end == null) return null;
  return _wholeSeconds(end) - _wholeSeconds(entry.startedAt);
}

/// Московская дата момента (`YYYY-MM-DD`).
String moscowDate(DateTime instant) {
  final shifted = DateTime.fromMillisecondsSinceEpoch(
    (_wholeSeconds(instant) * 1000) + moscowOffset.inMilliseconds,
    isUtc: true,
  );
  return formatDate(shifted);
}

/// Московский месяц момента (`YYYY-MM`).
String moscowMonth(DateTime instant) => moscowDate(instant).substring(0, 7);

/// Период отчёта: границы — даты `YYYY-MM-DD` включительно, `null` — без
/// ограничения.
@immutable
class DatePeriod {
  const DatePeriod({this.from, this.to});

  final String? from;
  final String? to;

  /// Входит ли дата [day] в период (`null` — не входит).
  bool contains(String? day) {
    if (day == null) return false;
    return (from == null || day.compareTo(from!) >= 0) &&
        (to == null || day.compareTo(to!) <= 0);
  }
}

bool _inPeriod(String? day, DatePeriod? period) =>
    period == null || period.contains(day);

/// Период календарного месяца `YYYY-MM` (включительно).
DatePeriod monthPeriod(String month) {
  final y = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  final last = daysInMonth(y, m);
  return DatePeriod(
    from: '$month-01',
    to: '$month-${last.toString().padLeft(2, '0')}',
  );
}

/// Итоги доработки.
@immutable
class ChangeRequestSummary {
  const ChangeRequestSummary({
    required this.id,
    required this.amount,
    required this.received,
    required this.remaining,
  });

  final String id;
  final int amount;
  final int received;

  /// Со знаком (минус — переплата); у отменённой всегда `0`.
  final int remaining;
}

/// Итоги проекта (spec 4.2–4.3).
@immutable
class ProjectSummary {
  const ProjectSummary({
    required this.total,
    required this.received,
    required this.remaining,
    required this.overpaid,
    required this.paidBp,
    required this.baseReceived,
    required this.baseRemaining,
    required this.changeRequests,
  });

  final int total;
  final int received;

  /// Со знаком: отрицательный остаток — переплата.
  final int remaining;
  final int overpaid;
  final int paidBp;
  final int baseReceived;
  final int baseRemaining;
  final List<ChangeRequestSummary> changeRequests;
}

/// Сумма проекта: база + доработки, кроме отменённых.
int projectTotal(WorkProject project, Iterable<ChangeRequest> changeRequests) {
  var extra = 0;
  for (final cr in changeRequests) {
    if (cr.projectId == project.id &&
        cr.status != ChangeRequestStatus.cancelled) {
      extra += cr.amount;
    }
  }
  return project.base + extra;
}

/// Получено по проекту: сумма всех его распределений.
int projectReceived(WorkProject project, Iterable<Allocation> allocations) {
  var sum = 0;
  for (final a in allocations) {
    if (a.projectId == project.id) sum += a.amount;
  }
  return sum;
}

/// Итоги одного проекта.
ProjectSummary projectSummary(
  WorkProject project,
  Iterable<ChangeRequest> changeRequests,
  Iterable<Allocation> allocations,
) {
  final mine = [
    for (final cr in changeRequests)
      if (cr.projectId == project.id) cr,
  ];
  final paid = [
    for (final a in allocations)
      if (a.projectId == project.id) a,
  ];
  final total = projectTotal(project, changeRequests);
  var received = 0;
  for (final a in paid) {
    received += a.amount;
  }
  final known = {for (final cr in mine) cr.id};
  var baseReceived = 0;
  for (final a in paid) {
    // Пустая или оборванная ссылка — оплата базовой суммы.
    if (!known.contains(a.changeRequestId)) baseReceived += a.amount;
  }
  final rows = <ChangeRequestSummary>[];
  for (final cr in mine) {
    var got = 0;
    for (final a in paid) {
      if (a.changeRequestId == cr.id) got += a.amount;
    }
    rows.add(
      ChangeRequestSummary(
        id: cr.id,
        amount: cr.amount,
        received: got,
        remaining: cr.status == ChangeRequestStatus.cancelled
            ? 0
            : cr.amount - got,
      ),
    );
  }
  return ProjectSummary(
    total: total,
    received: received,
    remaining: total - received,
    overpaid: received > total ? received - total : 0,
    paidBp: paidBasisPoints(received, total),
    baseReceived: baseReceived,
    baseRemaining: project.base - baseReceived,
    changeRequests: rows,
  );
}

/// Проект в списке долга заказчика.
@immutable
class DebtProject {
  const DebtProject({required this.id, required this.remaining});

  final String id;
  final int remaining;
}

/// Долг одного заказчика (`clientId == null` — «заказчик не указан»).
@immutable
class DebtGroup {
  const DebtGroup({
    required this.clientId,
    required this.remaining,
    required this.projects,
  });

  final String? clientId;
  final int remaining;
  final List<DebtProject> projects;
}

/// «Мне должны»: по заказчикам и общий итог.
@immutable
class Receivables {
  const Receivables({required this.total, required this.clients});

  static const empty = Receivables(total: 0, clients: []);

  final int total;
  final List<DebtGroup> clients;
}

/// Дебиторка по заказчикам (spec 4.4): по проектам «в работе», «пауза» и
/// «завершён» (в том числе архивным) долг = `max(0, сумма − получено)`;
/// переплата одного проекта не гасит долг другого.
Receivables receivables(
  Iterable<WorkProject> projects,
  Iterable<ChangeRequest> changeRequests,
  Iterable<Allocation> allocations,
) {
  final groups = <String?, List<DebtProject>>{};
  for (final project in projects) {
    if (!debtStatuses.contains(project.effectiveStatus)) continue;
    final total = projectTotal(project, changeRequests);
    final debt = total - projectReceived(project, allocations);
    if (debt > 0) {
      groups
          .putIfAbsent(project.clientId, () => [])
          .add(DebtProject(id: project.id, remaining: debt));
    }
  }
  final clients = <DebtGroup>[];
  groups.forEach((clientId, rows) {
    rows.sort(_byRemainingThenId);
    var sum = 0;
    for (final r in rows) {
      sum += r.remaining;
    }
    clients.add(DebtGroup(clientId: clientId, remaining: sum, projects: rows));
  });
  clients.sort((a, b) {
    if (a.remaining != b.remaining) return b.remaining.compareTo(a.remaining);
    // `null` — последним.
    if (a.clientId == null || b.clientId == null) {
      if (a.clientId == b.clientId) return 0;
      return a.clientId == null ? 1 : -1;
    }
    return a.clientId!.compareTo(b.clientId!);
  });
  var total = 0;
  for (final c in clients) {
    total += c.remaining;
  }
  return Receivables(total: total, clients: clients);
}

int _byRemainingThenId(DebtProject a, DebtProject b) {
  if (a.remaining != b.remaining) return b.remaining.compareTo(a.remaining);
  return a.id.compareTo(b.id);
}

/// Часы и доход по проекту за период.
@immutable
class ProjectIncome {
  const ProjectIncome({
    required this.id,
    required this.seconds,
    required this.received,
    required this.accrued,
    required this.perHourFact,
    required this.perHourAccrued,
  });

  final String id;
  final int seconds;
  final int received;
  final int accrued;

  /// Копеек в час по факту; `null` при нуле часов.
  final int? perHourFact;

  /// Копеек в час по начисленному; `null` при нуле часов.
  final int? perHourAccrued;
}

/// Итог часов и дохода (spec 4.5).
@immutable
class IncomeReport {
  const IncomeReport({
    required this.seconds,
    required this.received,
    required this.accrued,
    required this.perHourFact,
    required this.perHourAccrued,
    required this.projects,
  });

  final int seconds;
  final int received;
  final int accrued;
  final int? perHourFact;
  final int? perHourAccrued;

  /// В порядке входных проектов.
  final List<ProjectIncome> projects;
}

/// Доход в час за период: «по факту» (полученное) и «по начисленному»
/// (закрытые доработки + база завершённых проектов). Часы — только
/// оплачиваемые завершённые записи, начатые (по Москве) в периоде.
/// Общий итог = итоги, делённые друг на друга.
IncomeReport income({
  required Iterable<WorkProject> projects,
  required Iterable<ChangeRequest> changeRequests,
  required Iterable<Payment> payments,
  required Iterable<Allocation> allocations,
  required Iterable<TimeEntry> timeEntries,
  DatePeriod? period,
  String? projectId,
}) {
  final paidOn = {for (final p in payments) p.id: moscowDate(p.paidAt)};
  final rows = <ProjectIncome>[];
  for (final project in projects) {
    if (projectId != null && project.id != projectId) continue;
    final pid = project.id;
    var received = 0;
    for (final a in allocations) {
      if (a.projectId == pid && _inPeriod(paidOn[a.paymentId], period)) {
        received += a.amount;
      }
    }
    var accrued = 0;
    for (final cr in changeRequests) {
      if (cr.projectId == pid &&
          cr.status == ChangeRequestStatus.closed &&
          _inPeriod(cr.closedDate, period)) {
        accrued += cr.amount;
      }
    }
    if (project.effectiveStatus == ProjectStatus.completed &&
        _inPeriod(project.completedDate, period)) {
      accrued += project.base;
    }
    var seconds = 0;
    for (final entry in timeEntries) {
      if (entry.projectId != pid || !entry.billable) continue;
      final length = entrySeconds(entry);
      if (length != null && _inPeriod(moscowDate(entry.startedAt), period)) {
        seconds += length;
      }
    }
    rows.add(
      ProjectIncome(
        id: pid,
        seconds: seconds,
        received: received,
        accrued: accrued,
        perHourFact: perHour(received, seconds),
        perHourAccrued: perHour(accrued, seconds),
      ),
    );
  }
  var seconds = 0;
  var received = 0;
  var accrued = 0;
  for (final r in rows) {
    seconds += r.seconds;
    received += r.received;
    accrued += r.accrued;
  }
  return IncomeReport(
    seconds: seconds,
    received: received,
    accrued: accrued,
    perHourFact: perHour(received, seconds),
    perHourAccrued: perHour(accrued, seconds),
    projects: rows,
  );
}

/// Получено за московский месяц платежа (колонки Excel).
@immutable
class MonthlyReceived {
  const MonthlyReceived({
    required this.month,
    required this.received,
    required this.unallocated,
  });

  /// `YYYY-MM`.
  final String month;
  final int received;

  /// Платежи месяца минус все их распределения (может быть < 0 при
  /// нарушении 3.3); `null` при фильтре по проекту.
  final int? unallocated;
}

/// Помесячная разбивка полученного (spec 4.6), месяцы по возрастанию.
List<MonthlyReceived> monthlyReceived(
  Iterable<Payment> payments,
  Iterable<Allocation> allocations, {
  String? projectId,
}) {
  final monthOf = {for (final p in payments) p.id: moscowMonth(p.paidAt)};
  final received = <String, int>{};
  final allocated = <String, int>{};
  for (final a in allocations) {
    final month = monthOf[a.paymentId];
    if (month == null) continue;
    allocated[month] = (allocated[month] ?? 0) + a.amount;
    if (projectId == null || a.projectId == projectId) {
      received[month] = (received[month] ?? 0) + a.amount;
    }
  }
  final gross = <String, int>{};
  for (final p in payments) {
    final month = monthOf[p.id]!;
    gross[month] = (gross[month] ?? 0) + p.amount;
  }
  final months = {...received.keys, ...gross.keys}.toList()..sort();
  final out = <MonthlyReceived>[];
  for (final month in months) {
    final got = received[month] ?? 0;
    final free = (gross[month] ?? 0) - (allocated[month] ?? 0);
    if (projectId != null && got == 0) continue;
    if (projectId == null && got == 0 && free == 0) continue;
    out.add(
      MonthlyReceived(
        month: month,
        received: got,
        unallocated: projectId != null ? null : free,
      ),
    );
  }
  return out;
}

/// Предупреждение о нарушении, которое сервер не отклоняет (spec 3.3).
@immutable
class IntegrityProblem {
  const IntegrityProblem({
    required this.code,
    required this.id,
    required this.excess,
  });

  /// `over_allocated` — распределено больше платежа (`id` — платёж);
  /// `change_request_mismatch` — доработка чужого проекта (`id` —
  /// распределение).
  final String code;
  final String id;
  final int? excess;
}

/// Нарушения целостности (spec 4.9), порядок — по `code`, затем `id`.
List<IntegrityProblem> integrityProblems(
  Iterable<ChangeRequest> changeRequests,
  Iterable<Payment> payments,
  Iterable<Allocation> allocations,
) {
  final found = <IntegrityProblem>[];
  final spent = <String, int>{};
  for (final a in allocations) {
    spent[a.paymentId] = (spent[a.paymentId] ?? 0) + a.amount;
  }
  for (final p in payments) {
    final used = spent[p.id] ?? 0;
    if (used > p.amount) {
      found.add(
        IntegrityProblem(
          code: 'over_allocated',
          id: p.id,
          excess: used - p.amount,
        ),
      );
    }
  }
  final owner = {for (final cr in changeRequests) cr.id: cr.projectId};
  for (final a in allocations) {
    final link = a.changeRequestId;
    if (link != null && owner.containsKey(link) && owner[link] != a.projectId) {
      found.add(
        IntegrityProblem(
          code: 'change_request_mismatch',
          id: a.id,
          excess: null,
        ),
      );
    }
  }
  found.sort((a, b) {
    final c = a.code.compareTo(b.code);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return found;
}
