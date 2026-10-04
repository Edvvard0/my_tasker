import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';

/// Итог проверки PIN.
sealed class PinCheck {
  const PinCheck();
}

/// PIN верный.
class PinAccepted extends PinCheck {
  const PinAccepted();
}

/// PIN неверный; [failures] — подряд неверных попыток.
class PinRejected extends PinCheck {
  const PinRejected(this.failures, {this.blockedUntil});

  final int failures;

  /// Если после этой попытки наступила блокировка.
  final DateTime? blockedUntil;
}

/// Ввод заблокирован до [until].
class PinBlocked extends PinCheck {
  const PinBlocked(this.until);

  final DateTime until;
}

/// PIN-замок раздела «Финансы»: PIN хранится как соль и PBKDF2-хеш в
/// защищённом хранилище, не в открытом виде. После [freeAttempts] неверных
/// попыток подряд ввод блокируется на время, которое растёт вдвое с каждой
/// следующей ошибкой (до [maxBlock]); счётчик лежит в том же хранилище, а
/// не в памяти, поэтому перезапуск приложения блокировку не сбрасывает.
class PinLockService {
  PinLockService(
    this._store, {
    Random? random,
    this.iterations = 20000,
    DateTime Function()? now,
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  static const String pinKey = 'finance_lock_pin_v1'; // gitleaks:allow
  static const String attemptsKey = 'finance_lock_attempts_v1';
  static const int minLength = 4;
  static const int maxLength = 8;
  static const int freeAttempts = 5;
  static const Duration firstBlock = Duration(seconds: 30);
  static const Duration maxBlock = Duration(minutes: 15);

  final SecretStore _store;
  final Random _random;
  final DateTime Function() _now;

  /// Число итераций PBKDF2 для нового PIN (тесты ставят малое).
  final int iterations;

  /// Допустимый PIN: от 4 до 8 цифр.
  static String? problem(String pin) {
    if (!RegExp(r'^[0-9]+$').hasMatch(pin)) return 'PIN — только цифры';
    if (pin.length < minLength || pin.length > maxLength) {
      return 'PIN — от $minLength до $maxLength цифр';
    }
    return null;
  }

  Future<bool> isConfigured() async => await _store.read(pinKey) != null;

  /// Задаёт (или меняет) PIN; счётчик ошибок обнуляется.
  Future<void> setPin(String pin) async {
    final bad = problem(pin);
    if (bad != null) throw FormatException(bad);
    final salt = Uint8List.fromList([
      for (var i = 0; i < 16; i++) _random.nextInt(256),
    ]);
    final hash = _pbkdf2(utf8.encode(pin), salt, iterations);
    await _store.write(
      pinKey,
      jsonEncode({
        'v': 1,
        'iterations': iterations,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      }),
    );
    await _store.delete(attemptsKey);
  }

  /// Снимает PIN (замок выключен).
  Future<void> clear() async {
    await _store.delete(pinKey);
    await _store.delete(attemptsKey);
  }

  /// До какого момента ввод заблокирован; `null` — не заблокирован.
  Future<DateTime?> blockedUntil() async {
    final state = await _attempts();
    final until = state.blockedUntilMs;
    if (until == null) return null;
    final moment = DateTime.fromMillisecondsSinceEpoch(until, isUtc: true);
    return moment.isAfter(_now().toUtc()) ? moment : null;
  }

  /// Проверяет PIN. Неверные попытки считаются и блокируют ввод.
  Future<PinCheck> verify(String pin) async {
    final blocked = await blockedUntil();
    if (blocked != null) return PinBlocked(blocked);
    final raw = await _store.read(pinKey);
    if (raw == null) return const PinAccepted();
    final record = (jsonDecode(raw) as Map).cast<String, Object?>();
    final salt = base64Decode(record['salt']! as String);
    final expected = base64Decode(record['hash']! as String);
    final actual = _pbkdf2(
      utf8.encode(pin),
      salt,
      record['iterations']! as int,
    );
    if (_sameBytes(actual, expected)) {
      await _store.delete(attemptsKey);
      return const PinAccepted();
    }
    final state = await _attempts();
    final failures = state.failures + 1;
    DateTime? until;
    if (failures >= freeAttempts) {
      final doubled =
          firstBlock.inSeconds * (1 << min(failures - freeAttempts, 10));
      final seconds = min(doubled, maxBlock.inSeconds);
      until = _now().toUtc().add(Duration(seconds: seconds));
    }
    await _store.write(
      attemptsKey,
      jsonEncode({
        'failures': failures,
        'blocked_until_ms': until?.millisecondsSinceEpoch,
      }),
    );
    return PinRejected(failures, blockedUntil: until);
  }

  Future<({int failures, int? blockedUntilMs})> _attempts() async {
    final raw = await _store.read(attemptsKey);
    if (raw == null) return (failures: 0, blockedUntilMs: null);
    try {
      final map = (jsonDecode(raw) as Map).cast<String, Object?>();
      return (
        failures: (map['failures'] as int?) ?? 0,
        blockedUntilMs: map['blocked_until_ms'] as int?,
      );
    } on Object {
      return (failures: 0, blockedUntilMs: null);
    }
  }

  /// Сравнение за постоянное время.
  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// PBKDF2-HMAC-SHA256, один блок (32 байта).
  static Uint8List _pbkdf2(List<int> password, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, password);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return Uint8List.fromList(out);
  }
}
