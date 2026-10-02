import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_draft.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);

RRule rule(String s, {bool allDay = true}) => RRule.parse(s, allDay: allDay);

void main() {
  ensureTimeZones();

  group('WeekCycle', () {
    final base = WeekCycle(length: 2, week1Start: d(2026, 9, 28));

    test('номера недель, включая даты до опоры', () {
      expect(base.weekNumber(d(2026, 9, 30)), 1);
      expect(base.weekNumber(d(2026, 10, 5)), 2);
      expect(base.weekNumber(d(2026, 9, 21)), 2);
      expect(base.weekNumber(d(2026, 9, 14)), 1);
      expect(base.weekNumber(d(2026, 9, 23)), 2);
    });

    test('сдвиг чётности действует с недели from', () {
      final shifted = base.withShift(
        WeekShift(from: d(2026, 10, 12), weeks: 1),
      );
      expect(shifted.weekNumber(d(2026, 10, 5)), 2);
      expect(shifted.weekNumber(d(2026, 10, 12)), 2);
      expect(shifted.weekNumber(d(2026, 10, 19)), 1);
    });

    test('firstDate находит нужную неделю', () {
      final date = base.firstDate(d(2026, 9, 30), 1, 2); // вторник чётной
      expect(date, d(2026, 10, 6));
      expect(base.firstDate(d(2026, 9, 29), 1, 1), d(2026, 9, 29));
    });

    test('подписи', () {
      expect(base.labelOf(1), 'Нечётная');
      expect(base.labelOf(2), 'Чётная');
      expect(base.labelForDate(d(2026, 10, 6)), 'Чётная');
      final three = WeekCycle(length: 3, week1Start: d(2026, 9, 28));
      expect(three.labelOf(3), 'Неделя 3');
      final custom = WeekCycle(
        length: 2,
        week1Start: d(2026, 9, 28),
        labels: const ['Числитель', 'Знаменатель'],
      );
      expect(custom.labelOf(2), 'Знаменатель');
      expect(WeekCycle(length: 1, week1Start: d(2026, 9, 28)).isEnabled, false);
    });

    test('JSON туда-обратно, равенство', () {
      final c = WeekCycle(
        length: 2,
        week1Start: d(2026, 9, 28),
        labels: const ['А', 'Б'],
        shifts: [WeekShift(from: d(2026, 10, 12), weeks: 1)],
      );
      final back = WeekCycle.tryParse(c.toJson());
      expect(back, c);
      expect(back.hashCode, c.hashCode);
      expect(back, isNot(base));
      expect(base.toJson().containsKey('labels'), isFalse);
    });

    test('tryParse отвергает неверные значения', () {
      const start = '2026-09-28';
      final bad = <Object?>[
        null,
        'x',
        {'length': 'a', 'week1_start': start},
        {'length': 0, 'week1_start': start},
        {'length': 9, 'week1_start': start},
        {'length': 2},
        {'length': 2, 'week1_start': 'нет'},
        {'length': 2, 'week1_start': start, 'labels': 'x'},
        {
          'length': 2,
          'week1_start': start,
          'labels': ['а'],
        },
        {
          'length': 2,
          'week1_start': start,
          'labels': ['а', ' '],
        },
        {
          'length': 2,
          'week1_start': start,
          'labels': ['а', 'б' * 31],
        },
        {
          'length': 2,
          'week1_start': start,
          'labels': [1, 2],
        },
        {'length': 2, 'week1_start': start, 'shifts': 'x'},
        {
          'length': 2,
          'week1_start': start,
          'shifts': ['x'],
        },
        {
          'length': 2,
          'week1_start': start,
          'shifts': [
            {'from': 1, 'weeks': 1},
          ],
        },
        {
          'length': 2,
          'week1_start': start,
          'shifts': [
            {'from': 'нет', 'weeks': 1},
          ],
        },
      ];
      for (final v in bad) {
        expect(WeekCycle.tryParse(v), isNull, reason: '$v');
      }
    });
  });

  group('RecurrenceDraft', () {
    final zone = requireLocation('Europe/Moscow');
    final cycle = WeekCycle(length: 2, week1Start: d(2026, 9, 28));

    test('none и равенство', () {
      expect(RecurrenceDraft.none.isNone, isTrue);
      expect(
        RecurrenceDraft.none.toRule(start: d(2026, 9, 30), allDay: true),
        isNull,
      );
      expect(
        RecurrenceDraft.fromRule(null, start: d(2026, 9, 30)).isNone,
        true,
      );
      const a = RecurrenceDraft(freq: RepeatFreq.daily);
      expect(a, const RecurrenceDraft(freq: RepeatFreq.daily));
      expect(
        a.hashCode,
        const RecurrenceDraft(freq: RepeatFreq.daily).hashCode,
      );
      expect(a.copyWith(untilDate: d(2026, 10, 1)).untilDate, d(2026, 10, 1));
      expect(a.copyWith(untilDate: null).untilDate, isNull);
      expect(a.copyWith(cycleWeek: 2).cycleWeek, 2);
      expect(RepeatFreq.weekly.wire, 'WEEKLY');
      expect(RepeatFreq.none.wire, isNull);
      expect(RepeatFreq.daily.label, isNotEmpty);
      expect(MonthMode.lastDay.label, isNotEmpty);
      expect(RepeatEnd.count.label, isNotEmpty);
    });

    test('toRule: недели, чередование, месяц, конец', () {
      final weekly = const RecurrenceDraft(
        freq: RepeatFreq.weekly,
        weekdays: {3, 1},
        cycleWeek: 2,
        end: RepeatEnd.count,
        count: 5,
      ).toRule(start: d(2026, 10, 6), allDay: false, zone: zone, cycle: cycle)!;
      expect(weekly.interval, 2);
      expect(weekly.byDay.map((e) => e.weekday), [1, 3]);
      expect(weekly.count, 5);

      final nth = const RecurrenceDraft(
        freq: RepeatFreq.monthly,
        monthMode: MonthMode.nthWeekday,
      ).toRule(start: d(2026, 10, 13), allDay: true)!;
      expect(nth.byDay.single.ordinal, 2);
      final last = const RecurrenceDraft(
        freq: RepeatFreq.monthly,
        monthMode: MonthMode.nthWeekday,
      ).toRule(start: d(2026, 10, 27), allDay: true)!;
      expect(last.byDay.single.ordinal, -1);
      final lastDay = const RecurrenceDraft(
        freq: RepeatFreq.monthly,
        monthMode: MonthMode.lastDay,
      ).toRule(start: d(2026, 10, 27), allDay: true)!;
      expect(lastDay.byMonthDay, [-1]);
      expect(
        const RecurrenceDraft(freq: RepeatFreq.monthly)
            .toRule(start: d(2026, 10, 27), allDay: true)!
            .byMonthDay,
        isEmpty,
      );

      final untilAllDay = RecurrenceDraft(
        freq: RepeatFreq.daily,
        end: RepeatEnd.until,
        untilDate: d(2026, 11, 1),
      ).toRule(start: d(2026, 10, 1), allDay: true)!;
      expect(untilAllDay.untilDate, d(2026, 11, 1));
      final untilTimed = const RecurrenceDraft(
        freq: RepeatFreq.daily,
        end: RepeatEnd.until,
      ).toRule(start: d(2026, 10, 1), allDay: false, zone: zone)!;
      expect(untilTimed.untilUtc, DateTime.utc(2026, 10, 1, 20, 59, 59));
      expect(
        const RecurrenceDraft(
          freq: RepeatFreq.daily,
          end: RepeatEnd.until,
        ).toRule(start: d(2026, 10, 1), allDay: false)!.untilUtc,
        DateTime.utc(2026, 10, 1, 23, 59, 59),
      );
      expect(
        const RecurrenceDraft(
          freq: RepeatFreq.daily,
          interval: 0,
        ).toRule(start: d(2026, 10, 1), allDay: true)!.interval,
        1,
      );
    });

    test('fromRule: все формы', () {
      final start = d(2026, 10, 6);
      final w = RecurrenceDraft.fromRule(
        rule('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=4'),
        start: start,
        cycle: cycle,
      );
      expect(w.freq, RepeatFreq.weekly);
      expect(w.weekdays, {1, 3});
      expect(w.cycleWeek, 2);
      expect(w.end, RepeatEnd.count);
      expect(w.count, 4);
      final plain = RecurrenceDraft.fromRule(
        rule('FREQ=WEEKLY;INTERVAL=2'),
        start: start,
      );
      expect(plain.cycleWeek, isNull);
      final m1 = RecurrenceDraft.fromRule(
        rule('FREQ=MONTHLY;BYDAY=2TU'),
        start: start,
      );
      expect(m1.monthMode, MonthMode.nthWeekday);
      final m2 = RecurrenceDraft.fromRule(
        rule('FREQ=MONTHLY;BYMONTHDAY=-1'),
        start: start,
      );
      expect(m2.monthMode, MonthMode.lastDay);
      expect(
        RecurrenceDraft.fromRule(rule('FREQ=YEARLY'), start: start).freq,
        RepeatFreq.yearly,
      );
      final untilDate = RecurrenceDraft.fromRule(
        rule('FREQ=DAILY;UNTIL=20261101'),
        start: start,
      );
      expect(untilDate.end, RepeatEnd.until);
      expect(untilDate.untilDate, d(2026, 11, 1));
      final untilUtc = rule('FREQ=DAILY;UNTIL=20261101T205959Z', allDay: false);
      expect(
        RecurrenceDraft.fromRule(untilUtc, start: start, zone: zone).untilDate,
        d(2026, 11, 1),
      );
      expect(
        RecurrenceDraft.fromRule(untilUtc, start: start).untilDate,
        d(2026, 11, 1),
      );
    });

    test('firstMatchingDate', () {
      expect(
        firstMatchingDate(rule('FREQ=WEEKLY;BYDAY=FR'), d(2026, 9, 30)),
        d(2026, 10, 2),
      );
    });

    test('describeRule', () {
      final s = d(2026, 10, 6);
      String desc(String r, {WeekCycle? c}) =>
          describeRule(rule(r), start: s, cycle: c);
      expect(desc('FREQ=DAILY'), 'Каждый день');
      expect(desc('FREQ=DAILY;INTERVAL=3'), 'Каждые 3 дня');
      expect(desc('FREQ=DAILY;INTERVAL=5'), 'Каждые 5 дней');
      expect(desc('FREQ=DAILY;INTERVAL=11'), 'Каждые 11 дней');
      expect(desc('FREQ=WEEKLY'), 'Каждую неделю, Вт');
      expect(desc('FREQ=WEEKLY;BYDAY=TU,TH'), startsWith('Каждую неделю: '));
      expect(
        desc('FREQ=WEEKLY;INTERVAL=3;BYDAY=MO'),
        startsWith('Каждые 3 недели'),
      );
      expect(
        desc('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU', c: cycle),
        contains('чётным'),
      );
      expect(
        desc(
          'FREQ=WEEKLY;INTERVAL=3;BYDAY=TU',
          c: WeekCycle(length: 3, week1Start: d(2026, 9, 28)),
        ),
        contains('неделя'),
      );
      expect(
        desc(
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
          c: WeekCycle(length: 2, week1Start: d(2026, 9, 28)),
        ),
        contains('чётным'),
      );
      expect(desc('FREQ=MONTHLY'), 'Ежемесячно, 6-го');
      expect(
        desc('FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=1,15'),
        contains('1, 15-го'),
      );
      expect(desc('FREQ=MONTHLY;BYDAY=2TU'), 'Ежемесячно, 2-й Вт');
      expect(desc('FREQ=MONTHLY;BYDAY=-1FR'), contains('последний '));
      expect(desc('FREQ=MONTHLY;BYDAY=FR'), 'Ежемесячно, Пт');
      expect(desc('FREQ=MONTHLY;BYMONTHDAY=-1'), 'Ежемесячно, последний день');
      expect(desc('FREQ=MONTHLY;INTERVAL=5'), contains('5 месяцев'));
      expect(desc('FREQ=YEARLY'), 'Ежегодно');
      expect(desc('FREQ=YEARLY;INTERVAL=2'), 'Каждые 2 года');
      expect(desc('FREQ=DAILY;COUNT=3'), 'Каждый день, 3 раза');
      expect(desc('FREQ=DAILY;UNTIL=20261101'), 'Каждый день, до 1 ноября');
      expect(
        describeRule(
          rule('FREQ=DAILY;UNTIL=20261101T205959Z', allDay: false),
          start: s,
        ),
        'Каждый день, до 1 ноября',
      );
    });
  });

  group('ru_dates', () {
    test('форматы', () {
      final day = d(2026, 9, 30);
      expect(clockText(9, 5), '09:05');
      expect(timeOf(DateTime.utc(2026, 1, 1, 14, 30)), '14:30');
      expect(dayTitle(day), 'Ср, 30 сентября');
      expect(dayTitleShort(day), 'Ср, 30 сент.');
      expect(dayMonth(day), '30 сентября');
      expect(dayMonth(day, now: d(2027, 1, 1)), '30 сентября 2026');
      expect(monthYear(day), 'Сентябрь 2026');
      expect(monthTitle(day, d(2026, 1, 1)), 'Сентябрь');
      expect(monthTitle(day, d(2027, 1, 1)), 'Сентябрь 2026');
      expect(weekRange(d(2026, 9, 28)), '28 сент. – 4 окт.');
      expect(weekRange(d(2026, 10, 5)), '5 – 11 окт.');
      expect(durationText(45), '45 мин');
      expect(durationText(120), '2 ч');
      expect(durationText(90), '1 ч 30 мин');
      final today = d(2026, 9, 30);
      expect(relativeDay(today, today), 'Сегодня');
      expect(relativeDay(d(2026, 10, 1), today), 'Завтра');
      expect(relativeDay(d(2026, 9, 29), today), 'Вчера');
      expect(relativeDay(d(2026, 9, 27), today), '3 дня назад');
      expect(relativeDay(d(2026, 10, 5), today), 'через 5 дней');
      expect(relativeDay(d(2026, 10, 31), today), 'через 31 день');
    });
  });
}
