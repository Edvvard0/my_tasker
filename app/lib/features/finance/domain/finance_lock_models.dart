import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Модели замка раздела «Финансы» (Этап 5d): замок и режим «скрыть суммы»
/// существуют только на устройстве, сервер о них не знает (spec Этапа 5, 0).

/// Минимальная и максимальная длина PIN.
const int pinMinLength = 4;
const int pinMaxLength = 6;

/// PIN — только цифры, от 4 до 6.
bool isValidPin(String pin) =>
    pin.length >= pinMinLength &&
    pin.length <= pinMaxLength &&
    RegExp(r'^[0-9]+$').hasMatch(pin);

/// Когда раздел блокируется после ухода из него или сворачивания приложения.
enum LockTiming {
  immediately('immediately', 'Сразу', Duration.zero),
  minute1('1m', 'Через 1 мин', Duration(minutes: 1)),
  minute5('5m', 'Через 5 мин', Duration(minutes: 5));

  const LockTiming(this.wire, this.label, this.delay);

  final String wire;
  final String label;
  final Duration delay;

  /// Неизвестное значение читается как самое строгое: «сразу».
  static LockTiming parse(Object? value) => LockTiming.values.firstWhere(
    (t) => t.wire == value,
    orElse: () => LockTiming.immediately,
  );
}

/// Сколько неверных попыток подряд допускается до первой паузы.
const int attemptsBeforePause = 5;

/// Первая пауза; каждая следующая неверная попытка удваивает её.
const Duration basePause = Duration(seconds: 30);

/// Потолок паузы.
const Duration maxPause = Duration(hours: 1);

/// Пауза после [failures] неверных попыток подряд: до пятой — нет, на пятой
/// 30 с, дальше 60 с, 120 с, … до часа.
Duration pauseAfterFailures(int failures) {
  if (failures < attemptsBeforePause) return Duration.zero;
  final steps = math.min(failures - attemptsBeforePause, 10);
  final seconds = basePause.inSeconds * (1 << steps);
  return Duration(seconds: math.min(seconds, maxPause.inSeconds));
}

/// Сколько попыток осталось до паузы (0 — пауза включится на следующей
/// ошибке или уже идёт).
int attemptsLeft(int failures) =>
    failures >= attemptsBeforePause ? 0 : attemptsBeforePause - failures;

/// Запись замка в защищённом хранилище. PIN как таковой не хранится: только
/// соль и результат PBKDF2-HMAC-SHA256.
@immutable
class LockRecord {
  const LockRecord({
    required this.salt,
    required this.hash,
    required this.iterations,
    required this.pinLength,
    this.timing = LockTiming.immediately,
    this.biometric = false,
    this.failures = 0,
    this.pausedUntilMs,
  });

  factory LockRecord.fromJson(Map<String, Object?> json) => LockRecord(
    salt: base64Decode(json['salt']! as String),
    hash: base64Decode(json['hash']! as String),
    iterations: json['iter']! as int,
    pinLength: json['len']! as int,
    timing: LockTiming.parse(json['timing']),
    biometric: json['biometric'] == true,
    failures: (json['failures'] as int?) ?? 0,
    pausedUntilMs: json['paused_until'] as int?,
  );

  /// Разбирает сохранённую строку; повреждённая запись — `null`.
  static LockRecord? tryParse(String raw) {
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      final record = LockRecord.fromJson(json);
      final sane =
          record.salt.isNotEmpty &&
          record.hash.isNotEmpty &&
          record.iterations > 0 &&
          record.pinLength >= pinMinLength &&
          record.pinLength <= pinMaxLength;
      return sane ? record : null;
    } on Object {
      return null;
    }
  }

  final List<int> salt;
  final List<int> hash;
  final int iterations;

  /// Длина PIN: по ней экран ввода сам отправляет код (не секрет).
  final int pinLength;
  final LockTiming timing;
  final bool biometric;

  /// Неверные попытки подряд (сбрасываются успешным вводом).
  final int failures;

  /// Конец паузы (миллисекунды Unix), если она идёт.
  final int? pausedUntilMs;

  LockRecord copyWith({
    List<int>? salt,
    List<int>? hash,
    int? iterations,
    int? pinLength,
    LockTiming? timing,
    bool? biometric,
    int? failures,
    int? pausedUntilMs,
    bool clearPause = false,
  }) => LockRecord(
    salt: salt ?? this.salt,
    hash: hash ?? this.hash,
    iterations: iterations ?? this.iterations,
    pinLength: pinLength ?? this.pinLength,
    timing: timing ?? this.timing,
    biometric: biometric ?? this.biometric,
    failures: failures ?? this.failures,
    pausedUntilMs: clearPause ? null : (pausedUntilMs ?? this.pausedUntilMs),
  );

  String toJsonString() => jsonEncode({
    'v': 1,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'iter': iterations,
    'len': pinLength,
    'timing': timing.wire,
    'biometric': biometric,
    'failures': failures,
    'paused_until': pausedUntilMs,
  });
}

/// Итог проверки PIN.
@immutable
sealed class PinCheck {
  const PinCheck();
}

/// PIN верный.
class PinAccepted extends PinCheck {
  const PinAccepted();
}

/// PIN неверный; [attemptsLeft] — сколько попыток осталось до паузы.
class PinRejected extends PinCheck {
  const PinRejected({required this.attemptsLeft, this.pausedUntil});

  final int attemptsLeft;

  /// Если эта ошибка включила паузу — когда она кончится.
  final DateTime? pausedUntil;
}

/// Ввод заблокирован паузой, PIN даже не проверялся.
class PinPaused extends PinCheck {
  const PinPaused(this.until);

  final DateTime until;
}
