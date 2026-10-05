import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';

/// Модели «Сна и ритуалов» (spec `stage8_sleep_rituals.md`, раздел 1).
/// Даты — строки `YYYY-MM-DD`; моменты — UTC. Строка на дату: колонка
/// `date` неизменяема, `id` детерминирован (`sleep_ids.dart`).
///
/// Чтение «мягкое»: неизвестное значение перечисления (новая версия сервера)
/// читается как значение по умолчанию, а не ломает экран.

const Object _unset = Object();

/// Откуда запись о сне (`sleep_entries.source`).
enum SleepSource {
  manual('manual'),
  morningNotification('morning_notification');

  const SleepSource(this.wire);

  final String wire;

  static SleepSource parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => manual);
}

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

List<String> _ids(Object? value) => [
  if (value is List)
    for (final v in value)
      if (v is String) v,
];

/// Запись о сне (`sleep_entries`): когда лёг и когда встал, зона
/// пробуждения. Длительность не хранится — она вычисляется ([view]).
@immutable
class SleepEntry {
  const SleepEntry({
    required this.id,
    required this.date,
    required this.bedAt,
    required this.wakeAt,
    required this.wakeTz,
    this.bedTz,
    this.source = SleepSource.manual,
    this.quality,
    this.note,
  });

  factory SleepEntry.fromRow(Json row) => SleepEntry(
    id: (row['id'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    bedAt: _instant(row['bed_at']) ?? DateTime.utc(1970),
    wakeAt: _instant(row['wake_at']) ?? DateTime.utc(1970),
    bedTz: row['bed_tz'] as String?,
    wakeTz: (row['wake_tz'] as String?) ?? 'UTC',
    source: SleepSource.parse(row['source']),
    quality: row['quality'] as int?,
    note: row['note'] as String?,
  );

  final String id;

  /// Дата сна: локальная дата пробуждения в [wakeTz].
  final String date;
  final DateTime bedAt;
  final DateTime wakeAt;

  /// Зона, где лёг; `null` — та же, что [wakeTz].
  final String? bedTz;
  final String wakeTz;
  final SleepSource source;

  /// Самочувствие 1…5.
  final int? quality;
  final String? note;

  /// Строка для расчётов `sleep_calc.dart`.
  Json toRow() => {
    'id': id,
    'date': date,
    'bed_at': formatInstant(bedAt),
    'wake_at': formatInstant(wakeAt),
    'bed_tz': bedTz,
    'wake_tz': wakeTz,
  };

  /// Что показывать (длительность, часы); `null` — запись невалидна.
  EntryView? get view => entryView(toRow());

  /// Изменяемые колонки строки (без `date`).
  Json toFields() => {
    'bed_at': formatInstant(bedAt),
    'wake_at': formatInstant(wakeAt),
    'bed_tz': bedTz,
    'wake_tz': wakeTz,
    'source': source.wire,
    'quality': quality,
    'note': note,
  };

  SleepEntry copyWith({
    Object? quality = _unset,
    Object? note = _unset,
    SleepSource? source,
  }) => SleepEntry(
    id: id,
    date: date,
    bedAt: bedAt,
    wakeAt: wakeAt,
    bedTz: bedTz,
    wakeTz: wakeTz,
    source: source ?? this.source,
    quality: identical(quality, _unset) ? this.quality : quality as int?,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}

/// Утренний план (`daily_plans`): «главные дела дня». Наличие строки —
/// «утренний план сделан».
@immutable
class DailyPlan {
  const DailyPlan({
    required this.id,
    required this.date,
    this.taskIds = const [],
    this.mainTaskId,
    this.note,
  });

  factory DailyPlan.fromRow(Json row) => DailyPlan(
    id: (row['id'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    taskIds: _ids(row['task_ids']),
    mainTaskId: row['main_task_id'] as String?,
    note: row['note'] as String?,
  );

  final String id;
  final String date;

  /// До 10 задач; «главное» не обязано входить в список (слияние двух
  /// устройств), клиент при выборе добавляет его.
  final List<String> taskIds;
  final String? mainTaskId;
  final String? note;

  /// Изменяемые колонки строки (без `date`).
  Json toFields() => {
    'task_ids': taskIds,
    'main_task_id': mainTaskId,
    'note': note,
  };
}

/// Решение чек-ина о переносе задачи (`evening_checkins.carry_over[]`).
@immutable
class CarryDecision {
  const CarryDecision.tomorrow(this.taskId) : date = null;

  const CarryDecision.onDate(this.taskId, String this.date);

  /// Разбор решения из JSON; `null` — битое.
  static CarryDecision? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['task_id'];
    if (id is! String) return null;
    if (value['to'] == 'tomorrow') return CarryDecision.tomorrow(id);
    final date = value['date'];
    if (value['to'] == 'date' && date is String) {
      return CarryDecision.onDate(id, date);
    }
    return null;
  }

  final String taskId;

  /// Только у «на дату».
  final String? date;

  bool get isTomorrow => date == null;

  Json toJson() => isTomorrow
      ? {'task_id': taskId, 'to': 'tomorrow'}
      : {'task_id': taskId, 'to': 'date', 'date': date};

  @override
  bool operator ==(Object other) =>
      other is CarryDecision && other.taskId == taskId && other.date == date;

  @override
  int get hashCode => Object.hash(taskId, date);
}

/// Вечерний чек-ин (`evening_checkins`). Наличие строки — «чек-ин сделан».
/// Решения о переносе — журнал намерения: даты задач меняет клиент
/// (`SleepRepository.applyCarryOver`).
@immutable
class EveningCheckin {
  const EveningCheckin({
    required this.id,
    required this.date,
    this.rating,
    this.doneTaskIds = const [],
    this.carryOver = const [],
    this.note,
  });

  factory EveningCheckin.fromRow(Json row) => EveningCheckin(
    id: (row['id'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    rating: row['rating'] as int?,
    doneTaskIds: _ids(row['done_task_ids']),
    carryOver: [
      if (row['carry_over'] is List)
        for (final d in row['carry_over']! as List<Object?>)
          if (CarryDecision.tryParse(d) case final CarryDecision decision)
            decision,
    ],
    note: row['note'] as String?,
  );

  final String id;
  final String date;

  /// Оценка дня 1…5.
  final int? rating;
  final List<String> doneTaskIds;
  final List<CarryDecision> carryOver;
  final String? note;

  /// Изменяемые колонки строки (без `date`).
  Json toFields() => {
    'rating': rating,
    'done_task_ids': doneTaskIds,
    'carry_over': [for (final d in carryOver) d.toJson()],
    'note': note,
  };
}
