import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/ai_chat/data/ai_sync_specs.dart';
import 'package:my_tasker/features/banks/data/banks_sync_specs.dart';
import 'package:my_tasker/features/calendar/data/calendar_sync_specs.dart';
import 'package:my_tasker/features/finance/data/finance_sync_specs.dart';
import 'package:my_tasker/features/tasks/data/task_sync_specs.dart';
import 'package:my_tasker/features/work/data/work_sync_specs.dart';

/// Настройки «ключ -> значение», общие для устройств (spec 4.1).
///
/// `id` строки = `uuid5(NS, key)`, см. `userSettingsId`.
const SyncTableSpec userSettingsSpec = SyncTableSpec(
  name: 'user_settings',
  label: 'Настройка',
  columns: [
    SyncColumn('key', SyncColumnType.text, immutable: true),
    SyncColumn('value', SyncColumnType.json),
  ],
  titleOf: _settingTitle,
);

/// Понятные названия известных настроек для корзины; неизвестный ключ
/// показывается как есть.
const Map<String, String> settingLabels = {
  'calendar.week_cycle': 'Чередование недель',
  'ui.theme': 'Тема оформления',
};

String _settingTitle(Map<String, Object?> row) {
  final key = '${row['key']}';
  return settingLabels[key] ?? key;
}

/// Все синхронизируемые таблицы приложения. Модуль, которому нужна
/// синхронизация, добавляет сюда своё описание (и таблицу Drift в
/// `AppDatabase`, и шаг миграции).
///
/// Этап 2 (календарь и задачи): порядок — родители вперёд
/// (`backend/src/tasker/calendar/tables.py`, `CALENDAR_TABLES`).
const List<SyncTableSpec> registeredSyncTables = [
  userSettingsSpec,
  calendarsSpec,
  eventsSpec,
  eventOverridesSpec,
  projectsSpec,
  peopleSpec,
  tagsSpec,
  tasksSpec,
  subtasksSpec,
  taskTagsSpec,
  taskCompletionsSpec,
  // Этап 3 (ИИ-чат): `backend/src/tasker/ai/tables.py`, `AI_TABLES`.
  ...aiSyncSpecs,
  // Этап 4 (Работа): `backend/src/tasker/work/tables.py`, `WORK_TABLES`;
  // `projects` и `people` расширены на месте (см. выше).
  ...workSyncSpecs,
  // Этап 5 (Финансы): `backend/src/tasker/finance/tables.py`,
  // `FINANCE_TABLES`.
  ...financeSyncSpecs,
  // Этап 6 (Банки): `backend/src/tasker/banks/tables.py`, `BANKS_TABLES`.
  ...banksSyncSpecs,
];
