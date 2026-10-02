import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/rule_dates.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:timezone/timezone.dart' as tz;

/// Частота в редакторе повторений.
enum RepeatFreq {
  none('Нет'),
  daily('Каждый день'),
  weekly('Неделя'),
  monthly('Месяц'),
  yearly('Год');

  const RepeatFreq(this.label);

  final String label;

  String? get wire => switch (this) {
    none => null,
    daily => 'DAILY',
    weekly => 'WEEKLY',
    monthly => 'MONTHLY',
    yearly => 'YEARLY',
  };
}

/// Как задан день в месячном повторении.
enum MonthMode {
  /// По числу месяца (`BYMONTHDAY=N` по дате начала).
  dayOfMonth('По числу'),

  /// По дню недели (`2TU`: второй вторник).
  nthWeekday('По дню недели'),

  /// Последний день месяца (`BYMONTHDAY=-1`).
  lastDay('Последний день');

  const MonthMode(this.label);

  final String label;
}

/// Окончание повторения.
enum RepeatEnd {
  never('Никогда'),
  until('До даты'),
  count('Число раз');

  const RepeatEnd(this.label);

  final String label;
}

/// Черновик правила повторения в редакторе. Превращается в тело RRULE
/// ([toRule]) и обратно ([RecurrenceDraft.fromRule]).
@immutable
class RecurrenceDraft {
  const RecurrenceDraft({
    this.freq = RepeatFreq.none,
    this.interval = 1,
    this.weekdays = const {},
    this.monthMode = MonthMode.dayOfMonth,
    this.end = RepeatEnd.never,
    this.untilDate,
    this.count = 10,
    this.cycleWeek,
  });

  /// Черновик по существующему правилу [rule] серии, начавшейся в [start].
  /// [cycle] нужен, чтобы распознать чередование недель.
  factory RecurrenceDraft.fromRule(
    RRule? rule, {
    required DateTime start,
    tz.Location? zone,
    WeekCycle? cycle,
  }) {
    if (rule == null) return none;
    final freq = switch (rule.freq) {
      'DAILY' => RepeatFreq.daily,
      'WEEKLY' => RepeatFreq.weekly,
      'MONTHLY' => RepeatFreq.monthly,
      _ => RepeatFreq.yearly,
    };
    var monthMode = MonthMode.dayOfMonth;
    if (freq == RepeatFreq.monthly) {
      if (rule.byDay.isNotEmpty) {
        monthMode = MonthMode.nthWeekday;
      } else if (rule.byMonthDay.length == 1 && rule.byMonthDay.first == -1) {
        monthMode = MonthMode.lastDay;
      }
    }
    var endKind = RepeatEnd.never;
    DateTime? until;
    if (rule.count != null) {
      endKind = RepeatEnd.count;
    } else if (rule.untilDate != null) {
      endKind = RepeatEnd.until;
      until = rule.untilDate;
    } else if (rule.untilUtc != null) {
      endKind = RepeatEnd.until;
      until = dateOnly(
        zone == null ? rule.untilUtc! : utcToWall(zone, rule.untilUtc!),
      );
    }
    int? cycleWeek;
    if (freq == RepeatFreq.weekly &&
        cycle != null &&
        cycle.isEnabled &&
        rule.interval == cycle.length) {
      cycleWeek = cycle.weekNumber(start);
    }
    return RecurrenceDraft(
      freq: freq,
      interval: rule.interval,
      weekdays: freq == RepeatFreq.weekly
          ? {for (final d in rule.byDay) d.weekday}
          : const {},
      monthMode: monthMode,
      end: endKind,
      untilDate: until,
      count: rule.count ?? 10,
      cycleWeek: cycleWeek,
    );
  }

  final RepeatFreq freq;
  final int interval;

  /// Дни недели (0 = пн) для еженедельного повторения; пусто — день начала.
  final Set<int> weekdays;
  final MonthMode monthMode;
  final RepeatEnd end;
  final DateTime? untilDate;
  final int count;

  /// Чередование: номер недели цикла (1…length) — серия идёт только в такие
  /// недели (`INTERVAL = length`). `null` — обычное повторение.
  final int? cycleWeek;

  bool get isNone => freq == RepeatFreq.none;

  RecurrenceDraft copyWith({
    RepeatFreq? freq,
    int? interval,
    Set<int>? weekdays,
    MonthMode? monthMode,
    RepeatEnd? end,
    Object? untilDate = _keep,
    int? count,
    Object? cycleWeek = _keep,
  }) => RecurrenceDraft(
    freq: freq ?? this.freq,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    monthMode: monthMode ?? this.monthMode,
    end: end ?? this.end,
    untilDate: identical(untilDate, _keep)
        ? this.untilDate
        : untilDate as DateTime?,
    count: count ?? this.count,
    cycleWeek: identical(cycleWeek, _keep) ? this.cycleWeek : cycleWeek as int?,
  );

  static const RecurrenceDraft none = RecurrenceDraft();

  /// Правило для серии, начинающейся `start` (дата первого экземпляра).
  /// `allDay` и `zone` определяют форму `UNTIL` (конец — конец локального
  /// дня).
  RRule? toRule({
    required DateTime start,
    required bool allDay,
    tz.Location? zone,
    WeekCycle? cycle,
  }) {
    if (isNone) return null;
    var byDay = <ByDay>[];
    var byMonthDay = <int>[];
    var rate = interval;
    switch (freq) {
      case RepeatFreq.weekly:
        final days = weekdays.toList()..sort();
        byDay = [for (final d in days) ByDay(d)];
        if (cycleWeek != null && cycle != null && cycle.isEnabled) {
          rate = cycle.length;
        }
      case RepeatFreq.monthly:
        switch (monthMode) {
          case MonthMode.dayOfMonth:
            break;
          case MonthMode.nthWeekday:
            final ordinal = (start.day - 1) ~/ 7 + 1;
            final isLast = start.day + 7 > daysInMonth(start.year, start.month);
            byDay = [
              ByDay(weekdayIndex(start), isLast && ordinal >= 4 ? -1 : ordinal),
            ];
          case MonthMode.lastDay:
            byMonthDay = [-1];
        }
      case RepeatFreq.none || RepeatFreq.daily || RepeatFreq.yearly:
        break;
    }
    DateTime? outUntilUtc;
    DateTime? outUntilDate;
    int? cnt;
    switch (end) {
      case RepeatEnd.never:
        break;
      case RepeatEnd.count:
        cnt = count;
      case RepeatEnd.until:
        final date = untilDate ?? start;
        if (allDay) {
          outUntilDate = date;
        } else {
          outUntilUtc = wallToUtc(
            zone ?? requireLocation('UTC'),
            date.year,
            date.month,
            date.day,
            23,
            59,
            59,
          );
        }
    }
    return RRule(
      freq: freq.wire!,
      interval: rate < 1 ? 1 : rate,
      count: cnt,
      untilUtc: outUntilUtc,
      untilDate: outUntilDate,
      byDay: byDay,
      byMonthDay: byMonthDay,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecurrenceDraft &&
      other.freq == freq &&
      other.interval == interval &&
      setEquals(other.weekdays, weekdays) &&
      other.monthMode == monthMode &&
      other.end == end &&
      other.untilDate == untilDate &&
      other.count == count &&
      other.cycleWeek == cycleWeek;

  @override
  int get hashCode => Object.hash(
    freq,
    interval,
    Object.hashAll(weekdays),
    monthMode,
    end,
    untilDate,
    count,
    cycleWeek,
  );
}

const Object _keep = Object();

/// Первая дата серии, подходящая под [rule], не раньше [start]: начало
/// серии обязано подходить под правило (spec 3.2).
DateTime firstMatchingDate(RRule rule, DateTime start) {
  for (final date in ruleDates(rule.copyWith(count: () => null), start)) {
    return date;
  }
  return dateOnly(start);
}

/// Текст правила для человека: «Каждый день», «По вторникам и четвергам»,
/// «По нечётным неделям, Вт», «Каждые 2 недели», «Ежемесячно, 2-й вторник».
String describeRule(RRule rule, {required DateTime start, WeekCycle? cycle}) {
  final buffer = StringBuffer();
  final n = rule.interval;
  switch (rule.freq) {
    case 'DAILY':
      buffer.write(
        n == 1
            ? 'Каждый день'
            : 'Каждые $n ${_plural(n, 'день', 'дня', 'дней')}',
      );
    case 'WEEKLY':
      final days = rule.byDay.isEmpty
          ? [weekdayIndex(start)]
          : ([for (final d in rule.byDay) d.weekday]..sort());
      final names = days.map((d) => weekdayShortNames[d]).join(', ');
      if (cycle != null && cycle.isEnabled && n == cycle.length) {
        final label = cycle.labelForDate(start).toLowerCase();
        buffer.write(
          cycle.length == 2
              ? 'По ${_genitivePlural(label)} неделям, $names'
              : '$label, $names',
        );
      } else if (n == 1) {
        buffer.write(
          days.length == 1 && rule.byDay.isEmpty
              ? 'Каждую неделю, $names'
              : 'Каждую неделю: $names',
        );
      } else {
        buffer.write(
          'Каждые $n ${_plural(n, 'неделю', 'недели', 'недель')}: $names',
        );
      }
    case 'MONTHLY':
      buffer.write(
        n == 1
            ? 'Ежемесячно'
            : 'Каждые $n ${_plural(n, 'месяц', 'месяца', 'месяцев')}',
      );
      if (rule.byDay.isNotEmpty) {
        final d = rule.byDay.first;
        final ord = d.ordinal == null
            ? ''
            : d.ordinal == -1
            ? 'последний '
            : '${d.ordinal}-й ';
        buffer.write(', $ord${weekdayShortNames[d.weekday]}');
      } else if (rule.byMonthDay.length == 1 && rule.byMonthDay.first == -1) {
        buffer.write(', последний день');
      } else if (rule.byMonthDay.isNotEmpty) {
        buffer.write(', ${rule.byMonthDay.join(', ')}-го');
      } else {
        buffer.write(', ${start.day}-го');
      }
    default:
      buffer.write(
        n == 1 ? 'Ежегодно' : 'Каждые $n ${_plural(n, 'год', 'года', 'лет')}',
      );
  }
  if (rule.count != null) {
    buffer.write(
      ', ${rule.count} ${_plural(rule.count!, 'раз', 'раза', 'раз')}',
    );
  } else if (rule.untilDate != null) {
    buffer.write(', до ${dayMonth(rule.untilDate!)}');
  } else if (rule.untilUtc != null) {
    buffer.write(', до ${dayMonth(dateOnly(rule.untilUtc!))}');
  }
  return buffer.toString();
}

String _genitivePlural(String label) => switch (label) {
  'нечётная' => 'нечётным',
  'чётная' => 'чётным',
  _ => label,
};

String _plural(int n, String one, String few, String many) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}
