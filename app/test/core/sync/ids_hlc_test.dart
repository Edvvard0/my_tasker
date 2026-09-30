import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';

void main() {
  group('uuid7', () {
    test('версия 7, вариант RFC 4122, строчная дефисная запись', () {
      for (var i = 0; i < 200; i++) {
        final id = uuid7();
        expect(
          id,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(isUuid7(id), isTrue);
        expect(isUuid(id), isTrue);
      }
    });

    test('первые 48 бит — время в миллисекундах', () {
      final id = uuid7(nowMs: 0x0195f2a07b1c, random: Random(1));
      expect(id.replaceAll('-', '').substring(0, 12), '0195f2a07b1c');
      final later = uuid7(nowMs: 0x0195f2a07b1d, random: Random(1));
      expect(later.compareTo(id), greaterThan(0));
    });

    test('значения одного процесса строго возрастают', () {
      var previous = uuid7();
      for (var i = 0; i < 20000; i++) {
        final next = uuid7();
        expect(next.compareTo(previous), greaterThan(0), reason: 'шаг $i');
        previous = next;
      }
    });

    test('возрастают и при остановившихся часах, и при часах назад', () {
      final a = uuid7(nowMs: 4000000000000);
      final b = uuid7(nowMs: 4000000000000);
      final c = uuid7(nowMs: 3999999999000);
      expect(b.compareTo(a), greaterThan(0));
      expect(c.compareTo(b), greaterThan(0));
    });

    test('isUuid7 отвергает другие версии и варианты', () {
      expect(isUuid7('0195f2a0-0000-4000-8000-00000000000a'), isFalse);
      expect(isUuid7('0195f2a0-0000-7000-c000-00000000000a'), isFalse);
      expect(isUuid7('0195F2A0-0000-7000-8000-00000000000A'), isFalse);
      expect(isUuid7('not-a-uuid'), isFalse);
      expect(isUuid('0195f2a0-0000-7000-8000-00000000000'), isFalse);
    });
  });

  group('uuid5', () {
    test('RFC 4122: известное значение для DNS-пространства', () {
      // uuid5(NAMESPACE_DNS, "python.org") из документации Python.
      expect(
        uuid5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'python.org'),
        '886313e1-3b8a-5372-9b90-0c9aee199e5d',
      );
    });

    test('детерминирован; версия 5; плохое пространство — ошибка', () {
      final a = userSettingsId('ui.theme');
      expect(a, userSettingsId('ui.theme'));
      expect(a[14], '5');
      expect(userSettingsId('ui.other'), isNot(a));
      expect(() => uuid5('nope', 'x'), throwsArgumentError);
    });
  });

  group('Hlc', () {
    const device = '0195f2a0-0000-7000-8000-00000000000a';

    test('разбор, печать, равенство и порядок', () {
      final a = Hlc.parse(formatHlc(1000, 1, device));
      const b = Hlc(1000, 2, device);
      expect(a.toString(), formatHlc(1000, 1, device));
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(a), greaterThan(0));
      expect(a, const Hlc(1000, 1, device));
      expect(a.hashCode, const Hlc(1000, 1, device).hashCode);
      expect(a, isNot(b));
      expect([b, a]..sort(), [a, b]);
    });

    test('formatHlc проверяет устройство и диапазоны', () {
      expect(() => formatHlc(1, 1, 'nope'), throwsA(isA<HlcFormatException>()));
      expect(
        () => formatHlc(1, -1, device),
        throwsA(isA<HlcFormatException>()),
      );
      expect(formatHlc(1, 1, device).length, hlcLength);
    });

    test('HlcState: значение, равенство, вывод', () {
      expect(const HlcState(1, 2), const HlcState(1, 2));
      expect(const HlcState(1, 2).hashCode, const HlcState(1, 2).hashCode);
      expect(const HlcState(1, 2), isNot(const HlcState(1, 3)));
      expect(HlcState.zero.toString(), 'HlcState(0, 0)');
    });

    test('часы: send монотонны при любых входах', () {
      final clock = HlcClock(device);
      var previous = '';
      final rng = Random(7);
      var now = 5000;
      for (var i = 0; i < 2000; i++) {
        now += rng.nextInt(5) - 2; // часы то идут, то стоят, то откатываются
        final stamp = clock.send(now);
        expect(stamp.compareTo(previous), greaterThan(0));
        previous = stamp;
      }
    });

    test('часы: receive и send дают метку больше всего увиденного', () {
      final clock = HlcClock(device);
      final remote = formatHlc(
        9000,
        50,
        '0195f2a0-0000-7000-8000-00000000000b',
      );
      clock.receive(remote, 100);
      expect(clock.send(100).compareTo(remote), greaterThan(0));
    });
  });
}
