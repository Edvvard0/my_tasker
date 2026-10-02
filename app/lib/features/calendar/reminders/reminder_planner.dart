import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/tasks/domain/recurring_tasks.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

/// Горизонт планирования: 14 дней вперёд (spec 2.4).
const Duration reminderHorizon = Duration(days: 14);

/// Сколько уведомлений держим запланированными одновременно.
const int reminderLimit = 60;

/// Данные для планирования напоминаний.
class ReminderInput {
  const ReminderInput({
    required this.now,
    required this.zone,
    required this.allDayMinutes,
    this.events = const [],
    this.overrides = const [],
    this.tasks = const [],
    this.completions = const [],
  });

  /// Текущий момент (UTC).
  final DateTime now;

  /// Часовой пояс устройства: от него зависит, когда наступает «9:00» для
  /// событий на весь день.
  final tz.Location zone;

  /// Локальное время напоминаний «весь день»: минуты от полуночи
  /// (`calendar.all_day_reminder_time`, по умолчанию 09:00 = 540).
  final int allDayMinutes;
  final List<EventEntity> events;
  final List<EventOverride> overrides;
  final List<TaskEntity> tasks;
  final List<TaskCompletion> completions;
}

/// Ближайшие напоминания (не больше [limit]) на [horizon] вперёд по
/// возрастанию времени.
///
/// Правила (spec 2.4): для события/задачи с временем опорный момент —
/// начало; для «весь день» и срока без времени — локальное время
/// [ReminderInput.allDayMinutes] на дату начала. Список минут берётся из
/// переопределения экземпляра, если он не `null`, иначе из события. Не
/// напоминают о выполненных, отменённых, удалённых (их нет во входе) и
/// отменённых экземплярах.
List<PlannedReminder> planReminders(
  ReminderInput input, {
  Duration horizon = reminderHorizon,
  int limit = reminderLimit,
}) {
  final now = input.now.toUtc();
  final end = now.add(horizon);
  final result = <PlannedReminder>[];

  void add({
    required String kind,
    required String itemId,
    required String instance,
    required String title,
    required DateTime reference,
    required bool allDay,
    required List<int> minutes,
    required String payload,
  }) {
    for (final m in minutes) {
      final fireAt = reference.subtract(Duration(minutes: m));
      if (fireAt.isBefore(now) || fireAt.isAfter(end)) continue;
      final body = _body(
        m,
        allDay: allDay,
        time: allDay ? null : utcToWall(input.zone, reference),
      );
      final key =
          '$kind|$itemId|$instance|$m|${fireAt.millisecondsSinceEpoch}'
          '|$title|$body';
      result.add(
        PlannedReminder(
          id: reminderId(key),
          fireAt: fireAt,
          title: title,
          body: body,
          payload: payload,
        ),
      );
    }
  }

  DateTime allDayReference(DateTime date) => wallToUtc(
    input.zone,
    date.year,
    date.month,
    date.day,
    input.allDayMinutes ~/ 60,
    input.allDayMinutes % 60,
  );

  // События.
  final overridesByEvent = <String, List<EventOverride>>{};
  for (final o in input.overrides) {
    overridesByEvent.putIfAbsent(o.eventId, () => []).add(o);
  }
  for (final event in input.events) {
    final series = event.series;
    if (series == null) continue;
    final overrides = overridesByEvent[event.id] ?? const <EventOverride>[];
    final byKey = {for (final o in overrides) o.originalStart: o};
    final baseMinutes = event.reminders ?? const <int>[];
    final hasAny =
        baseMinutes.isNotEmpty ||
        overrides.any((o) => o.reminders?.isNotEmpty ?? false);
    if (!hasAny) continue;
    final maxMinutes = [
      ...baseMinutes,
      for (final o in overrides) ...?o.reminders,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    final windowEnd = end.add(Duration(minutes: maxMinutes + 1));
    final DateTime from;
    final DateTime to;
    if (event.allDay) {
      from = addDays(dateOnly(utcToWall(input.zone, now)), -1);
      to = dateOnly(utcToWall(input.zone, windowEnd))
          .add(const Duration(days: 2));
    } else {
      from = now.subtract(series.end.difference(series.start));
      to = windowEnd;
    }
    final occurrences = expandSeries(
      series,
      from: from,
      to: to,
      title: event.title,
      cancelled: {
        for (final o in overrides)
          if (o.cancelled) o.originalStart,
      },
      overrides: {
        for (final o in overrides)
          if (!o.cancelled)
            o.originalStart: o.toInstanceOverride(allDay: event.allDay),
      },
    );
    for (final o in occurrences) {
      final minutes = byKey[o.key]?.reminders ?? baseMinutes;
      if (minutes.isEmpty) continue;
      add(
        kind: 'event',
        itemId: event.id,
        instance: o.key,
        title: o.title,
        reference: event.allDay ? allDayReference(o.start) : o.start,
        allDay: event.allDay,
        minutes: minutes,
        payload: 'event:${event.id}|${o.key}',
      );
    }
  }

  // Задачи.
  final completions = <String, Map<String, TaskCompletion>>{};
  for (final c in input.completions) {
    completions.putIfAbsent(c.taskId, () => {})[c.instanceDate] = c;
  }
  for (final task in input.tasks) {
    final minutes = task.reminders;
    if (minutes == null || minutes.isEmpty || task.due.isNone) continue;
    if (task.status.isClosed || task.archivedAt != null) continue;
    final allDay = !task.due.hasTime;
    final maxMinutes = minutes.fold<int>(0, (a, b) => a > b ? a : b);
    final windowEnd = end.add(Duration(minutes: maxMinutes + 1));
    final DateTime from;
    final DateTime to;
    if (allDay) {
      from = addDays(dateOnly(utcToWall(input.zone, now)), -1);
      to = dateOnly(utcToWall(input.zone, windowEnd))
          .add(const Duration(days: 2));
    } else {
      from = now.subtract(Duration(minutes: task.durationMinutes ?? 0));
      to = windowEnd;
    }
    for (final o in taskOccurrences(
      task,
      completions[task.id] ?? const {},
      from: from,
      to: to,
    )) {
      if (o.state != null) continue; // выполнен или пропущен экземпляр
      add(
        kind: 'task',
        itemId: task.id,
        instance: o.instanceDate,
        title: task.title,
        reference: allDay ? allDayReference(o.start) : o.start,
        allDay: allDay,
        minutes: minutes,
        payload: 'task:${task.id}',
      );
    }
  }

  result.sort((a, b) {
    final c = a.fireAt.compareTo(b.fireAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return result.length > limit ? result.sublist(0, limit) : result;
}

String _body(int minutes, {required bool allDay, DateTime? time}) {
  final when = minutes == 0
      ? 'Сейчас'
      : minutes % 1440 == 0
      ? 'Через ${minutes ~/ 1440} ${_plural(minutes ~/ 1440, 'день', 'дня', 'дней')}'
      : minutes % 60 == 0
      ? 'Через ${minutes ~/ 60} ч'
      : 'Через $minutes мин';
  if (allDay) return minutes == 0 ? 'Сегодня, весь день' : '$when · весь день';
  final t =
      '${time!.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  return minutes == 0 ? 'Сейчас · $t' : '$when · $t';
}

String _plural(int n, String one, String few, String many) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}
