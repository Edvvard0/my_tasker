import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/finance/data/biometric.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/screen_security.dart';
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

// ---- защита экрана от снимков ----------------------------------------------

/// Платформенная защита экрана (Android `FLAG_SECURE`); тесты подставляют
/// [FakeScreenSecurity].
final Provider<ScreenSecurity> screenSecurityProvider =
    Provider<ScreenSecurity>((ref) => const PlatformScreenSecurity());

/// Причины, по которым экран должен быть защищён: «скрыть суммы» и
/// открытый раздел «Финансы». Защита включена, пока причина есть хотя бы
/// одна.
class SecureScreenNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void setReason(String reason, {required bool on}) {
    if (state.contains(reason) == on) return;
    state = on ? {...state, reason} : ({...state}..remove(reason));
    unawaited(
      ref.read(screenSecurityProvider).setSecure(secure: state.isNotEmpty),
    );
  }
}

final NotifierProvider<SecureScreenNotifier, Set<String>> secureScreenProvider =
    NotifierProvider<SecureScreenNotifier, Set<String>>(
      SecureScreenNotifier.new,
    );

/// Причина защиты экрана: включён режим «скрыть суммы».
const String secureReasonHideAmounts = 'hide_amounts';

// ---- «скрыть суммы» ----------------------------------------------------------

/// Ключ локальной настройки (таблица `local_settings`, не синхронизируется).
const String hideAmountsSettingKey = 'finance.hide_amounts';

/// Режим «скрыть суммы»: суммы в разделе показываются как «••• ₽». Хранится
/// на устройстве. **Пока настройка не прочитана, суммы считаются скрытыми**:
/// иначе первый кадр после холодного старта показал бы их открытыми.
class HideAmountsNotifier extends Notifier<bool> {
  bool _touched = false;

  @override
  bool build() {
    _touched = false;
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    var hidden = false;
    try {
      final value = await ref
          .read(localSettingsRepositoryProvider)
          .read(hideAmountsSettingKey);
      hidden = value == '1';
    } on Object {
      // Не прочиталось — безопаснее оставить суммы скрытыми.
      hidden = true;
    }
    if (!ref.mounted || _touched) return;
    state = hidden;
    _syncSecure();
  }

  void _syncSecure() => ref
      .read(secureScreenProvider.notifier)
      .setReason(secureReasonHideAmounts, on: state);

  Future<void> set({required bool hidden}) async {
    _touched = true;
    state = hidden;
    _syncSecure();
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
  String full(int kopecks) => hidden ? mask : formatAmountClamped(kopecks);

  /// Компактно для плиток: `80,5к ₽`.
  String short(int kopecks) => hidden ? mask : formatAmountShort(kopecks);

  /// Со знаком: `+1 000 ₽` / `-250 ₽` (ASCII-минус); 0 — без знака.
  String signed(int kopecks) {
    if (hidden) return mask;
    final text = formatAmountClamped(kopecks);
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

/// Метка «замок сброшен, но защищённое хранилище не удалось очистить»: пока
/// она стоит, нечитаемое хранилище не запирает раздел снова (PIN из него всё
/// равно не будет прочитан), а при следующем успешном чтении хранилище
/// очищается.
const String lockResetPendingKey = 'finance.lock.reset_pending';

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
    final settings = ref.read(localSettingsRepositoryProvider);
    final pending = await settings.read(lockResetPendingKey) == '1';
    try {
      if (pending) {
        // Сброс замка не дочистил хранилище: доделываем, когда оно читается.
        await _pin.clear();
        await settings.delete(lockResetPendingKey);
      }
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
      state = pending
          ? const FinanceLockState(loaded: true, locked: false)
          : const FinanceLockState(
              loaded: true,
              hasPin: true,
              error: 'Не удалось прочитать защищённое хранилище',
            );
    }
  }

  /// «Забыл PIN» / нечитаемое хранилище: снимает замок на этом устройстве.
  /// PIN удаляется вместе с настройкой биометрии и счётчиком ошибок; данные
  /// раздела **не удаляются**. Вызывать только после явного подтверждения
  /// пользователя (диалог в интерфейсе). Если защищённое хранилище не
  /// очищается (нечитаемо), ставится метка [lockResetPendingKey]: замок
  /// считается снятым, а очистка повторится при следующем чтении.
  Future<void> resetLock() async {
    final settings = ref.read(localSettingsRepositoryProvider);
    var cleared = true;
    try {
      await _pin.clear();
    } on Object {
      cleared = false;
    }
    await settings.delete(biometricSettingKey);
    if (cleared) {
      await settings.delete(lockResetPendingKey);
    } else {
      await settings.write(lockResetPendingKey, '1');
    }
    if (!ref.mounted) return;
    state = FinanceLockState(
      loaded: true,
      locked: false,
      biometricAvailable: state.biometricAvailable,
    );
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
    // Блокировка после неверных PIN действует и на биометрию.
    final until = await _pin.blockedUntil();
    if (until != null) {
      state = state.copyWith(blockedUntil: until);
      return false;
    }
    final ok = await ref
        .read(biometricProvider)
        .authenticate(reason: 'Открыть раздел «Финансы»');
    if (ok) {
      state = state.copyWith(locked: false, failures: 0, blockedUntil: null);
    }
    return ok;
  }

  /// Включает замок или меняет PIN; раздел остаётся открытым.
  Future<void> setPin(String pin) async {
    await _pin.setPin(pin);
    await ref.read(localSettingsRepositoryProvider).delete(lockResetPendingKey);
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
