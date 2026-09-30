import 'dart:convert';

/// Проверки значений колонок до отправки (spec 4, «Значения»;
/// `shared-test-vectors/sync/validation.json`). Сервер проверяет то же и
/// отклоняет операцию с `invalid_field`, а не всю пачку.

/// Максимальная вложенность JSON-значения.
const int maxJsonDepth = 64;

/// В строке нет NUL и непарных суррогатов UTF-16.
bool isStorableText(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u == 0) return false;
    if (u >= 0xD800 && u <= 0xDBFF) {
      final paired =
          i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF;
      if (!paired) return false;
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return false;
    }
  }
  return true;
}

/// JSON-значение допустимо: строки и ключи без NUL и непарных суррогатов,
/// вложенность не глубже [maxJsonDepth], только типы JSON.
bool isStorableJson(Object? value, {int depth = 1}) {
  if (depth > maxJsonDepth + 1) return false;
  switch (value) {
    case null || bool() || num():
      return true;
    case final String s:
      return isStorableText(s);
    case final List<Object?> list:
      if (depth > maxJsonDepth) return false;
      return list.every((e) => isStorableJson(e, depth: depth + 1));
    case final Map<Object?, Object?> map:
      if (depth > maxJsonDepth) return false;
      return map.entries.every(
        (e) =>
            e.key is String &&
            isStorableText(e.key! as String) &&
            isStorableJson(e.value, depth: depth + 1),
      );
    default:
      return false;
  }
}

final RegExp _isoWithZone = RegExp(
  r'^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|z|[+-]\d{2}:\d{2})$',
);

/// ISO 8601 со смещением -> строка UTC (`...Z`); `null`, если значение не
/// разбирается, без часового пояса или вне диапазона [1970, 2200).
String? normalizeDatetime(String value) {
  if (!_isoWithZone.hasMatch(value)) return null;
  final DateTime parsed;
  try {
    parsed = DateTime.parse(value);
  } on FormatException {
    return null;
  }
  final utc = parsed.toUtc();
  if (utc.year < 1970 || utc.year >= 2200) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  final micro = utc.millisecond * 1000 + utc.microsecond;
  final fraction = micro == 0 ? '' : '.${micro.toString().padLeft(6, '0')}';
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}$fraction'
      'Z';
}

/// Для отладки: сериализованный размер значения в байтах.
int jsonByteLength(Object? value) => utf8.encode(jsonEncode(value)).length;
