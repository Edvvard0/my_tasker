import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/finance/data/biometric.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';

/// Приватность раздела «Финансы» — только клиент, сервер не участвует.

/// Защищённое хранилище PIN (тесты подставляют память).
final Provider<SecretStore> secretStoreProvider = Provider<SecretStore>(
  (ref) => SecureSecretStore(),
);

/// Биометрия: платформенного плагина пока нет — [UnavailableBiometric].
final Provider<BiometricAuthenticator> biometricProvider =
    Provider<BiometricAuthenticator>((ref) => const UnavailableBiometric());

final Provider<PinLockService> pinLockServiceProvider =
    Provider<PinLockService>(
      (ref) => PinLockService(
        ref.watch(secretStoreProvider),
        now: ref.watch(clockProvider),
      ),
    );

// ---- «скрыть суммы» ----------------------------------------------------------

/// Ключ локальной настройки (таблица `local_settings`, не синхронизируется).
const String hideAmountsSettingKey = 'finance.hide_amounts';

/// Режим «скрыть суммы»: суммы в разделе показываются как «••• ₽». Хранится
/// на устройстве.
class HideAmountsNotifier extends Notifier<bool> {
  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    final value = await ref
        .read(localSettingsRepositoryProvider)
        .read(hideAmountsSettingKey);
    if (ref.mounted && value != null) state = value == '1';
  }

  Future<void> set({required bool hidden}) async {
    state = hidden;
    await ref
        .read(localSettingsRepositoryProvider)
        .write(hideAmountsSettingKey, hidden ? '1' : '0');
  }
}

final NotifierProvider<HideAmountsNotifier, bool> hideAmountsProvider =
    NotifierProvider<HideAmountsNotifier, bool>(HideAmountsNotifier.new);

/// Форматирование сумм с учётом режима «скрыть суммы».
@immutable
class AmountFormat {
  const AmountFormat({required this.hidden});

  final bool hidden;

  static const String mask = '••• ₽';

  /// `1 234,56 ₽` или маска.
  String full(int kopecks) => hidden ? mask : formatAmount(kopecks);

  /// Компактно для плиток: `80,5к ₽`.
  String short(int kopecks) => hidden ? mask : formatAmountShort(kopecks);

  /// Со знаком: `+1 000 ₽` / `-250 ₽` (ASCII-минус); 0 — без знака.
  String signed(int kopecks) {
    if (hidden) return mask;
    final text = formatAmount(kopecks);
    return kopecks > 0 ? '+$text' : text;
  }
}

final Provider<AmountFormat> amountFormatProvider = Provider<AmountFormat>(
  (ref) => AmountFormat(hidden: ref.watch(hideAmountsProvider)),
);

// ---- замок раздела --------------------------------------------------------------

/// Состояние замка раздела.
@immutable
class FinanceLockState {
  const FinanceLockState({
    this.loaded = false,
    this.hasPin = false,
    this.locked = true,
    this.biometric = false,
    this.biometricAvailable = false,
    this.failures = 0,
    this.blockedUntil,
    this.error,
  });

  /// Состояние замка прочитано из хранилища.
  final bool loaded;
  final bool hasPin;

  /// Раздел закрыт: пока `true`, содержимое не показывается.
  final bool locked;

  /// Включена разблокировка биометрией (и она доступна).
  final bool biometric;
  final bool biometricAvailable;
  final int failures;
  final DateTime? blockedUntil;

  /// Не удалось прочитать защищённое хранилище (раздел остаётся закрыт).
  final String? error;

  FinanceLockState copyWith({
    bool? loaded,
    bool? hasPin,
    bool? locked,
    bool? biometric,
    bool? biometricAvailable,
    int? failures,
    Object? blockedUntil = _unset,
    Object? error = _unset,
  }) => FinanceLockState(
    loaded: loaded ?? this.loaded,
    hasPin: hasPin ?? this.hasPin,
    locked: locked ?? this.locked,
    biometric: biometric ?? this.biometric,
    biometricAvailable: biometricAvailable ?? this.biometricAvailable,
    failures: failures ?? this.failures,
    blockedUntil: identical(blockedUntil, _unset)
        ? this.blockedUntil
        : blockedUntil as DateTime?,
    error: identical(error, _unset) ? this.error : error as String?,
  );
}

const Object _unset = Object();

/// Ключ локальной настройки «разблокировать биометрией».
const String biometricSettingKey = 'finance.lock.biometric';

/// Итог попытки разблокировки.
enum UnlockResult { unlocked, wrong, blocked }

class FinanceLockNotifier extends Notifier<FinanceLockState> {
  @override
  FinanceLockState build() {
    unawaited(load());
    return const FinanceLockState();
  }

  PinLockService get _pin => ref.read(pinLockServiceProvider);

  /// Читает состояние замка. Если защищённое хранилище недоступно, раздел
  /// остаётся закрытым (а не открывается «по умолчанию»).
  Future<void> load() async {
    try {
      final hasPin = await _pin.isConfigured();
      final available = await ref.read(biometricProvider).isAvailable();
      final wanted =
          await ref
              .read(localSettingsRepositoryProvider)
              .read(biometricSettingKey) ==
          '1';
      final until = await _pin.blockedUntil();
      if (!ref.mounted) return;
      state = FinanceLockState(
        loaded: true,
        hasPin: hasPin,
        locked: hasPin,
        biometric: hasPin && available && wanted,
        biometricAvailable: available,
        blockedUntil: until,
      );
    } on Object {
      if (!ref.mounted) return;
      state = const FinanceLockState(
        loaded: true,
        hasPin: true,
        error: 'Не удалось прочитать защищённое хранилище',
      );
    }
  }

  /// Закрывает раздел (уход приложения в фон, кнопка «Закрыть»).
  void lock() {
    if (state.hasPin && !state.locked) state = state.copyWith(locked: true);
  }

  Future<UnlockResult> unlockWithPin(String pin) async {
    final result = await _check(pin);
    if (result == UnlockResult.unlocked) {
      state = state.copyWith(
        locked: false,
        failures: 0,
        blockedUntil: null,
        error: null,
      );
    }
    return result;
  }

  /// Разблокировка биометрией (если включена и доступна).
  Future<bool> unlockWithBiometric() async {
    if (!state.biometric) return false;
    final ok = await ref
        .read(biometricProvider)
        .authenticate(reason: 'Открыть раздел «Финансы»');
    if (ok) state = state.copyWith(locked: false, failures: 0);
    return ok;
  }

  /// Включает замок или меняет PIN; раздел остаётся открытым.
  Future<void> setPin(String pin) async {
    await _pin.setPin(pin);
    state = state.copyWith(hasPin: true, locked: false, failures: 0);
  }

  /// Проверяет PIN, обновляя счётчик ошибок и блокировку.
  Future<UnlockResult> _check(String pin) async {
    final result = await _pin.verify(pin);
    switch (result) {
      case PinAccepted():
        return UnlockResult.unlocked;
      case PinRejected(:final failures, :final blockedUntil):
        state = state.copyWith(failures: failures, blockedUntil: blockedUntil);
        return blockedUntil == null ? UnlockResult.wrong : UnlockResult.blocked;
      case PinBlocked(:final until):
        state = state.copyWith(blockedUntil: until);
        return UnlockResult.blocked;
    }
  }

  /// Снимает замок (после проверки текущего PIN).
  Future<UnlockResult> removePin(String currentPin) async {
    final result = await _check(currentPin);
    if (result != UnlockResult.unlocked) return result;
    await _pin.clear();
    await ref.read(localSettingsRepositoryProvider).delete(biometricSettingKey);
    state = state.copyWith(
      hasPin: false,
      locked: false,
      biometric: false,
      failures: 0,
    );
    return result;
  }

  /// Меняет PIN (после проверки текущего).
  Future<UnlockResult> changePin(String currentPin, String nextPin) async {
    final result = await _check(currentPin);
    if (result != UnlockResult.unlocked) return result;
    await _pin.setPin(nextPin);
    state = state.copyWith(failures: 0);
    return result;
  }

  Future<void> setBiometric({required bool enabled}) async {
    if (!state.hasPin || !state.biometricAvailable) return;
    await ref
        .read(localSettingsRepositoryProvider)
        .write(biometricSettingKey, enabled ? '1' : '0');
    state = state.copyWith(biometric: enabled);
  }
}

final NotifierProvider<FinanceLockNotifier, FinanceLockState>
financeLockProvider = NotifierProvider<FinanceLockNotifier, FinanceLockState>(
  FinanceLockNotifier.new,
);
