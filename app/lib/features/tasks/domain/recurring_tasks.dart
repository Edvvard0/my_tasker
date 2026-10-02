import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/rule_dates.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Экземпляр повторяющейся задачи (режим `schedule`) или единственное
/// вхождение обычной задачи в окне.
@immutable
class TaskOccurrence {
  const TaskOccurrence({
    required this.task,
    required this.instanceDate,
    required this.start,
    required this.end,
    required this.allDay,
    required this.state,
  });

  final TaskEntity task;

  /// Локальная дата экземпляра `YYYY-MM-DD` (в `due_tz`; для `due_date` —
  /// сама дата): ключ `task_completions.instance_date`.
  final String instanceDate;

  /// Момент UTC (задача с временем) или дата (без времени).
  final DateTime start;
  final DateTime end;
  final bool allDay;

  /// `null` — экземпляр не отмечен; иначе отметка из `task_completions`.
  final TaskCompletion? state;

  bool get isDone => state != null && !state!.skipped;
  bool get isSkipped => state?.skipped ?? false;
}

/// Экземпляры задачи, пересекающие окно `[from, to)` (моменты UTC для
/// задачи с временем, даты для задачи с датой). Обычная задача и задача
/// `after_completion` имеют одно вхождение — текущий срок.
List<TaskOccurrence> taskOccurrences(
  TaskEntity task,
  Map<String, TaskCompletion> completions, {
  required DateTime from,
  required DateTime to,
}) {
  final due = task.due;
  if (due.isNone) return const [];
  final allDay = !due.hasTime;
  final zone = allDay ? null : findLocation(due.tz!);
  String dateKey(DateTime start) => allDay
      ? formatDate(start)
      : formatDate(dateOnly(utcToWall(zone ?? requireLocation('UTC'), start)));

  final series = task.series;
  if (series != null && task.recurrenceMode == RecurrenceMode.schedule) {
    return [
      for (final o in expandSeries(
        series,
        from: from,
        to: to,
        title: task.title,
      ))
        TaskOccurrence(
          task: task,
          instanceDate: dateKey(o.start),
          start: o.start,
          end: o.end,
          allDay: allDay,
          state: completions[dateKey(o.start)],
        ),
    ];
  }
  final start = allDay ? due.date! : due.at!;
  final end = allDay
      ? due.date!
      : due.at!.add(Duration(minutes: task.durationMinutes ?? 0));
  if (!overlapsWindow(start, end, from, to, allDay: allDay)) return const [];
  return [
    TaskOccurrence(
      task: task,
      instanceDate: dateKey(start),
      start: start,
      end: end,
      allDay: allDay,
      state: null,
    ),
  ];
}

/// Следующий срок после выполнения задачи `after_completion` (spec 4.1):
/// первый экземпляр правила, вычисленный так, как если бы началом серии
/// была **локальная дата выполнения** (с прежним временем суток), с
/// локальной датой **строго больше** даты выполнения. `null` — серия
/// закончилась (`COUNT` исчерпан или `UNTIL` пройден).
///
/// [completedOn] — локальная дата выполнения. Возвращает новый срок и
/// правило (у `COUNT` уменьшенное на выполненный экземпляр).
({TaskDue due, String rrule})? nextDueAfterCompletion(
  TaskEntity task,
  DateTime completedOn,
) {
  final ruleText = task.rrule;
  if (ruleText == null || task.due.isNone) return null;
  final allDay = !task.due.hasTime;
  var rule = RRule.parse(ruleText, allDay: allDay);
  if (rule.count != null) {
    final left = rule.count! - 1;
    if (left < 1) return null;
    rule = rule.copyWith(count: () => left);
  }
  final start = dateOnly(completedOn);
  DateTime? found;
  final unlimited = rule.copyWith(count: () => null);
  for (final date in ruleDates(unlimited, start)) {
    if (date.isAfter(start)) {
      found = date;
      break;
    }
  }
  if (found == null) return null;
  if (allDay) {
    if (rule.untilDate != null && found.isAfter(rule.untilDate!)) return null;
    return (due: TaskDue.date(found), rrule: rule.toRuleString());
  }
  final zone = requireLocation(task.due.tz!);
  final wall = utcToWall(zone, task.due.at!);
  final instant = wallToUtc(
    zone,
    found.year,
    found.month,
    found.day,
    wall.hour,
    wall.minute,
    wall.second,
  );
  if (rule.untilUtc != null && instant.isAfter(rule.untilUtc!)) return null;
  return (due: TaskDue.at(instant, task.due.tz!), rrule: rule.toRuleString());
}

/// Серия конечна (`COUNT` или `UNTIL`).
bool isFiniteSeries(TaskEntity task) {
  if (task.rrule == null) return false;
  final rule = RRule.parse(task.rrule!, allDay: !task.due.hasTime);
  return rule.count != null || rule.hasUntil;
}

/// Все экземпляры конечной серии отмечены (выполнены или пропущены):
/// клиент тогда переводит задачу в `done` (spec 4.1).
bool isSeriesFinished(
  TaskEntity task,
  Map<String, TaskCompletion> completions,
) {
  final series = task.series;
  if (series == null || !isFiniteSeries(task)) return false;
  final zone = task.due.hasTime ? requireLocation(task.due.tz!) : null;
  for (final o in series.originals()) {
    final date = zone == null
        ? o.key
        : formatDate(dateOnly(utcToWall(zone, parseInstant(o.key)!)));
    if (!completions.containsKey(date)) return false;
  }
  return true;
}
