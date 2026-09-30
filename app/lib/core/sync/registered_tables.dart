import 'package:my_tasker/core/sync/sync_table.dart';

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

String _settingTitle(Map<String, Object?> row) => '${row['key']}';

/// Все синхронизируемые таблицы приложения. Модуль, которому нужна
/// синхронизация, добавляет сюда своё описание (и таблицу Drift в
/// `AppDatabase`, и шаг миграции).
const List<SyncTableSpec> registeredSyncTables = [userSettingsSpec];
