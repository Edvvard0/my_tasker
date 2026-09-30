import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';

/// Настройки «ключ -> значение», общие для устройств (spec 4.1): первая
/// синхронизируемая таблица `user_settings`.
///
/// `id` строки = `uuid5(NS, key)`: два устройства, создавшие один ключ
/// офлайн, порождают одну строку, а не дубли. Запись идёт через
/// [SyncStore] — в одной транзакции со строкой и операцией outbox.
class UserSettingsRepository {
  UserSettingsRepository(this._store);

  static const table = 'user_settings';

  /// Предел размера сериализованного значения (spec 4.1).
  static const int maxValueBytes = 16 * 1024;

  static final RegExp _keyPattern = RegExp(r'^[a-z0-9][a-z0-9_.-]*$');

  final SyncStore _store;

  /// Ключ допустим: 1–100 символов, `^[a-z0-9][a-z0-9_.-]*$`.
  static bool isValidKey(String key) =>
      key.isNotEmpty && key.length <= 100 && _keyPattern.hasMatch(key);

  static void _checkKey(String key) {
    if (!isValidKey(key)) {
      throw ArgumentError.value(key, 'key', 'недопустимый ключ настройки');
    }
  }

  /// Значение или `null`, если ключа нет или он удалён.
  Future<Object?> read(String key) async {
    _checkKey(key);
    final row = await _store.getRow(table, userSettingsId(key));
    return row == null || row['deleted_at'] != null ? null : row['value'];
  }

  /// Есть ли живая настройка с таким ключом.
  Future<bool> contains(String key) async {
    _checkKey(key);
    final row = await _store.getRow(table, userSettingsId(key));
    return row != null && row['deleted_at'] == null;
  }

  /// Значение в реальном времени (в том числе изменения с других устройств).
  Stream<Object?> watch(String key) {
    _checkKey(key);
    return _store
        .watchRow(table, userSettingsId(key))
        .map(
          (row) =>
              row == null || row['deleted_at'] != null ? null : row['value'],
        );
  }

  /// Все живые настройки.
  Future<Map<String, Object?>> readAll() async {
    final rows = await _store.visibleRows(table, orderBy: 't.key');
    return {for (final r in rows) r['key']! as String: r['value']};
  }

  /// Записывает значение: создаёт настройку, меняет или возвращает из
  /// корзины (если ключ был удалён). Одинаковое значение не порождает
  /// операций.
  Future<void> set(String key, Object? value) async {
    _checkKey(key);
    if (utf8.encode(jsonEncode(value)).length > maxValueBytes) {
      throw ArgumentError.value(key, 'value', 'значение больше 16 КБ');
    }
    final id = userSettingsId(key);
    await _store.transaction(() async {
      final row = await _store.getRow(table, id);
      if (row == null) {
        await _store.create(table, id, {'key': key, 'value': value});
        return;
      }
      if (jsonEncode(row['value']) != jsonEncode(value)) {
        await _store.update(table, id, {'value': value});
      }
      if (row['deleted_at'] != null) await _store.restore(table, id);
    });
  }

  /// Удаляет настройку (в корзину на 30 дней). Нет ключа — ничего не делает.
  Future<void> remove(String key) async {
    _checkKey(key);
    final id = userSettingsId(key);
    await _store.transaction(() async {
      final row = await _store.getRow(table, id);
      if (row != null && row['deleted_at'] == null) {
        await _store.softDelete(table, id);
      }
    });
  }
}

final userSettingsRepositoryProvider = Provider<UserSettingsRepository>(
  (ref) => UserSettingsRepository(ref.watch(syncStoreProvider)),
);
