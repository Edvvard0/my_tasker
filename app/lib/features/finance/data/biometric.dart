/// Биометрия для замка раздела — через интерфейс: плагина биометрии в
/// проекте пока нет (платформенный адаптер добавляется отдельно, чтобы не
/// тянуть рискованную зависимость без проверки на устройстве). До тех пор
/// действует [UnavailableBiometric], и замок работает только по PIN.
abstract interface class BiometricAuthenticator {
  /// Есть ли на устройстве биометрия, которой можно пользоваться.
  Future<bool> isAvailable();

  /// Просит подтвердить личность; `true` — подтверждено.
  Future<bool> authenticate({required String reason});
}

/// Биометрии нет: кнопка и переключатель в интерфейсе не показываются.
class UnavailableBiometric implements BiometricAuthenticator {
  const UnavailableBiometric();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate({required String reason}) async => false;
}

/// Управляемая подделка для тестов.
class FakeBiometric implements BiometricAuthenticator {
  FakeBiometric({this.available = true, this.succeeds = true});

  bool available;
  bool succeeds;
  int calls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    return succeeds;
  }
}
