import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 8 (spec `stage8_sleep_rituals.md`,
/// раздел 1; сервер: `backend/src/tasker/sleep/tables.py`, `SLEEP_TABLES`).
/// Порядок регистрации: `sleep_entries`, `daily_plans`, `evening_checkins`.
/// Родителей и каскадов нет; ссылки на задачи (`task_ids`, `main_task_id`,
/// `done_task_ids`, `carry_over`) мягкие.
///
/// `id` каждой строки — `uuid5(ns(таблица), date)` (`sleep_ids.dart`), колонка
/// `date` неизменяема.

/// `sleep_entries` — сон (1.1).
const SyncTableSpec sleepEntriesSpec = SyncTableSpec(
  name: 'sleep_entries',
  label: 'Сон',
  columns: [
    SyncColumn('date', SyncColumnType.text, immutable: true),
    SyncColumn('bed_at', SyncColumnType.datetime),
    SyncColumn('wake_at', SyncColumnType.datetime),
    SyncColumn('bed_tz', SyncColumnType.text, nullable: true),
    SyncColumn('wake_tz', SyncColumnType.text),
    SyncColumn('source', SyncColumnType.text),
    SyncColumn('quality', SyncColumnType.integer, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  titleOf: _sleepTitle,
);

/// `daily_plans` — утренний план (1.2).
const SyncTableSpec dailyPlansSpec = SyncTableSpec(
  name: 'daily_plans',
  label: 'Утренний план',
  columns: [
    SyncColumn('date', SyncColumnType.text, immutable: true),
    SyncColumn('task_ids', SyncColumnType.json),
    SyncColumn('main_task_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  titleOf: _planTitle,
);

/// `evening_checkins` — вечерний чек-ин (1.3).
const SyncTableSpec eveningCheckinsSpec = SyncTableSpec(
  name: 'evening_checkins',
  label: 'Вечерний чек-ин',
  columns: [
    SyncColumn('date', SyncColumnType.text, immutable: true),
    SyncColumn('rating', SyncColumnType.integer, nullable: true),
    SyncColumn('done_task_ids', SyncColumnType.json),
    SyncColumn('carry_over', SyncColumnType.json),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  titleOf: _checkinTitle,
);

/// Все таблицы Этапа 8 в порядке регистрации.
const List<SyncTableSpec> sleepSyncSpecs = [
  sleepEntriesSpec,
  dailyPlansSpec,
  eveningCheckinsSpec,
];

String _sleepTitle(Map<String, Object?> row) => 'Сон ${row['date']}';

String _planTitle(Map<String, Object?> row) => 'Утренний план ${row['date']}';

String _checkinTitle(Map<String, Object?> row) =>
    'Вечерний чек-ин ${row['date']}';
