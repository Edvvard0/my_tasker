import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';

import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

List<_Json> _rows(Object? v) => [
  for (final r in (v as List<Object?>? ?? const [])) (r! as Map).cast(),
];

List<String> _strings(Object? v) => [
  for (final s in (v as List<Object?>? ?? const [])) s! as String,
];

/// Общие векторы «Сна» (`shared-test-vectors/sleep/`): Dart обязан пройти
/// каждый случай каждого файла; ожидаемое — эталон Python `reference.py`.
void main() {
  test('каталог векторов: все пять файлов и 83 случая', () {
    expect(vectorFiles('sleep'), [
      'averages.json',
      'carry_over.json',
      'duration.json',
      'link.json',
      'streaks.json',
    ]);
    final counts = {
      for (final f in vectorFiles('sleep')) f: loadVectors('sleep', f).length,
    };
    expect(counts, {
      'averages.json': 15,
      'carry_over.json': 21,
      'duration.json': 20,
      'link.json': 14,
      'streaks.json': 13,
    });
    expect(counts.values.fold<int>(0, (a, b) => a + b), 83);
  });

  test('duration.json: entry_view — длительность, дата и часы на стене', () {
    for (final c in loadVectors('sleep', 'duration.json')) {
      final view = entryView((c['input']! as Map).cast());
      final expected = c['expected'];
      if (isErrorExpected(expected)) {
        expect(view, isNull, reason: '${c['name']}');
      } else {
        expect(view?.toJson(), expected, reason: '${c['name']}');
      }
    }
  });

  test('averages.json: средний сон, пропущенные дни — не нули', () {
    for (final c in loadVectors('sleep', 'averages.json')) {
      final input = c['input']! as _Json;
      final actual = averageSleep(
        _rows(input['entries']),
        input['through']! as String,
        input['days']! as int,
      );
      expect(actual.toJson(), c['expected'], reason: '${c['name']}');
    }
  });

  test('link.json: связь сна с выполненными задачами', () {
    for (final c in loadVectors('sleep', 'link.json')) {
      final input = c['input']! as _Json;
      final actual = sleepTaskLink(
        _rows(input['entries']),
        _rows(input['tasks']),
        input['through']! as String,
      );
      expect(actual.toJson(), c['expected'], reason: '${c['name']}');
    }
  });

  test('streaks.json: серии ритуалов', () {
    for (final c in loadVectors('sleep', 'streaks.json')) {
      final input = c['input']! as _Json;
      final actual = ritualStreaks(
        _strings(input['morning']),
        _strings(input['evening']),
        input['through']! as String,
      );
      expect(actual.toJson(), c['expected'], reason: '${c['name']}');
    }
  });

  test('carry_over.json: перенос задач из чек-ина', () {
    for (final c in loadVectors('sleep', 'carry_over.json')) {
      final input = c['input']! as _Json;
      final actual = planCarryOver(
        input['date']! as String,
        _rows(input['decisions']),
        _rows(input['tasks']),
      );
      expect(
        [for (final r in actual) r.toJson()],
        c['expected'],
        reason: '${c['name']}',
      );
    }
  });
}
