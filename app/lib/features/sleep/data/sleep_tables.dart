import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 8 (spec `stage8_sleep_rituals.md`,
/// раздел 1). Даты — текст `YYYY-MM-DD`, моменты — текст UTC, списки задач —
/// сериализованный JSON. По одной строке на дату (детерминированный `id`);
/// внешних ключей нет: ссылки на задачи мягкие.

/// Сон (1.1).
@DataClassName('SleepEntryRow')
@TableIndex(name: 'sleep_entries_date_idx', columns: {#date})
class SleepEntries extends Table with SyncColumns {
  TextColumn get date => text()();
  TextColumn get bedAt => text()();
  TextColumn get wakeAt => text()();
  TextColumn get bedTz => text().nullable()();
  TextColumn get wakeTz => text()();
  TextColumn get source => text()();
  IntColumn get quality => integer().nullable()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'sleep_entries';
}

/// Утренний план (1.2).
@DataClassName('DailyPlanRow')
@TableIndex(name: 'daily_plans_date_idx', columns: {#date})
class DailyPlans extends Table with SyncColumns {
  TextColumn get date => text()();
  TextColumn get taskIds => text()();
  TextColumn get mainTaskId => text().nullable()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'daily_plans';
}

/// Вечерний чек-ин (1.3).
@DataClassName('EveningCheckinRow')
@TableIndex(name: 'evening_checkins_date_idx', columns: {#date})
class EveningCheckins extends Table with SyncColumns {
  TextColumn get date => text()();
  IntColumn get rating => integer().nullable()();
  TextColumn get doneTaskIds => text()();
  TextColumn get carryOver => text()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'evening_checkins';
}

// coverage:ignore-end
