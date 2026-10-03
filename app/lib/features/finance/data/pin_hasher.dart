import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Число итераций PBKDF2 в продакшене. PIN короткий, поэтому главная защита
/// от подбора — пауза после неверных попыток; соль и итерации лишь не дают
/// прочитать PIN из украденного хранилища «в лоб».
const int defaultPinIterations = 150000;

/// Длина соли и ключа в байтах.
const int pinSaltBytes = 16;
const int pinKeyBytes = 32;

/// PBKDF2 с HMAC-SHA256 (RFC 8018) на пакете `crypto`.
List<int> pbkdf2HmacSha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int length,
) {
  final hmac = Hmac(sha256, password);
  const blockLength = 32;
  final blocks = (length + blockLength - 1) ~/ blockLength;
  final out = <int>[];
  for (var i = 1; i <= blocks; i++) {
    var u = hmac.convert([
      ...salt,
      (i >> 24) & 0xff,
      (i >> 16) & 0xff,
      (i >> 8) & 0xff,
      i & 0xff,
    ]).bytes;
    final t = List<int>.of(u);
    for (var round = 1; round < iterations; round++) {
      u = hmac.convert(u).bytes;
      for (var k = 0; k < t.length; k++) {
        t[k] ^= u[k];
      }
    }
    out.addAll(t);
  }
  return out.sublist(0, length);
}

/// Сравнение за постоянное время (не выдаёт длину общего префикса).
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Случайная соль из криптостойкого генератора.
List<int> randomPinSalt(Random random) => [
  for (var i = 0; i < pinSaltBytes; i++) random.nextInt(256),
];

/// Выводит ключ из PIN. В приложении тяжёлый расчёт уходит в изолят, чтобы
/// не вешать интерфейс; тесты берут дешёвый вариант без изолята.
class PinHasher {
  const PinHasher({
    this.iterations = defaultPinIterations,
    this.useIsolate = true,
  });

  /// Итерации для новых записей (у старых — свои, они лежат в записи).
  final int iterations;
  final bool useIsolate;

  Future<List<int>> derive(String pin, List<int> salt, int iterations) {
    final password = utf8.encode(pin);
    if (!useIsolate) {
      return Future.value(
        pbkdf2HmacSha256(password, salt, iterations, pinKeyBytes),
      );
    }
    return Isolate.run(
      () => pbkdf2HmacSha256(password, salt, iterations, pinKeyBytes),
    );
  }
}
