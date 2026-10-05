/// Денежные хелперы: сумма — целое число копеек (RUB), никаких `double`.
///
/// Поведение фиксируется общими тестовыми векторами
/// `shared-test-vectors/money/*.json`, одинаковыми для Python и Dart.
library;

/// Максимум по модулю: 999 999 999 999,99 ₽ в копейках.
const int maxKopecks = 99999999999999;

const int _maxRubleDigits = 12;

/// Пробельные символы, которые понимает парсер: U+0020, U+00A0, U+202F,
/// U+2009. Всё остальное (табуляция, перевод строки) пробелом не считается.
const Set<int> _spaces = {0x20, 0xA0, 0x202F, 0x2009};

/// Суффиксы валюты в порядке проверки (регистр не важен).
const List<String> _currencySuffixes = ['₽', 'руб.', 'руб', 'р.', 'р'];

final RegExp _amountPattern = RegExp(r'^(\+|-|−)?[0-9]+([.,][0-9]{1,2})?$');

bool _isSpace(int codeUnit) => _spaces.contains(codeUnit);

String _trimSpaces(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && _isSpace(s.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isSpace(s.codeUnitAt(end - 1))) {
    end--;
  }
  return s.substring(start, end);
}

/// Разбирает введённую сумму в копейки.
///
/// Принимает `1 234,56`, `1234.5`, `-500`, `12 руб.`, `1 000 ₽` и т. п.
/// Бросает [FormatException], если строка не соответствует правилам
/// (см. `shared-test-vectors/README.md`).
int parseAmount(String text) {
  var s = _trimSpaces(text);

  final lower = s.toLowerCase();
  for (final suffix in _currencySuffixes) {
    if (lower.endsWith(suffix)) {
      s = s.substring(0, s.length - suffix.length);
      break;
    }
  }

  final compact = String.fromCharCodes(s.codeUnits.where((c) => !_isSpace(c)));

  final match = _amountPattern.firstMatch(compact);
  if (match == null) {
    throw FormatException('Некорректная сумма', text);
  }

  var body = compact;
  var negative = false;
  final sign = match.group(1);
  if (sign != null) {
    negative = sign != '+';
    body = compact.substring(sign.length);
  }

  final separator = body.indexOf(RegExp('[.,]'));
  final whole = separator < 0 ? body : body.substring(0, separator);
  final fraction = separator < 0 ? '' : body.substring(separator + 1);

  if (whole.length > _maxRubleDigits) {
    throw FormatException('Слишком большая сумма', text);
  }

  final kopecks = int.parse(whole) * 100 + int.parse(fraction.padRight(2, '0'));
  return negative ? -kopecks : kopecks;
}

/// Как [parseAmount], но возвращает `null` вместо исключения.
int? tryParseAmount(String text) {
  try {
    return parseAmount(text);
  } on FormatException {
    return null;
  }
}

/// Как [formatAmount], но для суммы вне допустимого диапазона не бросает
/// исключение, а возвращает «≈ ∞» / «≈ -∞» (для интерфейса и контекста ИИ:
/// сумма счетов из синхронизированных данных может выйти за предел).
String formatAmountClamped(int kopecks) {
  if (kopecks.abs() > maxKopecks) return kopecks > 0 ? '≈ ∞' : '≈ -∞';
  return formatAmount(kopecks);
}

/// Форматирует копейки: `123456` -> `1 234,56 ₽` (разделители U+00A0),
/// копейки пишутся только если они не нулевые, минус — ASCII `-`.
String formatAmount(int kopecks) {
  if (kopecks.abs() > maxKopecks) {
    throw RangeError.range(kopecks, -maxKopecks, maxKopecks, 'kopecks');
  }

  final abs = kopecks.abs();
  final rubles = (abs ~/ 100).toString();
  final cents = abs % 100;

  final grouped = StringBuffer();
  for (var i = 0; i < rubles.length; i++) {
    if (i > 0 && (rubles.length - i) % 3 == 0) {
      grouped.write(' ');
    }
    grouped.write(rubles[i]);
  }

  final sign = kopecks < 0 ? '-' : '';
  final fraction = cents == 0 ? '' : ',${cents.toString().padLeft(2, '0')}';
  return '$sign$grouped$fraction ₽';
}
