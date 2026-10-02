import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

const Object _unset = Object();

/// Момент из колонки `datetime` (любая ISO 8601 с зоной) в UTC.
DateTime? parseStoredInstant(Object? value) =>
    value is String ? DateTime.parse(value).toUtc() : null;

/// Момент для записи в колонку: `YYYY-MM-DDTHH:MM:SSZ`.
String? storedInstant(DateTime? instant) =>
    instant == null ? null : formatInstant(instant);

/// Дата из колонки `*_date`.
DateTime? parseStoredDate(Object? value) =>
    value is String ? parseDate(value) : null;

String? storedDate(DateTime? date) => date == null ? null : formatDate(date);

List<int>? parseReminders(Object? value) {
  if (value is! List) return null;
  return [for (final v in value) v! as int];
}

/// Вид календаря (spec 3.1).
enum CalendarKind { user, system }

/// Слой календаря (`calendars`).
@immutable
class CalendarLayer {
  const CalendarLayer({
    required this.id,
    required this.name,
    required this.kind,
    required this.visible,
    required this.position,
    this.color,
    this.systemKey,
  });

  factory CalendarLayer.fromRow(Json row) => CalendarLayer(
    id: row['id']! as String,
    name: row['name']! as String,
    color: row['color'] as String?,
    kind: row['kind'] == 'system' ? CalendarKind.system : CalendarKind.user,
    systemKey: row['system_key'] as String?,
    visible: row['visible']! as bool,
    position: row['position']! as int,
  );

  final String id;
  final String name;
  final String? color;
  final CalendarKind kind;
  final String? systemKey;
  final bool visible;
  final int position;

  bool get isSystem => kind == CalendarKind.system;

  /// Системные слои без строк событий: задачи и праздники (spec 3.1).
  bool get isVirtual => systemKey == 'tasks' || systemKey == 'holidays_ru';
}

/// Источник события (spec 3.2).
enum EventSource { manual, template, study, ai, import }

/// Событие (`events`).
@immutable
class EventEntity {
  const EventEntity({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.allDay,
    this.description,
    this.location,
    this.startAt,
    this.endAt,
    this.tz,
    this.startDate,
    this.endDate,
    this.rrule,
    this.reminders,
    this.source = EventSource.manual,
  });

  factory EventEntity.fromRow(Json row) => EventEntity(
    id: row['id']! as String,
    calendarId: row['calendar_id']! as String,
    title: row['title']! as String,
    description: row['description'] as String?,
    location: row['location'] as String?,
    allDay: row['all_day']! as bool,
    startAt: parseStoredInstant(row['start_at']),
    endAt: parseStoredInstant(row['end_at']),
    tz: row['tz'] as String?,
    startDate: parseStoredDate(row['start_date']),
    endDate: parseStoredDate(row['end_date']),
    rrule: row['rrule'] as String?,
    reminders: parseReminders(row['reminders']),
    source: EventSource.values.firstWhere(
      (s) => s.name == row['source'],
      orElse: () => EventSource.manual,
    ),
  );

  final String id;
  final String calendarId;
  final String title;
  final String? description;
  final String? location;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? tz;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? rrule;
  final List<int>? reminders;
  final EventSource source;

  bool get isRecurring => rrule != null;

  /// Прикладные колонки строки `events`.
  Json toFields() => {
    'calendar_id': calendarId,
    'title': title,
    'description': description,
    'location': location,
    'all_day': allDay,
    'start_at': storedInstant(startAt),
    'end_at': storedInstant(endAt),
    'tz': tz,
    'start_date': storedDate(startDate),
    'end_date': storedDate(endDate),
    'rrule': rrule,
    'reminders': reminders,
    'source': source.name,
  };

  /// Колонки группы времени: уходят в одной операции целиком (spec 0).
  Json timeFields() => {for (final k in eventTimeColumns) k: toFields()[k]};

  /// Описание серии для развёртки; `null`, если данные времени неполны.
  SeriesDefinition? get series {
    final rule = rrule == null ? null : RRule.parse(rrule!, allDay: allDay);
    if (allDay) {
      if (startDate == null || endDate == null) return null;
      return SeriesDefinition.allDay(
        startDate: startDate!,
        endDate: endDate!,
        rule: rule,
      );
    }
    final zone = tz == null ? null : findLocation(tz!);
    if (startAt == null || endAt == null || zone == null) return null;
    return SeriesDefinition.timed(
      location: zone,
      startUtc: startAt!,
      endUtc: endAt!,
      rule: rule,
    );
  }

  EventEntity copyWith({
    String? calendarId,
    String? title,
    Object? description = _unset,
    Object? location = _unset,
    bool? allDay,
    Object? startAt = _unset,
    Object? endAt = _unset,
    Object? tz = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    Object? rrule = _unset,
    Object? reminders = _unset,
    EventSource? source,
  }) => EventEntity(
    id: id,
    calendarId: calendarId ?? this.calendarId,
    title: title ?? this.title,
    description: identical(description, _unset)
        ? this.description
        : description as String?,
    location: identical(location, _unset) ? this.location : location as String?,
    allDay: allDay ?? this.allDay,
    startAt: identical(startAt, _unset) ? this.startAt : startAt as DateTime?,
    endAt: identical(endAt, _unset) ? this.endAt : endAt as DateTime?,
    tz: identical(tz, _unset) ? this.tz : tz as String?,
    startDate: identical(startDate, _unset)
        ? this.startDate
        : startDate as DateTime?,
    endDate: identical(endDate, _unset) ? this.endDate : endDate as DateTime?,
    rrule: identical(rrule, _unset) ? this.rrule : rrule as String?,
    reminders: identical(reminders, _unset)
        ? this.reminders
        : reminders as List<int>?,
    source: source ?? this.source,
  );
}

/// Колонки группы времени события (spec 0).
const List<String> eventTimeColumns = [
  'all_day',
  'start_at',
  'end_at',
  'tz',
  'start_date',
  'end_date',
];

/// Переопределение экземпляра (`event_overrides`).
@immutable
class EventOverride {
  const EventOverride({
    required this.id,
    required this.eventId,
    required this.originalStart,
    required this.cancelled,
    this.title,
    this.description,
    this.location,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDate,
    this.reminders,
  });

  factory EventOverride.fromRow(Json row) => EventOverride(
    id: row['id']! as String,
    eventId: row['event_id']! as String,
    originalStart: row['original_start']! as String,
    cancelled: row['cancelled']! as bool,
    title: row['title'] as String?,
    description: row['description'] as String?,
    location: row['location'] as String?,
    startAt: parseStoredInstant(row['start_at']),
    endAt: parseStoredInstant(row['end_at']),
    startDate: parseStoredDate(row['start_date']),
    endDate: parseStoredDate(row['end_date']),
    reminders: parseReminders(row['reminders']),
  );

  final String id;
  final String eventId;
  final String originalStart;
  final bool cancelled;
  final String? title;
  final String? description;
  final String? location;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<int>? reminders;

  /// Для развёртки: время экземпляра (момент или дата).
  InstanceOverride toInstanceOverride({required bool allDay}) =>
      InstanceOverride(
        title: title,
        start: allDay ? startDate : startAt,
        end: allDay ? endDate : endAt,
      );

  /// Прикладные колонки (кроме неизменяемых `event_id`, `original_start`).
  Json toFields() => {
    'cancelled': cancelled,
    'title': title,
    'description': description,
    'location': location,
    'start_at': storedInstant(startAt),
    'end_at': storedInstant(endAt),
    'start_date': storedDate(startDate),
    'end_date': storedDate(endDate),
    'reminders': reminders,
  };
}
