import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/rule_dates.dart';
import 'package:timezone/timezone.dart' as tz;

/// Серия событий или задач: начало первого экземпляра, длительность,
/// правило и таймзона (spec 5.2–5.3).
///
/// Для события «с временем» [start] и [end] — моменты UTC, повторения
/// считаются в настенном времени [location]. Для «весь день» — даты
/// (полночь UTC, [end] включительно), таймзоны нет.
@immutable
class SeriesDefinition {
  const SeriesDefinition._({
    required this.allDay,
    required this.start,
    required this.end,
    required this.location,
    required this.rule,
  });

  /// Серия с временем: [startUtc], [endUtc] — моменты UTC.
  factory SeriesDefinition.timed({
    required tz.Location location,
    required DateTime startUtc,
    required DateTime endUtc,
    RRule? rule,
  }) => SeriesDefinition._(
    allDay: false,
    start: startUtc.toUtc(),
    end: endUtc.toUtc(),
    location: location,
    rule: rule,
  );

  /// Серия «весь день»: [startDate], [endDate] — даты, конец включительно.
  factory SeriesDefinition.allDay({
    required DateTime startDate,
    required DateTime endDate,
    RRule? rule,
  }) => SeriesDefinition._(
    allDay: true,
    start: dateOnly(startDate),
    end: dateOnly(endDate),
    location: null,
    rule: rule,
  );

  final bool allDay;
  final DateTime start;
  final DateTime end;
  final tz.Location? location;
  final RRule? rule;

  Duration get _duration => end.difference(start);
  int get _spanDays => daysBetween(start, end);

  /// Ключ экземпляра `original_start` для настенной даты [date]
  /// (spec 5.2: момент UTC после применения 1.1 или дата).
  String keyOfDate(DateTime date) =>
      allDay ? formatDate(date) : formatInstant(_instantOfDate(dateOnly(date)));

  DateTime _instantOfDate(DateTime date) {
    final wall = utcToWall(location!, start);
    return wallToUtc(
      location!,
      date.year,
      date.month,
      date.day,
      wall.hour,
      wall.minute,
      wall.second,
    );
  }

  /// Настенная дата, на которую приходится начало экземпляра [key].
  DateTime? dateOfKey(String key) {
    if (allDay) return parseDate(key);
    final instant = parseInstant(key);
    return instant == null ? null : dateOnly(utcToWall(location!, instant));
  }

  /// Исходные экземпляры по возрастанию: (ключ, начало, конец).
  /// [hint] — дата, раньше которой можно пропустить период (правила без
  /// `COUNT`).
  Iterable<({String key, DateTime start, DateTime end})> originals({
    DateTime? hint,
  }) sync* {
    final firstDate = allDay ? start : dateOnly(utcToWall(location!, start));
    final rule = this.rule;
    if (rule == null) {
      yield _span(firstDate);
      return;
    }
    for (final date in ruleDates(rule, firstDate, hint: hint)) {
      if (allDay) {
        if (rule.untilDate != null && date.isAfter(rule.untilDate!)) return;
      } else {
        final instant = _instantOfDate(date);
        if (rule.untilUtc != null && instant.isAfter(rule.untilUtc!)) return;
      }
      yield _span(date);
    }
  }

  /// Исходный слот экземпляра с ключом [key] (начало и конец до
  /// переопределений) или `null`, если такого экземпляра нет.
  ({DateTime start, DateTime end})? slotOf(String key) {
    final date = dateOfKey(key);
    if (date == null) return null;
    for (final o in originals(hint: addDays(date, -1))) {
      final c = o.key.compareTo(key);
      if (c == 0) return (start: o.start, end: o.end);
      if (c > 0) return null;
    }
    return null;
  }

  ({String key, DateTime start, DateTime end}) _span(DateTime date) {
    if (allDay) {
      return (
        key: formatDate(date),
        start: date,
        end: addDays(date, _spanDays),
      );
    }
    final instant = _instantOfDate(date);
    return (
      key: formatInstant(instant),
      start: instant,
      end: instant.add(_duration),
    );
  }
}

/// Переопределение одного экземпляра (`event_overrides`, кроме отмены).
@immutable
class InstanceOverride {
  const InstanceOverride({this.title, this.start, this.end});

  /// `null` — как в серии.
  final String? title;

  /// Новое время экземпляра; [start] и [end] заданы оба или ни одного.
  final DateTime? start;
  final DateTime? end;
}

/// Развёрнутый экземпляр серии.
@immutable
class Occurrence {
  const Occurrence({
    required this.key,
    required this.start,
    required this.end,
    required this.title,
    required this.allDay,
    this.overridden = false,
  });

  /// `original_start` (ключ экземпляра).
  final String key;
  final DateTime start;
  final DateTime end;
  final String title;
  final bool allDay;

  /// Есть переопределение этого экземпляра.
  final bool overridden;
}

/// Пересекает ли отрезок окно `[from, to)` (spec 5.3, «Пересечение окна»).
bool overlapsWindow(
  DateTime start,
  DateTime end,
  DateTime from,
  DateTime to, {
  required bool allDay,
}) {
  if (allDay) {
    return start.isBefore(to) && addDays(end, 1).isAfter(from);
  }
  if (end == start) return !start.isBefore(from) && start.isBefore(to);
  return start.isBefore(to) && end.isAfter(from);
}

/// Экземпляры серии, пересекающие окно `[from, to)`, по возрастанию
/// `(start, key)` — нормативный алгоритм spec 5.3.
///
/// [cancelled] — `original_start` отменённых экземпляров (они всё равно
/// входят в счёт `COUNT`), [overrides] — переопределения по ключу.
/// Переопределения несуществующих экземпляров игнорируются; при
/// совпадении ключей побеждает отмена.
List<Occurrence> expandSeries(
  SeriesDefinition series, {
  required DateTime from,
  required DateTime to,
  String title = '',
  Set<String> cancelled = const {},
  Map<String, InstanceOverride> overrides = const {},
}) {
  final live = {
    for (final e in overrides.entries)
      if (!cancelled.contains(e.key)) e.key: e.value,
  };
  final allDay = series.allDay;
  final lastOverrideKey = live.keys.isEmpty
      ? null
      : (live.keys.toList()..sort()).last;

  // С какой даты начинать перебор (для правил без COUNT).
  DateTime hint;
  if (allDay) {
    hint = addDays(from, -series._spanDays - 1);
  } else {
    final lead = series._duration + const Duration(days: 2);
    hint = dateOnly(utcToWall(series.location!, from.subtract(lead)));
  }
  for (final key in live.keys) {
    final date = series.dateOfKey(key);
    if (date != null && date.isBefore(hint)) hint = addDays(date, -1);
  }

  final found = <String, Occurrence>{};
  final validOverrides = <String, ({DateTime start, DateTime end})>{};
  for (final original in series.originals(hint: hint)) {
    final key = original.key;
    final pastWindow = !original.start.isBefore(to);
    if (pastWindow &&
        (lastOverrideKey == null || key.compareTo(lastOverrideKey) >= 0)) {
      break;
    }
    if (live.containsKey(key)) {
      validOverrides[key] = (start: original.start, end: original.end);
      continue;
    }
    if (pastWindow || cancelled.contains(key)) continue;
    if (overlapsWindow(
      original.start,
      original.end,
      from,
      to,
      allDay: allDay,
    )) {
      found[key] = Occurrence(
        key: key,
        start: original.start,
        end: original.end,
        title: title,
        allDay: allDay,
      );
    }
  }
  for (final entry in validOverrides.entries) {
    final override = live[entry.key]!;
    final start = override.start ?? entry.value.start;
    final end = override.end ?? entry.value.end;
    if (overlapsWindow(start, end, from, to, allDay: allDay)) {
      final overrideTitle = override.title;
      found[entry.key] = Occurrence(
        key: entry.key,
        start: start,
        end: end,
        title: overrideTitle == null || overrideTitle.isEmpty
            ? title
            : overrideTitle,
        allDay: allDay,
        overridden: true,
      );
    }
  }
  final result = found.values.toList()
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.key.compareTo(b.key);
    });
  return result;
}
