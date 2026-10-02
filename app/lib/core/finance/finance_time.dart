/// Время Финансов (spec Этапа 5, раздел 0): хранение в UTC, «день», «месяц»
/// и границы периодов — по Москве (`Europe/Moscow` = UTC+3 без перехода на
/// летнее время с 2015-01-01): московская дата = дата момента + 3 часа.
///
/// Все расчёты идут в целых секундах Unix: доли секунды в моментах
/// отбрасываются до сравнения (как у `reference.py`).
library;

/// Сдвиг Москвы относительно UTC в секундах.
const int moscowOffsetSeconds = 3 * 3600;

/// Не раньше этого момента принимаются `occurred_at` и `checked_at`
/// (2015-01-01T00:00:00Z, секунды Unix) — spec 0 и 1.3.
const int financeEpochSeconds = 1420070400;

/// Тот же порог в виде строки момента.
const String financeEpoch = '2015-01-01T00:00:00Z';

const int _cacheLimit = 50000;
final Map<String, int> _secondsCache = {};

final RegExp _zone = RegExp(r'(Z|z|[+-]\d{2}(:?\d{2})?)$');

int _floorDiv(int a, int b) => (a / b).floor();

/// Момент `YYYY-MM-DDTHH:MM:SS[.дробь]Z` (или со смещением) -> секунды Unix;
/// доли секунды отбрасываются. Строка без зоны считается UTC.
/// [FormatException], если строка не разбирается.
int instantSeconds(String text) {
  final cached = _secondsCache[text];
  if (cached != null) return cached;
  final spaced = text.contains(' ') ? text.replaceFirst(' ', 'T') : text;
  final parsed = DateTime.parse(_zone.hasMatch(spaced) ? spaced : '${spaced}Z');
  final seconds = _floorDiv(parsed.toUtc().millisecondsSinceEpoch, 1000);
  if (_secondsCache.length >= _cacheLimit) _secondsCache.clear();
  _secondsCache[text] = seconds;
  return seconds;
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

DateTime _utc(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// Секунды Unix -> `YYYY-MM-DDTHH:MM:SSZ`.
String formatSeconds(int seconds) {
  final u = _utc(seconds);
  return '${_pad(u.year, 4)}-${_pad(u.month, 2)}-${_pad(u.day, 2)}T'
      '${_pad(u.hour, 2)}:${_pad(u.minute, 2)}:${_pad(u.second, 2)}Z';
}

/// Дата `YYYY-MM-DD` -> секунды Unix её полуночи UTC.
int _dayStartUtc(String day) =>
    _floorDiv(DateTime.parse('${day}T00:00:00Z').millisecondsSinceEpoch, 1000);

/// Первое мгновение московской даты в секундах Unix
/// (00:00 по UTC+3 = 21:00Z предыдущих суток).
int openingSeconds(String day) => _dayStartUtc(day) - moscowOffsetSeconds;

/// Последняя целая секунда московской даты (23:59:59 по UTC+3) в секундах.
int endOfDaySeconds(String day) => openingSeconds(day) + 86400 - 1;

/// `opening_instant`: первое мгновение московской даты строкой `…Z`.
String openingInstant(String day) => formatSeconds(openingSeconds(day));

/// `end_of_day`: последняя секунда московской даты строкой `…Z`.
String endOfDay(String day) => formatSeconds(endOfDaySeconds(day));

/// Последняя дата месяца `YYYY-MM`.
String monthEnd(String month) {
  final year = int.parse(month.substring(0, 4));
  final number = int.parse(month.substring(5, 7));
  final last = DateTime.utc(year, number + 1, 0);
  return '${_pad(last.year, 4)}-${_pad(last.month, 2)}-${_pad(last.day, 2)}';
}

/// Московская дата `YYYY-MM-DD` момента.
String moscowDate(String instant) =>
    moscowDateOfSeconds(instantSeconds(instant));

/// Московская дата для секунд Unix.
String moscowDateOfSeconds(int seconds) {
  final d = _utc(seconds + moscowOffsetSeconds);
  return '${_pad(d.year, 4)}-${_pad(d.month, 2)}-${_pad(d.day, 2)}';
}

/// Московский месяц `YYYY-MM` момента.
String moscowMonth(String instant) => moscowDate(instant).substring(0, 7);

/// [day] входит в период `{from, to}` (включительно; `null` в границе —
/// без ограничения; сам `period == null` — всё время).
bool inPeriod(String? day, Map<String, Object?>? period) {
  if (period == null) return true;
  if (day == null) return false;
  final first = period['from'] as String?;
  final last = period['to'] as String?;
  return (first == null || day.compareTo(first) >= 0) &&
      (last == null || day.compareTo(last) <= 0);
}
