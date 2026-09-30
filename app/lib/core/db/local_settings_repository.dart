import 'package:my_tasker/core/db/app_database.dart';

/// Доступ к таблице `local_settings` (ключ-значение).
class LocalSettingsRepository {
  LocalSettingsRepository(this._db);

  final AppDatabase _db;

  /// Значение по ключу или `null`.
  Future<String?> read(String key) async {
    final row = await (_db.select(
      _db.localSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Записывает (или заменяет) значение.
  Future<void> write(String key, String value) => _db
      .into(_db.localSettings)
      .insertOnConflictUpdate(
        LocalSettingsCompanion.insert(key: key, value: value),
      );

  /// Удаляет ключ (если его нет — ничего не происходит).
  Future<void> delete(String key) =>
      (_db.delete(_db.localSettings)..where((t) => t.key.equals(key))).go();

  /// Все настройки (для отладки и тестов).
  Future<Map<String, String>> readAll() async {
    final rows = await _db.select(_db.localSettings).get();
    return {for (final r in rows) r.key: r.value};
  }

  /// Атомарно записывает несколько ключей: `null` удаляет ключ.
  Future<void> writeAll(Map<String, String?> values) =>
      _db.transaction(() async {
        for (final entry in values.entries) {
          final value = entry.value;
          if (value == null) {
            await delete(entry.key);
          } else {
            await write(entry.key, value);
          }
        }
      });
}
