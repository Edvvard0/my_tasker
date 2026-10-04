import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Защищённое хранилище секретов замка раздела: Android Keystore /
/// Windows DPAPI через `flutter_secure_storage`. PIN в открытом виде
/// нигде не хранится (только соль и хеш, см. `PinLockService`).
abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Хранилище в памяти (тесты).
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  /// Тест может «сломать» хранилище: чтение бросает исключение.
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('хранилище недоступно');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
