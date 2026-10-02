import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';

/// Защита от бесконечных циклов: дальше этого года правило не разворачивается.
const int _horizonYear = maxYear + 2;

/// Настенные даты экземпляров правила по возрастанию (spec 5.3, шаг 1):
/// `FREQ`, `INTERVAL`, `BYDAY`, `BYMONTHDAY`, `COUNT`. Время суток и `UNTIL`
/// здесь не учитываются — это делает вызывающий.
///
/// [first] — дата первого экземпляра (начало серии). Если она не подходит
/// под `BYDAY`/`BYMONTHDAY`, первым считается ближайшая подходящая позже, а
/// самой [first] в результате нет (как у `python-dateutil`).
///
/// [hint] позволяет пропустить периоды до этой даты (для правил без
/// `COUNT`; при `COUNT` счёт всегда идёт с начала серии). Даты до [hint]
/// могут попасть в результат — потребитель их отфильтровывает.
Iterable<DateTime> ruleDates(
  RRule rule,
  DateTime first, {
  DateTime? hint,
}) sync* {
  final start = dateOnly(first);
  var period = 0;
  if (hint != null && rule.count == null) {
    period = _periodIndex(rule, start, dateOnly(hint));
  }
  var emitted = 0;
  while (true) {
    final bounds = _periodStart(rule, start, period);
    if (bounds.year > _horizonYear) return;
    for (final date in _candidates(rule, start, period)) {
      if (date.isBefore(start)) continue;
      yield date;
      emitted++;
      if (rule.count != null && emitted >= rule.count!) return;
    }
    period++;
  }
}

int _floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

int _periodIndex(RRule rule, DateTime first, DateTime hint) {
  final int raw;
  switch (rule.freq) {
    case 'DAILY':
      raw = daysBetween(first, hint);
    case 'WEEKLY':
      raw = _floorDiv(daysBetween(mondayOf(first), mondayOf(hint)), 7);
    case 'MONTHLY':
      raw = (hint.year - first.year) * 12 + hint.month - first.month;
    default:
      raw = hint.year - first.year;
  }
  final index = _floorDiv(raw, rule.interval);
  return index < 0 ? 0 : index;
}

/// Первый день периода (для проверки горизонта).
DateTime _periodStart(RRule rule, DateTime first, int period) {
  final step = period * rule.interval;
  switch (rule.freq) {
    case 'DAILY':
      return addDays(first, step);
    case 'WEEKLY':
      return addDays(mondayOf(first), 7 * step);
    case 'MONTHLY':
      final index = first.year * 12 + first.month - 1 + step;
      return DateTime.utc(index ~/ 12, index % 12 + 1);
    default:
      return DateTime.utc(first.year + step);
  }
}

List<DateTime> _candidates(RRule rule, DateTime first, int period) {
  final step = period * rule.interval;
  switch (rule.freq) {
    case 'DAILY':
      return [addDays(first, step)];
    case 'WEEKLY':
      final monday = addDays(mondayOf(first), 7 * step);
      final weekdays = rule.byDay.isEmpty
          ? [weekdayIndex(first)]
          : (rule.byDay.map((e) => e.weekday).toSet().toList()..sort());
      return [for (final w in weekdays) addDays(monday, w)];
    case 'MONTHLY':
      final index = first.year * 12 + first.month - 1 + step;
      return _monthDates(rule, first, index ~/ 12, index % 12 + 1);
    default:
      final year = first.year + step;
      if (first.day > daysInMonth(year, first.month)) return const [];
      return [DateTime.utc(year, first.month, first.day)];
  }
}

List<DateTime> _monthDates(RRule rule, DateTime first, int year, int month) {
  final total = daysInMonth(year, month);
  final days = <int>{};
  if (rule.byDay.isNotEmpty) {
    for (final entry in rule.byDay) {
      final matching = [
        for (var d = 1; d <= total; d++)
          if (DateTime.utc(year, month, d).weekday - 1 == entry.weekday) d,
      ];
      final ordinal = entry.ordinal;
      if (ordinal == null) {
        days.addAll(matching);
      } else {
        final index = ordinal > 0 ? ordinal - 1 : matching.length + ordinal;
        if (index >= 0 && index < matching.length) days.add(matching[index]);
      }
    }
  } else if (rule.byMonthDay.isNotEmpty) {
    for (final n in rule.byMonthDay) {
      final day = n > 0 ? n : total + n + 1;
      if (day >= 1 && day <= total) days.add(day);
    }
  } else if (first.day <= total) {
    days.add(first.day);
  }
  return [
    for (final d in (days.toList()..sort())) DateTime.utc(year, month, d),
  ];
}
