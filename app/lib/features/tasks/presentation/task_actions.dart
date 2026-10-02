import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

/// Отмечает задачу выполненной (или возвращает) и показывает снэкбар
/// «Задача выполнена · Отменить» (02, 4.9).
Future<void> toggleTaskDone(
  BuildContext context,
  WidgetRef ref,
  TaskEntry entry,
) async {
  final repo = ref.read(taskRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final today = ref.read(todayProvider);
  final wasDone = entry.done || entry.task.status == TaskStatus.done;
  await repo.toggleDone(
    entry.task,
    instanceDate: entry.instanceDate,
    localToday: today,
  );
  if (wasDone) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('Задача выполнена'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () async {
            final current = await repo.getTask(entry.task.id);
            if (current == null) return;
            await repo.toggleDone(
              current,
              instanceDate: entry.instanceDate,
              localToday: today,
            );
          },
        ),
      ),
    );
}

/// Отмечает задачу из календаря ([TaskItem]) выполненной или возвращает.
Future<void> toggleTaskItem(
  BuildContext context,
  WidgetRef ref,
  TaskItem item,
) {
  final task = item.task;
  final today = ref.read(todayProvider);
  final schedule =
      task.isRecurring && task.recurrenceMode == RecurrenceMode.schedule;
  return toggleTaskDone(
    context,
    ref,
    TaskEntry(
      task: task,
      due: task.due,
      instanceDate: schedule ? item.instanceDate : null,
      done: item.done,
      overdue: false,
      localDate: task.due.localDate ?? today,
    ),
  );
}

/// Куда перенести задачу (свайп влево, меню): «Сегодня вечером · Завтра ·
/// На выходных · Без даты · Выбрать дату» (02, 4.2). `null` — отмена.
Future<TaskDue?> showRescheduleSheet(
  BuildContext context, {
  required DateTime today,
}) {
  return showModalBottomSheet<TaskDue>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      // Ближайшая суббота строго после сегодня (в выходные — следующая).
      final untilSaturday = (5 - weekdayIndex(today)) % 7;
      final saturday = addDays(today, untilSaturday == 0 ? 7 : untilSaturday);
      Widget option(String key, String label, IconData icon, TaskDue? due) =>
          ListTile(
            key: Key(key),
            leading: Icon(icon, size: 20),
            title: Text(label, style: context.text.body),
            onTap: () => Navigator.of(context).pop(due ?? const TaskDue.none()),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Перенести', style: context.text.h3),
              ),
            ),
            option(
              'reschedule-today',
              'Сегодня',
              LucideIcons.sun,
              TaskDue.date(today),
            ),
            option(
              'reschedule-tomorrow',
              'Завтра',
              LucideIcons.sunrise,
              TaskDue.date(addDays(today, 1)),
            ),
            option(
              'reschedule-weekend',
              'На выходных',
              LucideIcons.calendarDays,
              TaskDue.date(saturday),
            ),
            option(
              'reschedule-none',
              'Без даты',
              LucideIcons.inbox,
              const TaskDue.none(),
            ),
            ListTile(
              key: const Key('reschedule-pick'),
              leading: const Icon(LucideIcons.calendar, size: 20),
              title: Text('Выбрать дату', style: context.text.body),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: today,
                  firstDate: DateTime(minYear),
                  lastDate: DateTime(maxYear),
                  locale: const Locale('ru'),
                );
                if (picked != null && context.mounted) {
                  Navigator.of(context).pop(
                    TaskDue.date(civil(picked.year, picked.month, picked.day)),
                  );
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

/// Переносит задачу через [showRescheduleSheet].
Future<void> rescheduleTask(
  BuildContext context,
  WidgetRef ref,
  TaskEntity task,
) async {
  final due = await showRescheduleSheet(
    context,
    today: ref.read(todayProvider),
  );
  if (due == null) return;
  await ref.read(taskRepositoryProvider).reschedule(task.id, due);
}

/// Меню долгого нажатия: редактировать, перенести, приоритет, дублировать,
/// удалить (02, 4.2).
Future<void> showTaskMenu(
  BuildContext context,
  WidgetRef ref,
  TaskEntity task,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      Widget item(String key, String label, IconData icon) => ListTile(
        key: Key('menu-$key'),
        leading: Icon(icon, size: 20),
        title: Text(label, style: context.text.body),
        onTap: () => Navigator.of(context).pop(key),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item('edit', 'Редактировать', LucideIcons.pencil),
            item('reschedule', 'Перенести', LucideIcons.calendarArrowUp),
            item('priority', 'Приоритет', LucideIcons.flag),
            item('duplicate', 'Дублировать', LucideIcons.copy),
            item('delete', 'Удалить', LucideIcons.trash2),
          ],
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  final repo = ref.read(taskRepositoryProvider);
  switch (action) {
    case 'edit':
      await showTaskEditor(context, taskId: task.id);
    case 'reschedule':
      await rescheduleTask(context, ref, task);
    case 'priority':
      await _pickPriority(context, ref, task);
    case 'duplicate':
      await repo.createTask(
        task
            .copyWith(title: task.title, status: TaskStatus.todo)
            .copyWithNew(repo.newTaskId()),
      );
    case 'delete':
      final messenger = ScaffoldMessenger.of(context);
      await repo.deleteTask(task.id);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('Удалено: «${task.title}»'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Отменить',
              onPressed: () => repo.restoreTask(task.id),
            ),
          ),
        );
  }
}

Future<void> _pickPriority(
  BuildContext context,
  WidgetRef ref,
  TaskEntity task,
) async {
  final result = await showModalBottomSheet<int>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in [0, 1, 2, 3, 4, 5])
            ListTile(
              key: Key('priority-pick-$p'),
              title: Text(p == 0 ? 'Без приоритета' : 'P$p'),
              trailing: (task.priority ?? 0) == p
                  ? const Icon(LucideIcons.check, size: 18)
                  : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ],
      ),
    ),
  );
  if (result == null) return;
  await ref
      .read(taskRepositoryProvider)
      .updateTask(task.copyWith(priority: result == 0 ? null : result));
}

extension on TaskEntity {
  /// Копия с новым идентификатором (дублирование).
  TaskEntity copyWithNew(String newId) => TaskEntity(
    id: newId,
    title: title,
    status: status,
    notes: notes,
    priority: priority,
    due: due,
    durationMinutes: durationMinutes,
    rrule: rrule,
    recurrenceMode: recurrenceMode,
    projectId: projectId,
    personId: personId,
    reminders: reminders,
    sortOrder: sortOrder,
  );
}
