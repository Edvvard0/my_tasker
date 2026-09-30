import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Пространство имён для `uuid5` идентификаторов `user_settings`
/// (`uuid5(NAMESPACE_URL, "urn:my-tasker:user_settings")`, spec 4.1).
const String userSettingsNamespace = '11fae5eb-de4a-5a92-88e3-5c86a8c454f4';

final Random _secureRandom = Random.secure();
int _lastMs = 0;
int _lastCounter = 0;

/// UUIDv7 (RFC 9562, строчная дефисная запись): 48 бит времени Unix в мс,
/// версия 7, 12-битный счётчик и 62 случайных бита.
///
/// Значения, созданные одним процессом, строго возрастают (счётчик в
/// `rand_a`, метод 1 из RFC 9562), поэтому сортировка по id = порядок
/// создания. [nowMs] и [random] нужны тестам.
String uuid7({int? nowMs, Random? random}) {
  final rng = random ?? _secureRandom;
  var ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  var counter = 0;
  if (random == null) {
    if (ms > _lastMs) {
      counter = rng.nextInt(0x800); // запас под приращения внутри миллисекунды
    } else {
      ms = _lastMs;
      counter = _lastCounter + 1;
      if (counter > 0xFFF) {
        ms += 1;
        counter = 0;
      }
    }
    _lastMs = ms;
    _lastCounter = counter;
  } else {
    counter = rng.nextInt(0x1000);
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xFF;
  }
  bytes[6] = 0x70 | ((counter >> 8) & 0x0F);
  bytes[7] = counter & 0xFF;
  for (var i = 8; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  return _format(bytes);
}

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Строчный дефисный uuid.
bool isUuid(String value) => _uuidPattern.hasMatch(value);

/// UUID версии 7 с вариантом RFC 4122.
bool isUuid7(String value) =>
    isUuid(value) && value[14] == '7' && '89ab'.contains(value[19]);

/// `uuid5(namespace, name)` (RFC 4122, SHA-1).
String uuid5(String namespace, String name) {
  if (!isUuid(namespace)) {
    throw ArgumentError.value(namespace, 'namespace', 'ожидается uuid');
  }
  final ns = _parse(namespace);
  final digest = sha1.convert([...ns, ...utf8.encode(name)]).bytes;
  final bytes = Uint8List.fromList(digest.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0F) | 0x50;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  return _format(bytes);
}

/// Идентификатор строки `user_settings` по ключу (spec 4.1).
String userSettingsId(String key) => uuid5(userSettingsNamespace, key);

Uint8List _parse(String uuid) {
  final hex = uuid.replaceAll('-', '');
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _format(Uint8List bytes) {
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
