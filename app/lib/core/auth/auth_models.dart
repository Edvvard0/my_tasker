import 'package:flutter/foundation.dart';

/// Токены и идентификатор устройства после входа или обновления
/// (spec 1.1, 1.3). Хранится **только** в защищённом хранилище ОС.
@immutable
class AuthSession {
  const AuthSession({
    required this.deviceId,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
    this.serverEpoch,
  });

  factory AuthSession.fromJson(Map<String, Object?> json) => AuthSession(
    deviceId: json['device_id']! as String,
    accessToken: json['access_token']! as String,
    accessExpiresAt: DateTime.parse(json['access_expires_at']! as String),
    refreshToken: json['refresh_token']! as String,
    refreshExpiresAt: DateTime.parse(json['refresh_expires_at']! as String),
    serverEpoch: json['server_epoch']?.toString(),
  );

  final String deviceId;
  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;

  /// `server_epoch` из ответа входа/обновления (не секрет; в хранилище
  /// токенов не пишется).
  final String? serverEpoch;

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'access_token': accessToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_token': refreshToken,
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
  };

  /// Токены в строку не попадают (журналы, отчёты об ошибках).
  @override
  String toString() => 'AuthSession(device: $deviceId, tokens: ***)';
}

/// Платформа устройства (spec 1.1).
enum DevicePlatform {
  android,
  windows,
  linux,
  macos,
  ios,
  web,
  other;

  static DevicePlatform parse(String? value) => values.firstWhere(
    (p) => p.name == value,
    orElse: () => DevicePlatform.other,
  );
}

/// Что клиент сообщает о себе при входе.
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.platform,
    this.appVersion,
  });

  final String name;
  final DevicePlatform platform;
  final String? appVersion;

  Map<String, Object?> toJson() => {
    'name': name,
    'platform': platform.name,
    'app_version': ?appVersion,
  };
}

/// Устройство из `GET /auth/devices` (spec 1.4).
@immutable
class RegisteredDevice {
  const RegisteredDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.isCurrent,
    this.appVersion,
    this.lastSeenAt,
    this.lastPulledVersion,
    this.revokedAt,
  });

  factory RegisteredDevice.fromJson(Map<String, Object?> json) =>
      RegisteredDevice(
        id: json['id']! as String,
        name: json['name']! as String,
        platform: DevicePlatform.parse(json['platform'] as String?),
        appVersion: json['app_version'] as String?,
        createdAt: DateTime.parse(json['created_at']! as String),
        lastSeenAt: _time(json['last_seen_at']),
        lastPulledVersion: json['last_pulled_version'] as int?,
        revokedAt: _time(json['revoked_at']),
        isCurrent: (json['is_current'] as bool?) ?? false,
      );

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.parse(value) : null;

  final String id;
  final String name;
  final DevicePlatform platform;
  final String? appVersion;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final int? lastPulledVersion;
  final DateTime? revokedAt;
  final bool isCurrent;

  bool get isRevoked => revokedAt != null;
}

/// Почему пользователь вышел (для подсказки на экране входа).
enum SignOutReason {
  /// Ещё не входил.
  none,

  /// Нажал «Выйти».
  loggedOut,

  /// Устройство отозвано с другого устройства (`device_revoked`).
  revoked,

  /// Предъявлен уже использованный refresh-токен
  /// (`refresh_reuse_detected`): сервер отозвал устройство.
  refreshReuse,

  /// Refresh-токен недействителен или просрочен.
  expired,
}

/// Состояние входа.
@immutable
sealed class AuthState {
  const AuthState();
}

/// Хранилище токенов ещё читается.
final class AuthUnknown extends AuthState {
  const AuthUnknown();
}

/// Нужен вход; локальные данные сохранены.
final class SignedOut extends AuthState {
  const SignedOut([this.reason = SignOutReason.none]);

  final SignOutReason reason;
}

/// Вход выполнен.
final class SignedIn extends AuthState {
  const SignedIn(this.deviceId);

  final String deviceId;
}
