import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Хранилище ключа шифрования локальной БД.
abstract interface class DatabaseKeyStore {
  /// Возвращает 256-битный ключ в виде 64 hex-символов; при первом запуске
  /// генерирует и сохраняет его.
  Future<String> getOrCreateKey();
}

/// Ключ в защищённом хранилище ОС: Android Keystore, Windows DPAPI
/// (через `flutter_secure_storage`).
class SecureDatabaseKeyStore implements DatabaseKeyStore {
  SecureDatabaseKeyStore({FlutterSecureStorage? storage, Random? random})
    : _storage = storage ?? const FlutterSecureStorage(),
      _random = random ?? Random.secure();

  static const storageKey = 'db_encryption_key_v1';
  static const keyBytes = 32;

  final FlutterSecureStorage _storage;
  final Random _random;

  @override
  Future<String> getOrCreateKey() async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(existing)) {
        // Не пересоздаём молча: новый ключ сделал бы старую БД нечитаемой.
        throw StateError('Ключ шифрования БД повреждён');
      }
      return existing;
    }
    final key = generateKey(_random);
    await _storage.write(key: storageKey, value: key);
    return key;
  }

  /// 32 случайных байта в hex (строчные буквы).
  static String generateKey(Random random) {
    final buffer = StringBuffer();
    for (var i = 0; i < keyBytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
