import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

List<_Json> _rows(Object? v) => [
  for (final r in (v as List<Object?>? ?? const [])) (r! as Map).cast(),
];

ScheduleInput _input(_Json input) => ScheduleInput(
  semesters: [for (final r in _rows(input['semesters'])) Semester.fromRow(r)],
  subjects: [for (final r in _rows(input['subjects'])) Subject.fromRow(r)],
  bells: [for (final r in _rows(input['bells'])) Bell.fromRow(r)],
  slots: [for (final r in _rows(input['slots'])) ClassSlot.fromRow(r)],
  dayRules: [for (final r in _rows(input['day_rules'])) DayRule.fromRow(r)],
  overrides: [
    for (final r in _rows(input['overrides'])) ClassOverride.fromRow(r),
  ],
  holidays: {
    for (final e in ((input['holidays'] as Map?) ?? const {}).entries)
      e.key as String: e.value as String,
  },
);

/// Общие векторы Учёбы (`shared-test-vectors/study/`): Dart обязан пройти
/// каждый случай каждого файла; ожидаемое — эталон Python `reference.py`.
void main() {
  test('каталог векторов: все файлы домена и не меньше 60 случаев', () {
    expect(vectorFiles('study'), [
      'attendance.json',
      'bells.json',
      'cycle.json',
      'expand.json',
      'rooms.json',
    ]);
    var total = 0;
    for (final f in vectorFiles('study')) {
      total += loadVectors('study', f).length;
    }
    expect(total, greaterThanOrEqualTo(133));
  });

  test('expand.json: развёртка расписания на дату', () {
    final cases = loadVectors('study', 'expand.json');
    expect(cases.length, greaterThanOrEqualTo(47));
    for (final c in cases) {
      final input = c['input']! as _Json;
      final schedule = _input(input);
      final dates = (input['dates']! as List<Object?>).cast<String>();
      final expected = (c['expected']! as List<Object?>).cast<_Json>();
      expect(dates.length, expected.length, reason: c['name']! as String);
      for (var i = 0; i < dates.length; i++) {
        expect(
          expandDay(dates[i], schedule).toJson(),
          expected[i],
          reason: '${c['name']} ${dates[i]}',
        );
      }
    }
  });

  test('attendance.json: посещаемость и состояния лимита', () {
    final cases = loadVectors('study', 'attendance.json');
    for (final c in cases) {
      final input = c['input']! as _Json;
      final marks = [
        for (final r in _rows(input['attendance'])) AttendanceMark.fromRow(r),
      ];
      final actual = attendanceSummary(
        input['through']! as String,
        _input(input),
        marks,
      );
      expect(
        [for (final s in actual) s.toJson()],
        c['expected'],
        reason: '${c['name']}',
      );
    }
  });

  test('rooms.json: разбор и показ аудитории', () {
    for (final c in loadVectors('study', 'rooms.json')) {
      final input = c['input']! as _Json;
      final reason = c['name']! as String;
      if (input['op'] == 'parse') {
        final parts = parseRoom(input['text']! as String);
        final expected = c['expected'] as _Json?;
        if (expected == null) {
          expect(parts, isNull, reason: reason);
        } else {
          expect(parts, isNotNull, reason: reason);
          expect(parts!.building, expected['building'], reason: reason);
          expect(parts.room, expected['room'], reason: reason);
        }
      } else {
        expect(
          formatRoom(input['building'] as String?, input['room'] as String?),
          c['expected'],
          reason: reason,
        );
      }
    }
  });

  test('bells.json: генератор сетки звонков', () {
    for (final c in loadVectors('study', 'bells.json')) {
      final input = c['input']! as _Json;
      final breaks = input['breaks'];
      final result = generateBells(
        input['first_start']! as String,
        input['duration']! as int,
        breaks is List ? breaks.cast<int>() : breaks! as int,
        input['count']! as int,
      );
      if (isErrorExpected(c['expected'])) {
        expect(result, isNull, reason: '${c['name']}');
      } else {
        expect(result, isNotNull, reason: '${c['name']}');
        expect(
          [
            for (final b in result!)
              {
                'number': b.number,
                'start_time': b.startTime,
                'end_time': b.endTime,
              },
          ],
          c['expected'],
          reason: '${c['name']}',
        );
      }
    }
  });

  test('cycle.json: неделя цикла семестра', () {
    for (final c in loadVectors('study', 'cycle.json')) {
      final input = c['input']! as _Json;
      final semester = Semester.fromRow((input['semester']! as Map).cast());
      final dates = (input['dates']! as List<Object?>).cast<String>();
      expect(
        [for (final d in dates) semester.weekNumber(d)],
        c['expected'],
        reason: '${c['name']}',
      );
    }
  });
}
