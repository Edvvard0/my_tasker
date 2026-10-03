import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/features/finance/data/biometric_authenticator.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/data/pin_hasher.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

/// Замок раздела «Финансы» и режим «скрыть суммы» (Этап 5d). Всё — только на
/// устройстве, сервер не участвует.

/// Хранилище приватности. Тесты подменяют его на память.
final financePrivacyStoreProvider = Provider<FinancePrivacyStore>(
  (ref) => SecureFinancePrivacyStore(),
);

/// Биометрия. Тесты подменяют её на поддельную.
final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => LocalAuthBiometric(),
);

/// Вычисление ключа из PIN (дешёвый вариант — в тестах).
final pinHasherProvider = Provider<PinHasher>((ref) => const PinHasher());

/// Источник случайности для соли.
final pinRandomProvider = Provider<Random>((ref) => Random.secure());

/// Состояние замка.
@immutable
class FinanceLockState {
  const FinanceLockState({
    this.loaded = false,
    this.enabled = false,
    this.locked = true,
    this.timing = LockTiming.immediately,
    this.biometric = false,
    this.pinLength = pinMinLength,
    this.failures = 0,
    this.pausedUntil,
    this.problem,
  });

  /// Запись замка прочитана из хранилища (или не прочиталась — тогда
  /// заполнен [problem]).
  final bool loaded;
  final bool enabled;

  /// Раздел сейчас закрыт (имеет смысл при [enabled]).
  final bool locked;
  final LockTiming timing;
  final bool biometric;
  final int pinLength;
  final int failures;
  final DateTime? pausedUntil;

  /// Запись замка прочитать не удалось: хранилище недоступно или запись
  /// повреждена. Пока это так, раздел закрыт (замок не «выключен»).
  final LockProblem? problem;

  /// Содержимое «Финансов» показывать нельзя: замок ещё не прочитан (на
  /// холодном старте — «закрыто, пока не доказано обратное»), не прочитался
  /// ([problem]) либо включён и закрыт.
  bool get closed => !loaded || problem != null || (enabled && locked);

  FinanceLockState copyWith({
    bool? loaded,
    bool? enabled,
    bool? locked,
    LockTiming? timing,
    bool? biometric,
    int? pinLength,
    int? failures,
    DateTime? pausedUntil,
    bool clearPause = false,
  }) => FinanceLockState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    locked: locked ?? this.locked,
    timing: timing ?? this.timing,
    biometric: biometric ?? this.biometric,
    pinLength: pinLength ?? this.pinLength,
    failures: failures ?? this.failures,
    pausedUntil: clearPause ? null : (pausedUntil ?? this.pausedUntil),
    problem: problem,
  );
}

/// Замок: проверка PIN с защитой от подбора, тайминг блокировки, биометрия.
class FinanceLockController extends Notifier<FinanceLockState> {
  Future<void>? _loading;
  LockRecord? _record;
  Timer? _timer;
  DateTime? _leftAt;

  // Пользователь внутри раздела «Финансы» и приложение на переднем плане.
  bool _inSection = false;
  bool _foreground = true;
  bool _inUse = false;

  @override
  FinanceLockState build() {
    ref.onDispose(() => _timer?.cancel());
    _loading = _load();
    return const FinanceLockState();
  }

  /// Завершается, когда запись замка прочитана.
  Future<void> get ready => _loading ?? Future<void>.value();

  DateTime get _now => ref.read(clockProvider)();

  Future<void> _load() async {
    LockRecord? record;
    try {
      record = await ref.read(financePrivacyStoreProvider).readLock();
    } on CorruptLockRecord {
      // Запись есть, но не разбирается: проверить PIN нельзя, а молча
      // отключать замок нельзя. Раздел закрыт до явного сброса.
      _failLoad(LockProblem.corrupted);
      return;
    } on Object {
      // Хранилище не ответило: это не «замка нет». Запись не трогаем,
      // раздел закрыт, пока чтение не удастся («Повторить»).
      _failLoad(LockProblem.storageUnavailable);
      return;
    }
    if (!ref.mounted) return;
    _record = record;
    // Холодный старт: включённый замок всегда закрыт.
    state = _fromRecord(record, locked: true);
  }

  void _failLoad(LockProblem problem) {
    if (!ref.mounted) return;
    _record = null;
    state = FinanceLockState(loaded: true, problem: problem);
  }

  /// Перечитывает запись замка после сбоя хранилища («Повторить»).
  Future<void> retryLoad() {
    if (state.problem == null) return ready;
    state = const FinanceLockState();
    return _loading = _load();
  }

  /// Сбрасывает замок, чья запись повреждена: удаляет запись, раздел
  /// открывается без PIN (данные «Финансов» не затрагиваются, теряется
  /// только PIN — новый можно задать в настройках приватности). Работает
  /// только при [LockProblem.corrupted]; вызывать после подтверждения.
  Future<void> resetCorruptedLock() async {
    if (state.problem != LockProblem.corrupted) return;
    await ref.read(financePrivacyStoreProvider).clearLock();
    _record = null;
    if (ref.mounted) state = _fromRecord(null, locked: false);
  }

  FinanceLockState _fromRecord(LockRecord? r, {required bool locked}) =>
      r == null
      ? const FinanceLockState(loaded: true, locked: false)
      : FinanceLockState(
          loaded: true,
          enabled: true,
          locked: locked,
          timing: r.timing,
          biometric: r.biometric,
          pinLength: r.pinLength,
          failures: r.failures,
          pausedUntil: _pauseOf(r),
        );

  DateTime? _pauseOf(LockRecord r) {
    final ms = r.pausedUntilMs;
    if (ms == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(ms);
    return until.isAfter(_now) ? until : null;
  }

  Future<void> _persist(LockRecord record) async {
    _record = record;
    await ref.read(financePrivacyStoreProvider).writeLock(record);
  }

  // ---- проверка PIN --------------------------------------------------------

  /// Проверяет PIN с учётом пауз и счётчика попыток; сам замок не открывает.
  Future<PinCheck> _check(String pin) async {
    await ready;
    // Запись замка не прочитана: PIN проверить нечем, раздел не открывается.
    if (state.problem != null) {
      return const PinRejected(attemptsLeft: attemptsBeforePause);
    }
    final record = _record;
    if (record == null) return const PinAccepted();
    final now = _now;
    final paused = _pauseOf(record);
    if (paused != null) return PinPaused(paused);

    // Попытка записывается ДО проверки: если приложение убьют посреди
    // вычисления хеша, неверная попытка всё равно останется посчитанной
    // (иначе можно подбирать PIN, обрывая процесс до записи счётчика).
    final failures = record.failures + 1;
    final pause = pauseAfterFailures(failures);
    final until = pause == Duration.zero ? null : now.add(pause);
    await _persist(
      record.copyWith(
        failures: failures,
        pausedUntilMs: until?.millisecondsSinceEpoch,
        clearPause: until == null,
      ),
    );

    final derived = await ref
        .read(pinHasherProvider)
        .derive(pin, record.salt, record.iterations);
    if (!ref.mounted) return const PinRejected(attemptsLeft: 0);
    if (constantTimeEquals(derived, record.hash)) {
      // Верный PIN снимает счётчик и паузу.
      await _persist(record.copyWith(failures: 0, clearPause: true));
      if (ref.mounted) state = state.copyWith(failures: 0, clearPause: true);
      return const PinAccepted();
    }

    if (ref.mounted) {
      state = state.copyWith(
        failures: failures,
        pausedUntil: until,
        clearPause: until == null,
      );
    }
    return PinRejected(
      attemptsLeft: attemptsLeft(failures),
      pausedUntil: until,
    );
  }

  /// Проверка PIN для чувствительных действий (смена, отключение).
  Future<PinCheck> verifyPin(String pin) => _check(pin);

  /// Разблокирует раздел по PIN.
  Future<PinCheck> unlock(String pin) async {
    final result = await _check(pin);
    if (result is PinAccepted && ref.mounted) {
      state = state.copyWith(locked: false);
    }
    return result;
  }

  /// Разблокирует биометрией, если она включена и доступна.
  Future<bool> unlockWithBiometric(String reason) async {
    await ready;
    if (!state.enabled || !state.biometric) return false;
    final auth = ref.read(biometricAuthenticatorProvider);
    if (!await auth.isAvailable()) return false;
    final ok = await auth.authenticate(reason);
    if (ok && ref.mounted) state = state.copyWith(locked: false);
    return ok;
  }

  // ---- настройка -----------------------------------------------------------

  /// Включает замок с новым PIN; раздел остаётся открытым (PIN только что
  /// введён).
  Future<void> enable(
    String pin, {
    LockTiming timing = LockTiming.immediately,
    bool biometric = false,
  }) async {
    if (!isValidPin(pin)) {
      throw ArgumentError.value(pin, 'pin', 'PIN — от 4 до 6 цифр');
    }
    await ready;
    if (state.problem != null) {
      // Не затираем запись, которую не удалось прочитать.
      throw StateError('Замок не прочитан: сначала повторите чтение');
    }
    final record = await _newRecord(pin, timing: timing, biometric: biometric);
    await _persist(record);
    if (!ref.mounted) return;
    state = _fromRecord(record, locked: false);
  }

  Future<LockRecord> _newRecord(
    String pin, {
    required LockTiming timing,
    required bool biometric,
  }) async {
    final salt = randomPinSalt(ref.read(pinRandomProvider));
    final hasher = ref.read(pinHasherProvider);
    final hash = await hasher.derive(pin, salt, hasher.iterations);
    return LockRecord(
      salt: salt,
      hash: hash,
      iterations: hasher.iterations,
      pinLength: pin.length,
      timing: timing,
      biometric: biometric,
    );
  }

  /// Меняет PIN после проверки текущего.
  Future<PinCheck> changePin(String current, String next) async {
    if (!isValidPin(next)) {
      throw ArgumentError.value(next, 'next', 'PIN — от 4 до 6 цифр');
    }
    final result = await _check(current);
    if (result is! PinAccepted) return result;
    final old = _record!;
    final record = await _newRecord(
      next,
      timing: old.timing,
      biometric: old.biometric,
    );
    await _persist(record);
    if (ref.mounted) state = _fromRecord(record, locked: false);
    return result;
  }

  /// Отключает замок после проверки текущего PIN.
  Future<PinCheck> disable(String current) async {
    final result = await _check(current);
    if (result is! PinAccepted) return result;
    _timer?.cancel();
    await ref.read(financePrivacyStoreProvider).clearLock();
    _record = null;
    if (ref.mounted) state = _fromRecord(null, locked: false);
    return result;
  }

  Future<void> setTiming(LockTiming timing) async {
    final record = _record;
    if (record == null) return;
    await _persist(record.copyWith(timing: timing));
    if (ref.mounted) state = state.copyWith(timing: timing);
  }

  Future<void> setBiometric({required bool value}) async {
    final record = _record;
    if (record == null) return;
    await _persist(record.copyWith(biometric: value));
    if (ref.mounted) state = state.copyWith(biometric: value);
  }

  // ---- блокировка по времени -----------------------------------------------

  /// Закрывает раздел немедленно.
  void lockNow() {
    _timer?.cancel();
    if (ref.mounted && state.loaded && state.enabled && !state.locked) {
      state = state.copyWith(locked: true);
    }
  }

  /// Пользователь вошёл в раздел «Финансы» ([value] `true`) или вышел.
  void setSectionActive({required bool value}) {
    if (!ref.mounted) return;
    _inSection = value;
    _recompute();
  }

  /// Приложение на переднем плане или свёрнуто.
  void setForeground({required bool value}) {
    if (!ref.mounted) return;
    _foreground = value;
    _recompute();
  }

  /// «Ушёл» = не в разделе или приложение свёрнуто. При уходе запоминаем
  /// момент и взводим таймер; при возвращении отменяем таймер и, если
  /// времени прошло не меньше выбранного (таймер мог не сработать, пока
  /// приложение спало), закрываем раздел.
  void _recompute() {
    final inUse = _inSection && _foreground;
    if (inUse == _inUse) return;
    _inUse = inUse;
    if (!inUse) {
      _leftAt = _now;
      _timer?.cancel();
      if (!state.enabled || state.locked) return;
      final delay = state.timing.delay;
      if (delay == Duration.zero) {
        lockNow();
      } else {
        _timer = Timer(delay, lockNow);
      }
      return;
    }
    _timer?.cancel();
    final left = _leftAt;
    _leftAt = null;
    if (left != null &&
        state.enabled &&
        !state.locked &&
        _now.difference(left) >= state.timing.delay) {
      lockNow();
    }
  }
}

final financeLockProvider =
    NotifierProvider<FinanceLockController, FinanceLockState>(
      FinanceLockController.new,
    );

// ---- «скрыть суммы» --------------------------------------------------------

/// Состояние режима «скрыть суммы».
@immutable
class HideAmountsState {
  const HideAmountsState({this.loaded = false, this.hidden = false});

  final bool loaded;
  final bool hidden;

  /// Суммы скрывать: режим включён либо ещё не прочитан (чтобы на холодном
  /// старте суммы не мелькнули до чтения настройки).
  bool get masked => !loaded || hidden;
}

/// Режим «скрыть суммы»: хранится на устройстве, не синхронизируется.
class HideAmountsController extends Notifier<HideAmountsState> {
  Future<void>? _loading;
  bool _touched = false;

  @override
  HideAmountsState build() {
    _touched = false;
    _loading = _load();
    return const HideAmountsState();
  }

  Future<void> get ready => _loading ?? Future<void>.value();

  Future<void> _load() async {
    var hidden = false;
    try {
      hidden = await ref.read(financePrivacyStoreProvider).readHideAmounts();
    } on Object {
      // Не прочиталось: показываем, как по умолчанию.
    }
    if (!ref.mounted || _touched) return;
    state = HideAmountsState(loaded: true, hidden: hidden);
  }

  Future<void> set({required bool hidden}) async {
    _touched = true;
    state = HideAmountsState(loaded: true, hidden: hidden);
    try {
      await ref
          .read(financePrivacyStoreProvider)
          .writeHideAmounts(hidden: hidden);
    } on Object {
      // Не записалось — режим действует до закрытия приложения.
    }
  }

  Future<void> toggle() => set(hidden: !state.hidden);
}

final hideAmountsProvider =
    NotifierProvider<HideAmountsController, HideAmountsState>(
      HideAmountsController.new,
    );

/// Суммы Финансов нужно маскировать: включён режим «скрыть суммы» либо
/// раздел закрыт замком. Единственный вход для всех, кто показывает суммы
/// Финансов (экраны, поиск, виджеты «Сегодня»).
final amountsMaskedProvider = Provider<bool>(
  (ref) =>
      ref.watch(hideAmountsProvider.select((s) => s.masked)) ||
      ref.watch(financeLockProvider.select((s) => s.closed)),
);

/// Пользователь явно разрешил отправить суммы в контекст ИИ при включённом
/// «скрыть суммы» (подтверждение в превью). Живёт только в памяти: новый
/// запуск, новое переключение режима или блокировка раздела сбрасывают его.
class FinanceAiAmountsConsent extends Notifier<bool> {
  @override
  bool build() {
    // Любая смена режима или блокировка отзывает согласие.
    ref
      ..listen(hideAmountsProvider.select((s) => s.hidden), (_, _) {
        state = false;
      })
      ..listen(financeLockProvider.select((s) => s.closed), (_, closed) {
        if (closed) state = false;
      });
    return false;
  }

  // Метод, а не сеттер: вызывается из обработчика кнопки превью.
  // ignore: use_setters_to_change_properties
  void set({required bool value}) => state = value;
}

final financeAiAmountsConsentProvider =
    NotifierProvider<FinanceAiAmountsConsent, bool>(
      FinanceAiAmountsConsent.new,
    );

/// Чаты, в которых пользователь согласился отправить сообщение агенту
/// «Финансы» при включённом «скрыть суммы»: серверный агент сам читает счета,
/// цели и долги инструментами, и результаты уходят облачной модели и в
/// синхронизируемые сообщения чата. Живёт только в памяти и отзывается так же,
/// как согласие на контекст: новым переключением режима или блокировкой.
class FinanceAgentConsent extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref
      ..listen(hideAmountsProvider.select((s) => s.hidden), (_, _) {
        state = const {};
      })
      ..listen(financeLockProvider.select((s) => s.closed), (_, closed) {
        if (closed) state = const {};
      });
    return const {};
  }

  /// Согласие для чата [conversationId] дано.
  void grant(String conversationId) => state = {...state, conversationId};
}

final financeAgentConsentProvider =
    NotifierProvider<FinanceAgentConsent, Set<String>>(FinanceAgentConsent.new);

/// Что можно положить в контекст ИИ.
@immutable
class FinanceAiAccess {
  const FinanceAiAccess({required this.unlocked, required this.amounts});

  /// Раздел открыт (замок выключен или снят): без этого данных нет вообще.
  final bool unlocked;

  /// Суммы разрешены: режим «скрыть суммы» выключен либо подтверждено
  /// отправить суммы.
  final bool amounts;
}

final financeAiAccessProvider = Provider<FinanceAiAccess>((ref) {
  final hide = ref.watch(hideAmountsProvider);
  final consent = ref.watch(financeAiAmountsConsentProvider);
  final closed = ref.watch(financeLockProvider.select((s) => s.closed));
  return FinanceAiAccess(
    unlocked: !closed,
    amounts: hide.loaded && (!hide.hidden || consent),
  );
});
