import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';

/// Правило вне поддерживаемого подмножества RFC 5545 (spec 5.1).
class RRuleError extends FormatException {
  const RRuleError(super.message);
}

/// Дни недели в порядке индекса: понедельник = 0.
const List<String> weekdayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

const List<String> rruleFrequencies = ['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'];

const int rruleMaxLength = 200;
const int rruleMaxCount = 1000;

final RegExp _interval = RegExp(r'^[1-9][0-9]{0,2}$');
final RegExp _count = RegExp(r'^[1-9][0-9]{0,3}$');
final RegExp _byDayMonthly = RegExp(r'^(-?[1-5])?(MO|TU|WE|TH|FR|SA|SU)$');
final RegExp _byDayWeekly = RegExp(r'^(MO|TU|WE|TH|FR|SA|SU)$');
final RegExp _byMonthDay = RegExp(r'^-?([1-9]|[12][0-9]|3[01])$');
final RegExp _part = RegExp(r'^([A-Z]+)=([A-Za-z0-9,+-]+)$');

/// Элемент `BYDAY`: день недели (0 = пн) и порядковый номер в месяце
/// (`2TU` -> 2, `-1FR` -> -1; `null` — «каждый такой день»).
@immutable
class ByDay {
  const ByDay(this.weekday, [this.ordinal]);

  final int weekday;
  final int? ordinal;

  @override
  bool operator ==(Object other) =>
      other is ByDay && other.weekday == weekday && other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(weekday, ordinal);

  @override
  String toString() => '${ordinal ?? ''}${weekdayCodes[weekday]}';
}

/// Правило повторения из подмножества spec 5.1: только тело правила
/// (`FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;UNTIL=20261231T210000Z`), без `RRULE:`,
/// `DTSTART`, `EXDATE`, `WKST`. Неделя — всегда с понедельника.
@immutable
class RRule {
  const RRule({
    required this.freq,
    this.interval = 1,
    this.count,
    this.untilUtc,
    this.untilDate,
    this.byDay = const [],
    this.byMonthDay = const [],
  });

  /// Разбирает [text]; [RRuleError], если правило вне подмножества.
  /// [allDay] выбирает форму `UNTIL` (дата или момент).
  factory RRule.parse(String text, {required bool allDay}) {
    if (text.isEmpty || text.length > rruleMaxLength) {
      throw const RRuleError('правило пустое или слишком длинное');
    }
    final parts = <String, String>{};
    for (final chunk in text.split(';')) {
      final match = _part.firstMatch(chunk);
      if (match == null) throw RRuleError('часть «$chunk» не разобрана');
      final name = match.group(1)!;
      if (parts.containsKey(name)) throw RRuleError('$name указан дважды');
      parts[name] = match.group(2)!;
    }
    const known = {'FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'BYDAY', 'BYMONTHDAY'};
    final unknown = parts.keys.where((k) => !known.contains(k)).toList()
      ..sort();
    if (unknown.isNotEmpty) {
      throw RRuleError('не поддерживается: ${unknown.join(', ')}');
    }
    final freq = parts['FREQ'];
    if (freq == null || !rruleFrequencies.contains(freq)) {
      throw const RRuleError('FREQ: DAILY, WEEKLY, MONTHLY или YEARLY');
    }
    var interval = 1;
    if (parts.containsKey('INTERVAL')) {
      if (!_interval.hasMatch(parts['INTERVAL']!)) {
        throw const RRuleError('INTERVAL: 1…999');
      }
      interval = int.parse(parts['INTERVAL']!);
    }
    if (parts.containsKey('COUNT') && parts.containsKey('UNTIL')) {
      throw const RRuleError('COUNT и UNTIL взаимоисключающие');
    }
    int? count;
    if (parts.containsKey('COUNT')) {
      final value = parts['COUNT']!;
      if (!_count.hasMatch(value) || int.parse(value) > rruleMaxCount) {
        throw const RRuleError('COUNT: 1…$rruleMaxCount');
      }
      count = int.parse(value);
    }
    DateTime? untilUtc;
    DateTime? untilDate;
    if (parts.containsKey('UNTIL')) {
      final value = parts['UNTIL']!;
      if (allDay) {
        untilDate = parseDateCompact(value);
        if (untilDate == null) {
          throw const RRuleError('UNTIL «весь день»: YYYYMMDD');
        }
      } else {
        untilUtc = parseInstantCompact(value);
        if (untilUtc == null) {
          throw const RRuleError('UNTIL: YYYYMMDDTHHMMSSZ');
        }
      }
    }
    if (parts.containsKey('BYDAY') && parts.containsKey('BYMONTHDAY')) {
      throw const RRuleError('BYDAY и BYMONTHDAY не сочетаются');
    }
    final byDay = parts.containsKey('BYDAY')
        ? _parseByDay(parts['BYDAY']!, freq)
        : const <ByDay>[];
    final byMonthDay = parts.containsKey('BYMONTHDAY')
        ? _parseByMonthDay(parts['BYMONTHDAY']!, freq)
        : const <int>[];
    return RRule(
      freq: freq,
      interval: interval,
      count: count,
      untilUtc: untilUtc,
      untilDate: untilDate,
      byDay: byDay,
      byMonthDay: byMonthDay,
    );
  }

  final String freq;
  final int interval;
  final int? count;

  /// `UNTIL` события с временем: момент UTC, включительно.
  final DateTime? untilUtc;

  /// `UNTIL` события «весь день»: локальная дата, включительно.
  final DateTime? untilDate;
  final List<ByDay> byDay;
  final List<int> byMonthDay;

  bool get hasUntil => untilUtc != null || untilDate != null;

  static List<ByDay> _parseByDay(String value, String freq) {
    if (freq != 'WEEKLY' && freq != 'MONTHLY') {
      throw const RRuleError('BYDAY только для WEEKLY и MONTHLY');
    }
    final items = value.split(',');
    if (items.length > 14) throw const RRuleError('BYDAY: слишком много');
    final result = <ByDay>[];
    for (final item in items) {
      final ByDay entry;
      if (freq == 'MONTHLY') {
        final match = _byDayMonthly.firstMatch(item);
        if (match == null) throw RRuleError('BYDAY «$item» не поддерживается');
        final ordinal = match.group(1);
        entry = ByDay(
          weekdayCodes.indexOf(match.group(2)!),
          ordinal == null ? null : int.parse(ordinal),
        );
      } else {
        if (!_byDayWeekly.hasMatch(item)) {
          throw RRuleError('BYDAY «$item» не поддерживается');
        }
        entry = ByDay(weekdayCodes.indexOf(item));
      }
      if (result.contains(entry)) throw const RRuleError('BYDAY: повтор');
      result.add(entry);
    }
    return result;
  }

  static List<int> _parseByMonthDay(String value, String freq) {
    if (freq != 'MONTHLY') {
      throw const RRuleError('BYMONTHDAY только для MONTHLY');
    }
    final result = <int>[];
    for (final item in value.split(',')) {
      if (!_byMonthDay.hasMatch(item)) {
        throw RRuleError('BYMONTHDAY «$item» вне диапазона');
      }
      final number = int.parse(item);
      if (result.contains(number)) {
        throw const RRuleError('BYMONTHDAY: повтор');
      }
      result.add(number);
    }
    return result;
  }

  /// Сообщение об ошибке или `null`, если правило допустимо.
  static String? problem(String text, {required bool allDay}) {
    try {
      RRule.parse(text, allDay: allDay);
    } on RRuleError catch (e) {
      return e.message;
    }
    return null;
  }

  /// Тело правила в каноническом порядке частей.
  String toRuleString() {
    final parts = ['FREQ=$freq'];
    if (interval != 1) parts.add('INTERVAL=$interval');
    if (count != null) parts.add('COUNT=$count');
    if (untilUtc != null) parts.add('UNTIL=${formatInstantCompact(untilUtc!)}');
    if (untilDate != null) {
      parts.add('UNTIL=${formatDateCompact(untilDate!)}');
    }
    if (byDay.isNotEmpty) parts.add('BYDAY=${byDay.join(',')}');
    if (byMonthDay.isNotEmpty) parts.add('BYMONTHDAY=${byMonthDay.join(',')}');
    return parts.join(';');
  }

  @override
  String toString() => toRuleString();

  RRule copyWith({
    String? freq,
    int? interval,
    int? Function()? count,
    DateTime? Function()? untilUtc,
    DateTime? Function()? untilDate,
    List<ByDay>? byDay,
    List<int>? byMonthDay,
  }) => RRule(
    freq: freq ?? this.freq,
    interval: interval ?? this.interval,
    count: count != null ? count() : this.count,
    untilUtc: untilUtc != null ? untilUtc() : this.untilUtc,
    untilDate: untilDate != null ? untilDate() : this.untilDate,
    byDay: byDay ?? this.byDay,
    byMonthDay: byMonthDay ?? this.byMonthDay,
  );

  /// Правило без `UNTIL`/`COUNT` (для новой серии при разрезе).
  RRule withoutEnd() =>
      copyWith(count: () => null, untilUtc: () => null, untilDate: () => null);
}
