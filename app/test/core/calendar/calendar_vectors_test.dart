import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/quick_input/quick_input_parser.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';

import '../../support/vectors.dart';

Map<String, Object?> _map(Object? v) => (v! as Map).cast<String, Object?>();

/// Общие векторы домена `calendar` (`shared-test-vectors/calendar/*.json`):
/// каждый случай читается с диска, файлы не копируются в код.
void main() {
  ensureTimeZones();

  test('все файлы векторов домена calendar покрыты тестами', () {
    expect(vectorFiles('calendar'), [
      'holidays.json',
      'ids.json',
      'quick_input.json',
      'rrule_expand.json',
      'rrule_validate.json',
      'week_cycle.json',
    ]);
  });

  group('быстрый ввод', () {
    final cases = loadVectors('calendar', 'quick_input.json');
    test('векторов не меньше 100', () => expect(cases.length >= 100, isTrue));
    for (final c in cases) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final now = DateTime.parse(input['now']! as String);
        final result = parseQuickInput(input['text']! as String, now);
        expect(result.toJson(), _map(c['expected']));
      });
    }
  });

  group('RRULE: допустимость', () {
    for (final c in loadVectors('calendar', 'rrule_validate.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final expected = _map(c['expected'])['valid']! as bool;
        final problem = RRule.problem(
          input['rrule']! as String,
          allDay: input['all_day']! as bool,
        );
        expect(problem == null, expected, reason: '$problem');
      });
    }
  });

  group('RRULE: развёртка', () {
    for (final c in loadVectors('calendar', 'rrule_expand.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final allDay = input['all_day']! as bool;
        DateTime point(String s) => allDay ? parseDate(s)! : parseInstant(s)!;
        String show(DateTime d) => allDay ? formatDate(d) : formatInstant(d);
        final rrule = input['rrule'] as String?;
        final rule = rrule == null ? null : RRule.parse(rrule, allDay: allDay);
        final series = allDay
            ? SeriesDefinition.allDay(
                startDate: parseDate(input['start']! as String)!,
                endDate: parseDate(input['end']! as String)!,
                rule: rule,
              )
            : SeriesDefinition.timed(
                location: requireLocation(input['tz']! as String),
                startUtc: parseInstant(input['start']! as String)!,
                endUtc: parseInstant(input['end']! as String)!,
                rule: rule,
              );
        final overrides = <String, InstanceOverride>{
          for (final o
              in (input['overrides']! as List).cast<Map<String, Object?>>())
            o['original_start']! as String: InstanceOverride(
              title: o['title'] as String?,
              start: o['start'] == null ? null : point(o['start']! as String),
              end: o['end'] == null ? null : point(o['end']! as String),
            ),
        };
        final window = _map(input['window']);
        final result = expandSeries(
          series,
          from: point(window['from']! as String),
          to: point(window['to']! as String),
          title: input['title']! as String,
          cancelled: {...(input['cancelled']! as List).cast<String>()},
          overrides: overrides,
        );
        expect([
          for (final o in result)
            {
              'original_start': o.key,
              'start': show(o.start),
              'end': show(o.end),
              'title': o.title,
            },
        ], (c['expected']! as List).cast<Map<String, Object?>>());
      });
    }
  });

  group('цикл недель', () {
    for (final c in loadVectors('calendar', 'week_cycle.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final cycle = WeekCycle(
          length: input['length']! as int,
          week1Start: parseDate(input['week1_start']! as String)!,
          shifts: [
            for (final s
                in ((input['shifts'] ?? const <Object?>[]) as List)
                    .cast<Map<String, Object?>>())
              WeekShift(
                from: parseDate(s['from']! as String)!,
                weeks: s['weeks']! as int,
              ),
          ],
        );
        switch (input['op']) {
          case 'week_number':
            final date = parseDate(input['date']! as String)!;
            expect(_map(c['expected']), {
              'monday': formatDate(mondayOf(date)),
              'week_number': cycle.weekNumber(date),
            });
          case 'first_date':
            expect(
              formatDate(
                cycle.firstDate(
                  parseDate(input['after']! as String)!,
                  input['weekday']! as int,
                  input['week']! as int,
                ),
              ),
              c['expected'],
            );
          default:
            fail('неизвестная операция ${input['op']}');
        }
      });
    }
  });

  group('праздники РФ', () {
    final calendar = HolidayCalendar.fromJsonString(
      File('../shared-data/calendar/holidays_ru.json').readAsStringSync(),
    );
    for (final c in loadVectors('calendar', 'holidays.json')) {
      test(c['name']! as String, () {
        final info = calendar.dayInfo(parseDate(c['input']! as String)!);
        expect({
          'is_day_off': info.isDayOff,
          'name': info.name,
        }, _map(c['expected']));
      });
    }
  });

  group('детерминированные id', () {
    for (final c in loadVectors('calendar', 'ids.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = switch (input['kind']) {
          'system_calendar' => systemCalendarId(input['system_key']! as String),
          'tag' => tagId(input['name']! as String),
          'event_override' => eventOverrideId(
            input['event_id']! as String,
            input['original_start']! as String,
          ),
          'task_completion' => taskCompletionId(
            input['task_id']! as String,
            input['instance_date']! as String,
          ),
          'task_tag' => taskTagId(
            input['task_id']! as String,
            input['tag_id']! as String,
          ),
          final other => fail('неизвестный вид $other'),
        };
        expect(actual, c['expected']);
      });
    }
  });
}
