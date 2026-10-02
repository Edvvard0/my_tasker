/// Календарные даты без времени и таймзоны (spec Этапа 2, раздел 1).
///
/// «Дата» в этом модуле — `DateTime.utc(год, месяц, день)` в полночь: UTC
/// нужен только затем, чтобы арифметика по суткам не зависела от перехода
/// на летнее время устройства. Тип не несёт таймзоны и не переводится в
/// моменты без явной зоны (см. `wall_time.dart`).
library;

/// Допустимые годы дат и моментов (spec, раздел 1).
const int minYear = 1970;
const int maxYear = 2200;

/// Дата `DateTime.utc(y, m, d)` (нормализуется: `d = 32` -> 1-е следующего).
DateTime civil(int year, int month, int day) => DateTime.utc(year, month, day);

/// Отбрасывает время у любого [DateTime]: берёт его календарные поля как
/// есть (без пересчёта зоны).
DateTime dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime addDays(DateTime date, int days) =>
    DateTime.utc(date.year, date.month, date.day + days);

/// Число суток между датами ([to] - [from]).
int daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Понедельник недели с [date] (неделя всегда с понедельника, spec 5.1).
DateTime mondayOf(DateTime date) => addDays(date, -(date.weekday - 1));

/// День недели: понедельник = 0 … воскресенье = 6.
int weekdayIndex(DateTime date) => date.weekday - 1;

bool isLeapYear(int year) =>
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

int daysInMonth(int year, int month) => switch (month) {
  2 => isLeapYear(year) ? 29 : 28,
  4 || 6 || 9 || 11 => 30,
  _ => 31,
};

/// Прибавляет месяцы; число сжимается до конца месяца (31 янв -> 28 фев).
DateTime addMonthsClamped(DateTime date, int months) {
  final index = date.year * 12 + date.month - 1 + months;
  final year = index ~/ 12;
  final month = index % 12 + 1;
  final day = date.day <= daysInMonth(year, month)
      ? date.day
      : daysInMonth(year, month);
  return DateTime.utc(year, month, day);
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// `YYYY-MM-DD`.
String formatDate(DateTime date) =>
    '${_pad(date.year, 4)}-${_pad(date.month, 2)}-${_pad(date.day, 2)}';

/// `YYYYMMDD` (для `UNTIL` событий «весь день»).
String formatDateCompact(DateTime date) =>
    '${_pad(date.year, 4)}${_pad(date.month, 2)}${_pad(date.day, 2)}';

final RegExp _datePattern = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

/// `YYYY-MM-DD` -> дата; `null`, если строка не реальная дата 1970–2200.
DateTime? parseDate(String text) {
  if (!_datePattern.hasMatch(text)) return null;
  return _validated(
    int.parse(text.substring(0, 4)),
    int.parse(text.substring(5, 7)),
    int.parse(text.substring(8, 10)),
  );
}

DateTime? _validated(int year, int month, int day) {
  if (year < minYear || year > maxYear) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > daysInMonth(year, month)) return null;
  return DateTime.utc(year, month, day);
}

/// `YYYYMMDD` -> дата или `null`.
DateTime? parseDateCompact(String text) {
  if (!RegExp(r'^[0-9]{8}$').hasMatch(text)) return null;
  return _validated(
    int.parse(text.substring(0, 4)),
    int.parse(text.substring(4, 6)),
    int.parse(text.substring(6, 8)),
  );
}

final RegExp _instantPattern = RegExp(
  r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$',
);

/// `YYYY-MM-DDTHH:MM:SSZ` (целые секунды, UTC) -> момент или `null`.
DateTime? parseInstant(String text) {
  if (!_instantPattern.hasMatch(text)) return null;
  final date = _validated(
    int.parse(text.substring(0, 4)),
    int.parse(text.substring(5, 7)),
    int.parse(text.substring(8, 10)),
  );
  if (date == null) return null;
  return _withTime(
    date,
    int.parse(text.substring(11, 13)),
    int.parse(text.substring(14, 16)),
    int.parse(text.substring(17, 19)),
  );
}

/// `YYYYMMDDTHHMMSSZ` (форма `UNTIL`) -> момент или `null`.
DateTime? parseInstantCompact(String text) {
  if (!RegExp(r'^[0-9]{8}T[0-9]{6}Z$').hasMatch(text)) return null;
  final date = parseDateCompact(text.substring(0, 8));
  if (date == null) return null;
  return _withTime(
    date,
    int.parse(text.substring(9, 11)),
    int.parse(text.substring(11, 13)),
    int.parse(text.substring(13, 15)),
  );
}

DateTime? _withTime(DateTime date, int hour, int minute, int second) {
  if (hour > 23 || minute > 59 || second > 59) return null;
  return DateTime.utc(date.year, date.month, date.day, hour, minute, second);
}

/// `YYYY-MM-DDTHH:MM:SSZ` (без долей секунды).
String formatInstant(DateTime instant) {
  final u = instant.toUtc();
  return '${_pad(u.year, 4)}-${_pad(u.month, 2)}-${_pad(u.day, 2)}T'
      '${_pad(u.hour, 2)}:${_pad(u.minute, 2)}:${_pad(u.second, 2)}Z';
}

/// `YYYYMMDDTHHMMSSZ`.
String formatInstantCompact(DateTime instant) {
  final u = instant.toUtc();
  return '${_pad(u.year, 4)}${_pad(u.month, 2)}${_pad(u.day, 2)}T'
      '${_pad(u.hour, 2)}${_pad(u.minute, 2)}${_pad(u.second, 2)}Z';
}
