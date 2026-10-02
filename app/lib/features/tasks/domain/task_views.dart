import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

/// Запись списка задач: задача и её **актуальный** срок. Для повторяющейся
/// задачи `schedule` это ближайший неотмеченный экземпляр (spec 4.1), для
/// остальных — сам срок задачи.
@immutable
class TaskEntry {
  const TaskEntry({
    required this.task,
    required this.due,
    required this.instanceDate,
    required this.done,
    required this.overdue,
    required this.localDate,
  });

  final TaskEntity task;
  final TaskDue due;

  /// Локальная дата экземпляра для отметки (только у повторяющихся).
  final String? instanceDate;
  final bool done;

  /// Срок раньше «сейчас», задача не закрыта (spec 4.1).
  final bool overdue;

  /// Локальная дата срока в поясе устройства.
  final DateTime? localDate;

  /// Время срока в поясе устройства (для задачи со временем).
  DateTime? localTime(tz.Location zone) =>
      due.at == null ? null : utcToWall(zone, due.at!);
}

/// Записи списка для [tasks] на момент [now] в поясе [zone].
List<TaskEntry> buildTaskEntries(
  List<TaskEntity> tasks,
  List<TaskCompletion> completions, {
  required DateTime now,
  required tz.Location zone,
}) {
  final today = dateOnly(utcToWall(zone, now));
  final byTask = <String, Map<String, TaskCompletion>>{};
  for (final c in completions) {
    byTask.putIfAbsent(c.taskId, () => {})[c.instanceDate] = c;
  }
  final entries = <TaskEntry>[];
  for (final task in tasks) {
    var due = task.due;
    String? instance;
    var done = task.status == TaskStatus.done;
    final series = task.series;
    if (series != null && task.recurrenceMode == RecurrenceMode.schedule) {
      final marks = byTask[task.id] ?? const {};
      final hint = addDays(today, -1);
      final anchor = task.due.hasTime
          ? dateOnly(utcToWall(requireLocation(task.due.tz!), task.due.at!))
          : task.due.date!;
      final zoneOfDue = task.due.hasTime ? requireLocation(task.due.tz!) : null;
      for (final o in series.originals(
        hint: hint.isBefore(anchor) ? null : hint,
      )) {
        final key = zoneOfDue == null
            ? o.key
            : formatDate(dateOnly(utcToWall(zoneOfDue, parseInstant(o.key)!)));
        final date = parseDate(key)!;
        if (date.isBefore(today) || marks.containsKey(key)) continue;
        instance = key;
        due = zoneOfDue == null
            ? TaskDue.date(o.start)
            : TaskDue.at(o.start, task.due.tz!);
        done = false;
        break;
      }
      if (instance == null) {
        // Экземпляров впереди нет: задача закрыта или ждёт закрытия.
        done = task.status == TaskStatus.done;
      }
    }
    final localDate = due.isNone
        ? null
        : due.hasTime
        ? dateOnly(utcToWall(zone, due.at!))
        : due.date;
    final closed = task.status.isClosed;
    final overdue =
        !closed &&
        !done &&
        !due.isNone &&
        (due.hasTime ? due.at!.isBefore(now) : localDate!.isBefore(today));
    entries.add(
      TaskEntry(
        task: task,
        due: due,
        instanceDate: instance,
        done: done,
        overdue: overdue,
        localDate: localDate,
      ),
    );
  }
  return entries;
}

/// Раздел списка задач.
enum TaskGroupKind { overdue, today, tomorrow, week, later, noDate, done }

/// Сгруппированные записи.
@immutable
class TaskGroup {
  const TaskGroup(this.kind, this.entries);

  final TaskGroupKind kind;
  final List<TaskEntry> entries;

  String get title => switch (kind) {
    TaskGroupKind.overdue => 'ПРОСРОЧЕНО',
    TaskGroupKind.today => 'СЕГОДНЯ',
    TaskGroupKind.tomorrow => 'ЗАВТРА',
    TaskGroupKind.week => 'НА НЕДЕЛЕ',
    TaskGroupKind.later => 'ПОЗЖЕ',
    TaskGroupKind.noDate => 'БЕЗ ДАТЫ',
    TaskGroupKind.done => 'ВЫПОЛНЕНО',
  };
}

/// Сравнение внутри раздела: приоритет (P1 первым, без приоритета — в
/// конце), время срока, ручной порядок, название.
int compareEntries(TaskEntry a, TaskEntry b) {
  final pa = a.task.priority ?? 9;
  final pb = b.task.priority ?? 9;
  if (pa != pb) return pa.compareTo(pb);
  final ta = a.due.at?.millisecondsSinceEpoch ?? 1 << 60;
  final tb = b.due.at?.millisecondsSinceEpoch ?? 1 << 60;
  if (ta != tb) return ta.compareTo(tb);
  final oa = a.task.sortOrder ?? 1 << 60;
  final ob = b.task.sortOrder ?? 1 << 60;
  if (oa != ob) return oa.compareTo(ob);
  return a.task.title.compareTo(b.task.title);
}

/// Группирует записи: просрочено, сегодня, завтра, на неделе, позже, без
/// даты, выполнено (внизу). Пустые разделы не возвращаются.
List<TaskGroup> groupTaskEntries(
  List<TaskEntry> entries, {
  required DateTime today,
}) {
  final buckets = {for (final k in TaskGroupKind.values) k: <TaskEntry>[]};
  final weekEnd = addDays(mondayOf(today), 6);
  for (final e in entries) {
    final TaskGroupKind kind;
    if (e.task.status.isClosed || e.done) {
      kind = TaskGroupKind.done;
    } else if (e.localDate == null) {
      kind = TaskGroupKind.noDate;
    } else if (e.overdue) {
      kind = TaskGroupKind.overdue;
    } else {
      final days = daysBetween(today, e.localDate!);
      kind = days <= 0
          ? TaskGroupKind.today
          : days == 1
          ? TaskGroupKind.tomorrow
          : !e.localDate!.isAfter(weekEnd)
          ? TaskGroupKind.week
          : TaskGroupKind.later;
    }
    buckets[kind]!.add(e);
  }
  return [
    for (final k in TaskGroupKind.values)
      if (buckets[k]!.isNotEmpty)
        TaskGroup(k, buckets[k]!..sort(compareEntries)),
  ];
}

/// Фильтр списка задач: статусы, приоритеты, проект, тег, срок.
@immutable
class TaskFilter {
  const TaskFilter({
    this.range = TaskRange.all,
    this.statuses = const {},
    this.priorities = const {},
    this.projectId,
    this.tagId,
    this.showCancelled = false,
    this.showArchived = false,
    this.query = '',
  });

  final TaskRange range;
  final Set<TaskStatus> statuses;

  /// Приоритеты 1…5; `0` — «без приоритета».
  final Set<int> priorities;
  final String? projectId;
  final String? tagId;
  final bool showCancelled;
  final bool showArchived;
  final String query;

  bool get isActive =>
      range != TaskRange.all ||
      statuses.isNotEmpty ||
      priorities.isNotEmpty ||
      projectId != null ||
      tagId != null ||
      showCancelled ||
      showArchived ||
      query.isNotEmpty;

  TaskFilter copyWith({
    TaskRange? range,
    Set<TaskStatus>? statuses,
    Set<int>? priorities,
    Object? projectId = _keep,
    Object? tagId = _keep,
    bool? showCancelled,
    bool? showArchived,
    String? query,
  }) => TaskFilter(
    range: range ?? this.range,
    statuses: statuses ?? this.statuses,
    priorities: priorities ?? this.priorities,
    projectId: identical(projectId, _keep)
        ? this.projectId
        : projectId as String?,
    tagId: identical(tagId, _keep) ? this.tagId : tagId as String?,
    showCancelled: showCancelled ?? this.showCancelled,
    showArchived: showArchived ?? this.showArchived,
    query: query ?? this.query,
  );
}

const Object _keep = Object();

/// Срок, по которому фильтруется список.
enum TaskRange {
  all('Все'),
  today('Сегодня'),
  week('Неделя'),
  noDate('Без даты');

  const TaskRange(this.label);

  final String label;
}

/// Применяет [filter] к записям. [taskTags] — теги по id задачи.
List<TaskEntry> applyTaskFilter(
  List<TaskEntry> entries,
  TaskFilter filter, {
  required DateTime today,
  Map<String, Set<String>> taskTags = const {},
}) {
  final weekEnd = addDays(mondayOf(today), 6);
  final q = filter.query.trim().toLowerCase();
  return [
    for (final e in entries)
      if (_matches(e, filter, today, weekEnd, q, taskTags)) e,
  ];
}

bool _matches(
  TaskEntry e,
  TaskFilter f,
  DateTime today,
  DateTime weekEnd,
  String query,
  Map<String, Set<String>> taskTags,
) {
  final t = e.task;
  if (!f.showArchived && t.archivedAt != null) return false;
  if (t.status == TaskStatus.cancelled &&
      !f.showCancelled &&
      !f.statuses.contains(TaskStatus.cancelled)) {
    return false;
  }
  if (f.statuses.isNotEmpty && !f.statuses.contains(t.status)) return false;
  if (f.priorities.isNotEmpty && !f.priorities.contains(t.priority ?? 0)) {
    return false;
  }
  if (f.projectId != null && t.projectId != f.projectId) return false;
  if (f.tagId != null && !(taskTags[t.id]?.contains(f.tagId) ?? false)) {
    return false;
  }
  if (query.isNotEmpty && !t.title.toLowerCase().contains(query)) return false;
  switch (f.range) {
    case TaskRange.all:
      return true;
    case TaskRange.noDate:
      return e.localDate == null;
    case TaskRange.today:
      return e.localDate != null &&
          (e.overdue || !e.localDate!.isAfter(today)) &&
          !t.status.isClosed;
    case TaskRange.week:
      return e.localDate != null && !e.localDate!.isAfter(weekEnd);
  }
}
