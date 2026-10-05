import 'package:flutter/services.dart';

/// Защита экрана от снимков и записи (Android `FLAG_SECURE`): пока раздел
/// «Финансы» открыт или включено «скрыть суммы», суммы не попадают в
/// скриншоты и в превью «последних приложений». Нативная часть —
/// `MainActivity.kt` (канал `my_tasker/screen_security`); на других
/// платформах канала нет, вызов тихо ничего не делает.
abstract interface class ScreenSecurity {
  Future<void> setSecure({required bool secure});
}

class PlatformScreenSecurity implements ScreenSecurity {
  const PlatformScreenSecurity();

  static const MethodChannel channel = MethodChannel(
    'my_tasker/screen_security',
  );

  @override
  Future<void> setSecure({required bool secure}) async {
    try {
      await channel.invokeMethod<void>('setSecure', secure);
    } on MissingPluginException {
      // Платформа без нативной части (Windows, тесты).
    } on PlatformException {
      // Защита экрана — усиление, а не условие работы раздела.
    }
  }
}

/// Запоминает вызовы (тесты).
class FakeScreenSecurity implements ScreenSecurity {
  final List<bool> calls = [];

  bool get secure => calls.isNotEmpty && calls.last;

  @override
  Future<void> setSecure({required bool secure}) async => calls.add(secure);
}
