import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:timezone/timezone.dart' as tz;

/// Задачи дня для утреннего плана и вечернего чек-ина.
class DayTasks {
  const DayTasks({
    required this.open,
    required this.done,
    required this.missing,
  });

  /// Не закрытые: срок сегодня или раньше (просроченные первыми) и открытые
  /// задачи плана.
  final List<TaskEntry> open;

  /// Сделанные сегодня: закрыты сегодня, со сроком сегодня или из плана.
  final List<TaskEntry> done;

  /// Задачи плана, которых нет на устройстве (удалены или ещё не доехали).
  final List<String> missing;
}

/// Раскладывает задачи по ритуалам дня [today]. [planIds] — задачи
/// утреннего плана: они остаются в списках, даже если срок у них позже.
DayTasks dayTasks(
  TaskListData data, {
  required DateTime today,
  required tz.Location zone,
  Iterable<String> planIds = const [],
}) {
  final plan = planIds.toSet();
  final byId = {for (final e in data.entries) e.task.id: e};
  final open = <TaskEntry>[];
  final done = <TaskEntry>[];
  for (final e in data.entries) {
    final task = e.task;
    if (task.archivedAt != null || task.status == TaskStatus.cancelled) {
      continue;
    }
    final inPlan = plan.contains(task.id);
    final date = e.localDate;
    if (e.done || task.status == TaskStatus.done) {
      final completed = task.completedAt;
      final closedToday =
          completed != null &&
          dateOnly(utcToWall(zone, completed)).isAtSameMomentAs(today);
      if (inPlan || closedToday || (date != null && date == today)) {
        done.add(e);
      }
    } else if (inPlan || (date != null && !date.isAfter(today))) {
      open.add(e);
    }
  }
  open.sort((a, b) {
    if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
    return compareEntries(a, b);
  });
  done.sort(compareEntries);
  return DayTasks(
    open: open,
    done: done,
    missing: [
      for (final id in planIds)
        if (!byId.containsKey(id)) id,
    ],
  );
}
