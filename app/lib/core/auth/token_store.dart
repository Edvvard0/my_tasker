import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:my_tasker/core/auth/auth_models.dart';

/// Хранилище токенов сессии. Токены живут только здесь — в защищённом
/// хранилище ОС, не в SQLite и не в журналах.
abstract interface class TokenStore {
  Future<AuthSession?> read();

  Future<void> write(AuthSession session);

  Future<void> clear();
}

/// Android Keystore / Windows DPAPI через `flutter_secure_storage`.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 'auth_session_v1'; // gitleaks:allow

  final FlutterSecureStorage _storage;

  @override
  Future<AuthSession?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null) return null;
    try {
      return AuthSession.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      // Повреждённая запись равна отсутствию сессии: нужен новый вход.
      await _storage.delete(key: storageKey);
      return null;
    }
  }

  @override
  Future<void> write(AuthSession session) =>
      _storage.write(key: storageKey, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}

/// Хранилище в памяти (тесты).
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.session]);

  AuthSession? session;
  int writes = 0;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> write(AuthSession value) async {
    writes++;
    session = value;
  }

  @override
  Future<void> clear() async => session = null;
}
