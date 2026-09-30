import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/async/async_mutex.dart';
import 'package:my_tasker/core/auth/auth_api.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final authApiProvider = Provider<AuthApi?>((ref) {
  final client = ref.watch(apiClientProvider);
  return client == null ? null : AuthApi(client);
});

/// Запас до истечения access-токена, при котором он обновляется заранее.
const Duration accessRefreshMargin = Duration(seconds: 30);

/// Сессия входа: токены, обновление с ротацией, выход.
///
/// * Токены — только в [TokenStore] (защищённое хранилище ОС).
/// * Обновление идёт под общим mutex: параллельные `401` вызывают **один**
///   `POST /auth/refresh`, остальные получают уже обновлённый токен
///   (spec 1.3: параллельный refresh недопустим — второй использовал бы
///   уже отработанный refresh-токен и отозвал бы устройство).
/// * Новый refresh сохраняется **до** использования новых токенов.
/// * Отзыв устройства и повторное использование refresh стирают токены и
///   переводят в «нужен вход»; локальные данные остаются.
class AuthController extends Notifier<AuthState>
    implements AccessTokenProvider {
  AuthSession? _session;
  final AsyncMutex _refreshMutex = AsyncMutex();
  bool _disposed = false;

  /// Завершается, когда токены прочитаны из хранилища.
  Future<void> ready = Future<void>.value();

  @override
  AuthState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    ready = _load();
    return const AuthUnknown();
  }

  DateTime _now() => ref.read(clockProvider)();

  Future<void> _load() async {
    final session = await ref.read(tokenStoreProvider).read();
    if (_disposed) return;
    _session = session;
    state = session == null ? const SignedOut() : SignedIn(session.deviceId);
  }

  /// Вход по паролю и коду TOTP. Ошибки — [ApiException]
  /// (`invalid_credentials`, `too_many_attempts`, `client_too_old`, …).
  Future<void> login({
    required String password,
    required String totpCode,
    required DeviceInfo device,
  }) async {
    await ready;
    final api = ref.read(authApiProvider);
    if (api == null) throw const ApiException.notConfigured();
    final session = await api.login(
      password: password,
      totpCode: totpCode,
      device: device,
    );
    // Метки неотправленных операций получают идентификатор нового устройства.
    final store = ref.read(syncStoreProvider);
    await store.adoptDevice(session.deviceId);
    await store.observeEpoch(session.serverEpoch);
    await ref.read(tokenStoreProvider).write(session);
    _session = session;
    state = SignedIn(session.deviceId);
  }

  /// Выход: отзывает текущее устройство на сервере (если сеть есть) и
  /// стирает токены. Локальные данные остаются.
  Future<void> logout() async {
    await ready;
    try {
      await ref.read(authApiProvider)?.logout();
    } on ApiException {
      // Нет сети или сессия уже недействительна: выходим локально.
    }
    await _endSession(SignOutReason.loggedOut);
  }

  Future<void> _endSession(SignOutReason reason) async {
    _session = null;
    await ref.read(tokenStoreProvider).clear();
    if (!_disposed) state = SignedOut(reason);
  }

  @override
  Future<String?> currentAccessToken() async {
    await ready;
    final session = _session;
    if (session == null) return null;
    if (session.accessExpiresAt.difference(_now()) > accessRefreshMargin) {
      return session.accessToken;
    }
    return await refreshAfterUnauthorized(session.accessToken);
  }

  @override
  Future<String?> refreshAfterUnauthorized(String? usedToken) =>
      _refreshMutex.protect(() async {
        final session = _session;
        if (session == null) return null;
        // Кто-то уже обновил токены, пока этот запрос ждал очереди.
        if (usedToken != null && session.accessToken != usedToken) {
          return session.accessToken;
        }
        if (!session.refreshExpiresAt.isAfter(_now())) {
          await _endSession(SignOutReason.expired);
          return null;
        }
        final api = ref.read(authApiProvider);
        if (api == null) throw const ApiException.notConfigured();
        try {
          final fresh = await api.refresh(session.refreshToken);
          // Сначала сохраняем новый refresh, потом пользуемся токенами.
          await ref.read(tokenStoreProvider).write(fresh);
          _session = fresh;
          await ref.read(syncStoreProvider).observeEpoch(fresh.serverEpoch);
          return fresh.accessToken;
        } on ApiException catch (e) {
          final reason = switch (e.code) {
            'device_revoked' => SignOutReason.revoked,
            'refresh_reuse_detected' => SignOutReason.refreshReuse,
            'invalid_refresh_token' ||
            'refresh_expired' => SignOutReason.expired,
            _ => null,
          };
          if (reason == null) rethrow;
          await _endSession(reason);
          return null;
        }
      });

  @override
  Future<void> onDeviceRevoked(String code) async {
    if (code == 'device_revoked') {
      await _endSession(SignOutReason.revoked);
    } else if (code == 'refresh_reuse_detected') {
      await _endSession(SignOutReason.refreshReuse);
    }
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
