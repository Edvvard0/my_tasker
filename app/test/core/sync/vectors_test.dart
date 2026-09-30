import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/server_epoch.dart';
import 'package:my_tasker/core/sync/value_validation.dart';

import '../../support/fake_server/merge_decisions.dart';
import '../../support/vectors.dart';

Map<String, Object?> _map(Object? v) => (v! as Map).cast<String, Object?>();

void main() {
  test('все файлы векторов домена sync покрыты тестами', () {
    expect(vectorFiles('sync'), [
      'epoch.json',
      'hlc.json',
      'merge.json',
      'outbox.json',
      'settings_id.json',
      'validation.json',
    ]);
  });

  group('HLC: общие векторы', () {
    for (final c in loadVectors('sync', 'hlc.json')) {
      test(c['name']! as String, () {
        final data = _map(c['input']);
        final expected = c['expected'];
        switch (data['op']) {
          case 'compare':
            final a = data['a']! as String;
            final b = data['b']! as String;
            expect(compareHlc(a, b), expected);
            expect(Hlc.parse(a).compareTo(Hlc.parse(b)).sign, expected);
          case 'format':
            String run() => formatHlc(
              data['ms']! as int,
              data['counter']! as int,
              data['device']! as String,
            );
            if (isErrorExpected(expected)) {
              expect(run, throwsA(isA<HlcFormatException>()));
            } else {
              expect(run(), expected);
            }
          case 'parse':
            final value = data['value']! as String;
            if (isErrorExpected(expected)) {
              expect(
                () => Hlc.parse(value),
                throwsA(isA<HlcFormatException>()),
              );
              expect(isValidHlc(value), isFalse);
            } else {
              final e = _map(expected);
              final parsed = Hlc.parse(value);
              expect(parsed.ms, e['ms']);
              expect(parsed.counter, e['counter']);
              expect(parsed.device, e['device']);
              expect(parsed.toString(), value);
              expect(hlcMs(value), e['ms']);
              expect(hlcDevice(value), e['device']);
              expect(value.length, hlcLength);
            }
          case 'send':
            final state = _map(data['state']);
            final clock = HlcClock(
              data['device']! as String,
              HlcState(state['l']! as int, state['c']! as int),
            );
            final e = _map(expected);
            expect(clock.send(data['now']! as int), e['hlc']);
            final es = _map(e['state']);
            expect(clock.state, HlcState(es['l']! as int, es['c']! as int));
          case 'receive':
            final state = _map(data['state']);
            final clock = HlcClock(
              '0195f2a0-0000-7000-8000-000000000001',
              HlcState(state['l']! as int, state['c']! as int),
            )..receive(data['remote']! as String, data['now']! as int);
            final es = _map(_map(expected)['state']);
            expect(clock.state, HlcState(es['l']! as int, es['c']! as int));
          default:
            fail('неизвестная операция hlc ${data['op']}');
        }
      });
    }
  });

  group('слияние: общие векторы (решения сервера)', () {
    for (final c in loadVectors('sync', 'merge.json')) {
      test(c['name']! as String, () {
        final data = _map(c['input']);
        final String actual;
        switch (data['kind']) {
          case 'field':
            final current = data['current'];
            final incoming = data['incoming'];
            actual = fieldDecision(
              sameValue:
                  _canonical(current) == _canonical(incoming) &&
                  current.runtimeType == incoming.runtimeType,
              entry: data['entry'] == null
                  ? null
                  : FieldEntry.fromJson(_map(data['entry'])),
              opHlc: data['hlc']! as String,
              baseVersion: data['base_version']! as int,
            );
          case 'delete':
            actual = deleteDecision(
              alreadyDeleted: data['deleted']! as bool,
              fieldEntries: {
                for (final e in _map(data['fields']).entries)
                  e.key: FieldEntry.fromJson(_map(e.value)),
              },
              opHlc: data['hlc']! as String,
              baseVersion: data['base_version']! as int,
            );
          case 'tombstone_edit':
            actual = tombstoneEditDecision(
              entryDeleted: FieldEntry.fromJson(_map(data['entry'])),
              opHlc: data['hlc']! as String,
              baseVersion: data['base_version']! as int,
              restore: data['restore']! as bool,
            );
          default:
            fail('неизвестный вид ${data['kind']}');
        }
        expect(actual, c['expected']);
      });
    }
  });

  group('outbox: общие векторы', () {
    for (final c in loadVectors('sync', 'outbox.json')) {
      test(c['name']! as String, () {
        final data = _map(c['input']);
        if (data['op'] == 'collapse') {
          final outbox = [
            for (final o in data['outbox']! as List<Object?>) _map(o),
          ];
          final before = [for (final o in outbox) deepCopy(o)];
          final result = collapseOutbox(outbox, _map(data['new']));
          expect(result, c['expected']);
          expect(outbox, before, reason: 'исходный outbox не меняется');
        } else {
          final outbox = [
            for (final o in data['outbox']! as List<Object?>) _map(o),
          ];
          final row = rebaseRow(_map(data['server_row']), outbox);
          expect(row, _map(c['expected'])['row']);
        }
      });
    }
  });

  group('эпоха сервера: общие векторы', () {
    for (final c in loadVectors('sync', 'epoch.json')) {
      test(c['name']! as String, () {
        final data = _map(c['input']);
        final action = epochAction(
          stored: data['stored'] as String?,
          received: data['received'] as String?,
        );
        expect(switch (action) {
          EpochAction.none => 'none',
          EpochAction.store => 'store',
          EpochAction.fullResync => 'full_resync',
        }, c['expected']);
      });
    }
  });

  group('проверка значений: общие векторы', () {
    for (final c in loadVectors('sync', 'validation.json')) {
      test(c['name']! as String, () {
        final data = _map(c['input']);
        final expected = c['expected'];
        final Object? actual;
        switch (data['op']) {
          case 'datetime':
            actual = normalizeDatetime(data['value']! as String);
          case 'text':
            final v = data['value']! as String;
            actual = isStorableText(v) ? v : null;
          case 'json':
            actual = isStorableJson(data['value']) ? data['value'] : null;
          case 'nested_lists':
            Object? nested = <Object?>[];
            for (var i = 1; i < (data['depth']! as int); i++) {
              nested = <Object?>[nested];
            }
            actual = isStorableJson(nested) ? true : null;
          default:
            fail('неизвестная операция ${data['op']}');
        }
        if (isErrorExpected(expected)) {
          expect(actual, isNull);
        } else {
          expect(actual, expected);
        }
      });
    }
  });

  group('user_settings.id: общие векторы', () {
    for (final c in loadVectors('sync', 'settings_id.json')) {
      test(c['name']! as String, () {
        expect(userSettingsId(c['input']! as String), c['expected']);
      });
    }
  });
}

String _canonical(Object? value) => jsonEncodeSortedForTest(value);

String jsonEncodeSortedForTest(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '$k:${jsonEncodeSortedForTest(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(jsonEncodeSortedForTest).join(',')}]';
  return '$value';
}
