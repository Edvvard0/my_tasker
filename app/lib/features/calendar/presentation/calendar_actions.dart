import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/data/event_moves.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/recurrence_scope_dialog.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

/// Действия над блоками календаря: перенос и растяжение перетаскиванием,
/// падение задачи из бэклога в сетку. Итог показывается снэкбаром
/// «Перенесено на Чт 14:15 · Отменить» (02, 5.1.6).
class CalendarActions {
  CalendarActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  DateTime _shift(DateTime wall, int days, int minutes) => DateTime.utc(
    wall.year,
    wall.month,
    wall.day + days,
    wall.hour,
    wall.minute + minutes,
  );

  void _toast(String text, {VoidCallback? undo}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 5),
          action: undo == null
              ? null
              : SnackBarAction(label: 'Отменить', onPressed: undo),
        ),
      );
  }

  String _label(DateTime wall) =>
      '${dayTitleShort(dateOnly(wall))} ${timeOf(wall)}';

  /// Блок перетащили: сдвиг на [days] суток и [minutes] минут.
  Future<void> move(CalendarItem item, int days, int minutes) async {
    final zone = ref.read(deviceTimeZoneProvider);
    final newWall = _shift(item.start, days, minutes);
    final newStart = wallToUtc(
      zone,
      newWall.year,
      newWall.month,
      newWall.day,
      newWall.hour,
      newWall.minute,
    );
    final duration =
        wallToUtc(
          zone,
          item.end.year,
          item.end.month,
          item.end.day,
          item.end.hour,
          item.end.minute,
        ).difference(
          wallToUtc(
            zone,
            item.start.year,
            item.start.month,
            item.start.day,
            item.start.hour,
            item.start.minute,
          ),
        );
    try {
      switch (item) {
        case EventItem():
          await _moveEvent(item, newStart, newStart.add(duration), newWall);
        case TaskItem():
          final tasks = ref.read(taskRepositoryProvider);
          final old = item.task;
          await tasks.reschedule(old.id, TaskDue.at(newStart, zone.name));
          _toast(
            'Перенесено на ${_label(newWall)}',
            undo: () => tasks.reschedule(old.id, old.due),
          );
      }
    } on ValidationError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _moveEvent(
    EventItem item,
    DateTime newStart,
    DateTime newEnd,
    DateTime newWall,
  ) async {
    final repo = ref.read(calendarRepositoryProvider);
    final event = item.event;
    var scope = RecurrenceScope.all;
    if (event.isRecurring) {
      final picked = await showRecurrenceScopeDialog(
        context,
        title: 'Перенести повторяющееся событие',
      );
      if (picked == null) return;
      scope = picked;
    }
    await ref
        .read(eventMovesProvider)
        .move(
          event,
          key: item.key,
          newStart: newStart,
          newEnd: newEnd,
          scope: scope,
        );
    final dropped = repo.lastDroppedOverrides;
    _toast(
      dropped > 0
          ? 'Перенесено на ${_label(newWall)}. Исключения серии сброшены: '
                '$dropped'
          : 'Перенесено на ${_label(newWall)}',
      undo: event.isRecurring ? null : () => repo.updateEvent(event),
    );
  }

  /// Растянули нижний край: новая длительность [minutes].
  Future<void> resize(CalendarItem item, int minutes) async {
    final zone = ref.read(deviceTimeZoneProvider);
    final start = wallToUtc(
      zone,
      item.start.year,
      item.start.month,
      item.start.day,
      item.start.hour,
      item.start.minute,
    );
    try {
      switch (item) {
        case EventItem():
          await _moveEvent(
            item,
            start,
            start.add(Duration(minutes: minutes)),
            item.start,
          );
        case TaskItem():
          final tasks = ref.read(taskRepositoryProvider);
          final old = item.task;
          await tasks.updateTask(
            old.copyWith(durationMinutes: minutes.clamp(1, 1440)),
          );
          _toast(
            'Длительность: ${durationText(minutes)}',
            undo: () => tasks.updateTask(old),
          );
      }
    } on ValidationError catch (e) {
      _toast(e.message);
    }
  }

  /// Задачу из бэклога бросили на сетку ([minutes] `null` — в полосу
  /// «весь день»: только дата).
  Future<void> dropTask(TaskEntity task, DateTime day, int? minutes) async {
    final zone = ref.read(deviceTimeZoneProvider);
    final tasks = ref.read(taskRepositoryProvider);
    final due = minutes == null
        ? TaskDue.date(day)
        : TaskDue.at(
            wallToUtc(
              zone,
              day.year,
              day.month,
              day.day,
              minutes ~/ 60,
              minutes % 60,
            ),
            zone.name,
          );
    try {
      if (minutes != null && task.durationMinutes == null) {
        await tasks.updateTask(
          task.copyWith(
            due: due,
            durationMinutes: 60,
            status: task.status == TaskStatus.inbox
                ? TaskStatus.todo
                : task.status,
          ),
        );
      } else {
        await tasks.reschedule(task.id, due);
      }
      _toast(
        minutes == null
            ? 'Назначено на ${dayTitleShort(day)}'
            : 'Назначено на ${dayTitleShort(day)} ${clockText(minutes ~/ 60, minutes % 60)}',
        undo: () => tasks.reschedule(task.id, const TaskDue.none()),
      );
    } on ValidationError catch (e) {
      _toast(e.message);
    }
  }
}
