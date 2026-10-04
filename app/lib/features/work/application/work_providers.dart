import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

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

final StreamProvider<List<WorkProject>> workProjectsProvider =
    _rows<WorkProject>(
      'projects',
      WorkProject.fromRow,
      orderBy: 't.title, t.id',
    );

final StreamProvider<List<WorkPerson>> workPeopleProvider = _rows<WorkPerson>(
  'people',
  WorkPerson.fromRow,
  orderBy: 't.name, t.id',
);

final StreamProvider<List<ChangeRequest>> changeRequestsProvider =
    _rows<ChangeRequest>(
      'change_requests',
      ChangeRequest.fromRow,
      orderBy: 't.created_at, t.id',
    );

final StreamProvider<List<Payment>> paymentsProvider = _rows<Payment>(
  'payments',
  Payment.fromRow,
  orderBy: 't.paid_at DESC, t.id',
);

final StreamProvider<List<Allocation>> allocationsProvider = _rows<Allocation>(
  'payment_allocations',
  Allocation.fromRow,
  orderBy: 't.created_at, t.id',
);

final StreamProvider<List<TimeEntry>> timeEntriesProvider = _rows<TimeEntry>(
  'time_entries',
  TimeEntry.fromRow,
  orderBy: 't.started_at DESC, t.id',
);

/// Весь снимок «Работы» с готовыми расчётами. Расчёты — чистые функции
/// `work_calc.dart` (общие векторы с сервером); здесь только кэш.
@immutable
class WorkData {
  WorkData({
    required this.projects,
    required this.people,
    required this.changeRequests,
    required this.payments,
    required this.allocations,
    required this.entries,
    required this.now,
  });

  final List<WorkProject> projects;
  final List<WorkPerson> people;
  final List<ChangeRequest> changeRequests;
  final List<Payment> payments;
  final List<Allocation> allocations;
  final List<TimeEntry> entries;

  /// «Сейчас» (UTC).
  final DateTime now;

  late final Map<String, WorkProject> projectById = {
    for (final p in projects) p.id: p,
  };
  late final Map<String, WorkPerson> personById = {
    for (final p in people) p.id: p,
  };
  late final Map<String, ChangeRequest> changeRequestById = {
    for (final c in changeRequests) c.id: c,
  };

  final Map<String, ProjectSummary> _summaries = {};

  /// Итоги проекта (кэшируются).
  ProjectSummary summaryOf(String projectId) => _summaries[projectId] ??=
      projectSummary(projectById[projectId]!, changeRequests, allocations);

  /// Заказчик проекта; `null` — не указан или удалён.
  WorkPerson? clientOf(WorkProject project) =>
      project.clientId == null ? null : personById[project.clientId];

  late final Receivables receivablesAll = receivables(
    projects,
    changeRequests,
    allocations,
  );

  late final List<IntegrityProblem> integrity = integrityProblems(
    changeRequests,
    payments,
    allocations,
  );

  /// Доработки проекта: в работе, закрытые, отменённые.
  List<ChangeRequest> changeRequestsOf(String projectId) {
    final mine = [
      for (final c in changeRequests)
        if (c.projectId == projectId) c,
    ];
    int rank(ChangeRequest c) => switch (c.status) {
      ChangeRequestStatus.inProgress => 0,
      ChangeRequestStatus.closed => 1,
      ChangeRequestStatus.cancelled => 2,
    };
    return mine..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  List<Allocation> allocationsOfProject(String projectId) => [
    for (final a in allocations)
      if (a.projectId == projectId) a,
  ];

  List<Allocation> allocationsOfPayment(String paymentId) => [
    for (final a in allocations)
      if (a.paymentId == paymentId) a,
  ];

  /// Записи времени проекта, свежие первыми.
  List<TimeEntry> entriesOf(String projectId) => [
    for (final e in entries)
      if (e.projectId == projectId) e,
  ];

  /// Не распределённая часть платежа (со знаком).
  int unallocatedOf(Payment payment) {
    var used = 0;
    for (final a in allocationsOfPayment(payment.id)) {
      used += a.amount;
    }
    return payment.amount - used;
  }

  /// Часы и доход за период (все проекты или один).
  IncomeReport incomeFor({DatePeriod? period, String? projectId}) => income(
    projects: projects,
    changeRequests: changeRequests,
    payments: payments,
    allocations: allocations,
    timeEntries: entries,
    period: period,
    projectId: projectId,
  );

  /// Помесячное полученное.
  List<MonthlyReceived> monthly({String? projectId}) =>
      monthlyReceived(payments, allocations, projectId: projectId);

  /// Период текущего московского месяца.
  DatePeriod get thisMonth => monthPeriod(moscowMonth(now));

  /// Проект с долгом.
  bool hasDebt(String projectId) {
    final project = projectById[projectId];
    if (project == null || !debtStatuses.contains(project.effectiveStatus)) {
      return false;
    }
    return summaryOf(projectId).remaining > 0;
  }
}

/// «Повторить» после ошибки чтения: пересоздаёт все потоки раздела, а не
/// только проекты и платежи — ошибка могла быть в любом из них.
void retryWorkData(WidgetRef ref) {
  ref
    ..invalidate(workProjectsProvider)
    ..invalidate(workPeopleProvider)
    ..invalidate(changeRequestsProvider)
    ..invalidate(paymentsProvider)
    ..invalidate(allocationsProvider)
    ..invalidate(timeEntriesProvider);
}

/// Снимок «Работы»: ошибка любого потока — ошибка экрана, пока хотя бы
/// один загружается — загрузка.
final Provider<AsyncValue<WorkData>> workDataProvider =
    Provider<AsyncValue<WorkData>>((ref) {
      final projects = ref.watch(workProjectsProvider);
      final people = ref.watch(workPeopleProvider);
      final crs = ref.watch(changeRequestsProvider);
      final payments = ref.watch(paymentsProvider);
      final allocations = ref.watch(allocationsProvider);
      final entries = ref.watch(timeEntriesProvider);
      // «Сейчас» нужно только ради московской даты (неделя, месяц, «вчера»):
      // пересчитываем снимок при смене даты, а не каждые 30 секунд.
      ref.watch(nowProvider.select(moscowDate));
      final now = ref.read(nowProvider);
      final all = <AsyncValue<Object?>>[
        projects,
        people,
        crs,
        payments,
        allocations,
        entries,
      ];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        WorkData(
          projects: projects.requireValue,
          people: people.requireValue,
          changeRequests: crs.requireValue,
          payments: payments.requireValue,
          allocations: allocations.requireValue,
          entries: entries.requireValue,
          now: now,
        ),
      );
    });

/// Фильтр списка проектов (02, 6.6): «В работе · Все · С долгом · Архив».
enum ProjectFilter {
  active('В работе'),
  all('Все'),
  debt('С долгом'),
  archive('Архив');

  const ProjectFilter(this.label);

  final String label;
}

class ProjectFilterNotifier extends Notifier<ProjectFilter> {
  @override
  ProjectFilter build() => ProjectFilter.active;

  // Метод Notifier, а не сеттер: вызывается из обработчиков нажатий.
  // ignore: use_setters_to_change_properties
  void select(ProjectFilter filter) => state = filter;
}

final NotifierProvider<ProjectFilterNotifier, ProjectFilter>
projectFilterProvider = NotifierProvider<ProjectFilterNotifier, ProjectFilter>(
  ProjectFilterNotifier.new,
);

/// Проекты под выбранный фильтр (в архиве — только архивные, в остальных
/// списках архивные не показываются).
List<WorkProject> filterProjects(WorkData data, ProjectFilter filter) {
  bool open(WorkProject p) => !p.archived;
  final list = switch (filter) {
    ProjectFilter.active => [
      for (final p in data.projects)
        if (open(p) &&
            (p.effectiveStatus == ProjectStatus.active ||
                p.effectiveStatus == ProjectStatus.paused ||
                p.effectiveStatus == ProjectStatus.lead))
          p,
    ],
    ProjectFilter.all => [
      for (final p in data.projects)
        if (open(p)) p,
    ],
    ProjectFilter.debt => [
      for (final p in data.projects)
        if (open(p) && data.hasDebt(p.id)) p,
    ],
    ProjectFilter.archive => [
      for (final p in data.projects)
        if (p.archived) p,
    ],
  };
  // Сначала ближайший срок, проекты без срока — после; затем по названию.
  return list..sort((a, b) {
    final da = a.deadlineDate;
    final db = b.deadlineDate;
    if (da != db) {
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }
    return a.title.compareTo(b.title);
  });
}
