import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Биометрическая разблокировка замка «Финансов». Только удобство поверх
/// PIN: PIN остаётся основным способом и запасным путём.
abstract interface class BiometricAuthenticator {
  /// Устройство умеет и биометрия настроена.
  Future<bool> isAvailable();

  /// Показывает системный запрос; `true` — пользователь подтвердил.
  Future<bool> authenticate(String reason);
}

/// Реализация на пакете `local_auth` (Android — отпечаток/лицо, Windows —
/// Windows Hello). На остальных платформах и при любой ошибке плагина
/// биометрия просто недоступна.
class LocalAuthBiometric implements BiometricAuthenticator {
  LocalAuthBiometric({LocalAuthentication? auth})
    : _plugin = auth ?? LocalAuthentication();

  final LocalAuthentication _plugin;

  bool get _supportedPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<bool> isAvailable() async {
    if (!_supportedPlatform) return false;
    try {
      if (!await _plugin.isDeviceSupported()) return false;
      // Windows Hello не перечисляет биометрию: хватает «устройство умеет».
      if (defaultTargetPlatform == TargetPlatform.windows) return true;
      return (await _plugin.getAvailableBiometrics()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    if (!_supportedPlatform) return false;
    try {
      return await _plugin.authenticate(
        localizedReason: reason,
        biometricOnly: defaultTargetPlatform == TargetPlatform.android,
      );
    } on Object {
      return false;
    }
  }
}
