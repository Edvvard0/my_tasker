import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/domain/recurring_tasks.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

/// Элемент календаря в поясе устройства: событие или задача. Время —
/// «настенные» поля (`DateTime.utc` как наивное значение): для событий с
/// временем — в поясе устройства, для «весь день» — даты.
@immutable
sealed class CalendarItem {
  const CalendarItem({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
  });

  final String title;

  /// Начало: дата и время (для «весь день» — полночь даты начала).
  final DateTime start;

  /// Конец: для «весь день» — **включительная** дата конца (полночь).
  final DateTime end;
  final bool allDay;

  /// Первая дата, на которую приходится элемент.
  DateTime get firstDay => dateOnly(start);

  /// Последняя дата, на которую приходится элемент (конец ровно в полночь
  /// следующих суток к ним не относится).
  DateTime get lastDay {
    if (allDay) return dateOnly(end);
    final atMidnight =
        end.hour == 0 &&
        end.minute == 0 &&
        end.second == 0 &&
        end.isAfter(start);
    return dateOnly(
      atMidnight ? end.subtract(const Duration(seconds: 1)) : end,
    );
  }

  /// Элемент приходится на [day].
  bool coversDay(DateTime day) {
    final d = dateOnly(day);
    return !d.isBefore(firstDay) && !d.isAfter(lastDay);
  }

  /// Минут от начала суток [day] до начала элемента (с обрезкой по дню).
  int startMinuteOn(DateTime day) {
    if (dateOnly(start).isBefore(dateOnly(day))) return 0;
    return start.hour * 60 + start.minute;
  }

  /// Минут от начала суток [day] до конца элемента (с обрезкой по дню).
  int endMinuteOn(DateTime day) {
    if (dateOnly(end).isAfter(dateOnly(day))) return 24 * 60;
    final m = end.hour * 60 + end.minute;
    return m == 0 && end.isAfter(start) ? 24 * 60 : m;
  }
}

/// Событие (или экземпляр повторяющегося).
@immutable
class EventItem extends CalendarItem {
  const EventItem({
    required super.title,
    required super.start,
    required super.end,
    required super.allDay,
    required this.event,
    required this.key,
    required this.layerKind,
    required this.alternating,
    this.overridden = false,
    this.location,
    this.layerName,
  });

  final EventEntity event;

  /// `original_start` экземпляра (для одиночного события — его начало).
  final String key;

  /// `system_key` слоя (`personal`, `work`, `study`) или `null` (пользовательский).
  final String? layerKind;
  final String? layerName;
  final bool overridden;
  final String? location;

  /// Серия чередования недель: `FREQ=WEEKLY` и `INTERVAL > 1` (иконка `repeat-2`).
  final bool alternating;

  bool get isRecurring => event.isRecurring;
}

/// Задача (или экземпляр повторяющейся) с датой или временем.
@immutable
class TaskItem extends CalendarItem {
  const TaskItem({
    required super.title,
    required super.start,
    required super.end,
    required super.allDay,
    required this.task,
    required this.instanceDate,
    required this.done,
  });

  final TaskEntity task;

  /// Локальная дата экземпляра для отметок повторяющейся задачи.
  final String instanceDate;
  final bool done;

  /// У задачи есть время: блок в сетке, а не полоса «весь день».
  bool get hasTime => !allDay;
}

/// Снимок данных календаря для построения элементов.
@immutable
class CalendarData {
  const CalendarData({
    this.layers = const [],
    this.events = const [],
    this.overrides = const [],
    this.tasks = const [],
    this.completions = const [],
  });

  final List<CalendarLayer> layers;
  final List<EventEntity> events;
  final List<EventOverride> overrides;
  final List<TaskEntity> tasks;
  final List<TaskCompletion> completions;

  /// Слой виден (если слоёв ещё нет — считаем видимым).
  bool layerVisible(String? calendarId) {
    for (final l in layers) {
      if (l.id == calendarId) return l.visible;
    }
    return true;
  }

  bool get tasksVisible => layerVisible(systemCalendarId('tasks'));
  bool get holidaysVisible => layerVisible(systemCalendarId('holidays_ru'));
}

/// Элементы календаря на полуоткрытом отрезке дат `[fromDate, toDate)` в
/// поясе [zone] (по возрастанию начала). События скрытых слоёв не
/// попадают; отменённые экземпляры и закрытые задачи `cancelled` — тоже.
List<CalendarItem> buildCalendarItems(
  CalendarData data, {
  required DateTime fromDate,
  required DateTime toDate,
  required tz.Location zone,
}) {
  final from = dateOnly(fromDate);
  final to = dateOnly(toDate);
  final fromInstant = wallToUtc(zone, from.year, from.month, from.day);
  final toInstant = wallToUtc(zone, to.year, to.month, to.day);
  final layers = {for (final l in data.layers) l.id: l};
  final overridesByEvent = <String, List<EventOverride>>{};
  for (final o in data.overrides) {
    overridesByEvent.putIfAbsent(o.eventId, () => []).add(o);
  }
  final items = <CalendarItem>[];

  for (final event in data.events) {
    if (!data.layerVisible(event.calendarId)) continue;
    final series = event.series;
    if (series == null) continue;
    final overrides = overridesByEvent[event.id] ?? const <EventOverride>[];
    final cancelled = {
      for (final o in overrides)
        if (o.cancelled) o.originalStart,
    };
    final changes = {
      for (final o in overrides)
        if (!o.cancelled)
          o.originalStart: o.toInstanceOverride(allDay: event.allDay),
    };
    final occurrences = expandSeries(
      series,
      from: event.allDay ? from : fromInstant,
      to: event.allDay ? to : toInstant,
      title: event.title,
      cancelled: cancelled,
      overrides: changes,
    );
    final layer = layers[event.calendarId];
    final rule = event.rrule == null
        ? null
        : RRule.parse(event.rrule!, allDay: event.allDay);
    final alternating =
        rule != null && rule.freq == 'WEEKLY' && rule.interval > 1;
    final byKey = {for (final o in overrides) o.originalStart: o};
    for (final o in occurrences) {
      final change = byKey[o.key];
      items.add(
        EventItem(
          title: o.title,
          start: event.allDay ? o.start : utcToWall(zone, o.start),
          end: event.allDay ? o.end : utcToWall(zone, o.end),
          allDay: event.allDay,
          event: event,
          key: o.key,
          layerKind: layer?.systemKey,
          layerName: layer?.name,
          alternating: alternating,
          overridden: o.overridden,
          location: change?.location ?? event.location,
        ),
      );
    }
  }

  if (data.tasksVisible) {
    final completions = <String, Map<String, TaskCompletion>>{};
    for (final c in data.completions) {
      completions.putIfAbsent(c.taskId, () => {})[c.instanceDate] = c;
    }
    for (final task in data.tasks) {
      if (task.status == TaskStatus.cancelled || task.archivedAt != null) {
        continue;
      }
      if (task.due.isNone) continue;
      final allDay = !task.due.hasTime;
      final occurrences = taskOccurrences(
        task,
        completions[task.id] ?? const {},
        from: allDay ? from : fromInstant,
        to: allDay ? to : toInstant,
      );
      for (final o in occurrences) {
        if (o.isSkipped) continue;
        final minutes = task.blockMinutes;
        final start = allDay ? o.start : utcToWall(zone, o.start);
        final end = allDay
            ? o.end
            : utcToWall(zone, o.start).add(Duration(minutes: minutes));
        items.add(
          TaskItem(
            title: task.title,
            start: start,
            end: end,
            allDay: allDay,
            task: task,
            instanceDate: o.instanceDate,
            done: task.isRecurring
                ? (task.recurrenceMode == RecurrenceMode.schedule
                      ? o.isDone
                      : task.status == TaskStatus.done)
                : task.status == TaskStatus.done,
          ),
        );
      }
    }
  }
  items.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.title.compareTo(b.title);
  });
  return items;
}

/// Элементы, приходящиеся на день [day], из [items].
List<CalendarItem> itemsOn(List<CalendarItem> items, DateTime day) => [
  for (final i in items)
    if (i.coversDay(day)) i,
];
