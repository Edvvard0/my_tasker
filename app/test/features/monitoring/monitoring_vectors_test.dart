import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_stats.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_targets.dart';

import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

/// Общие векторы «Серверов» (`shared-test-vectors/monitoring/`): Dart обязан
/// пройти `targets.json` (форма клиента отвечает на адреса так же, как
/// сервер) и `availability.json` (общий расчёт доступности); `alerts.json` и
/// `quiet.json` — серверные правила, Dart их не реализует (проверяем лишь,
/// что файлы на месте).
void main() {
  test('каталог векторов: четыре файла, targets — 96 случаев', () {
    expect(vectorFiles('monitoring'), [
      'alerts.json',
      'availability.json',
      'quiet.json',
      'targets.json',
    ]);
    expect(loadVectors('monitoring', 'targets.json'), hasLength(96));
    expect(loadVectors('monitoring', 'availability.json'), hasLength(14));
    // Серверные файлы читаются, но на устройстве не считаются.
    expect(loadVectors('monitoring', 'alerts.json'), isNotEmpty);
    expect(loadVectors('monitoring', 'quiet.json'), isNotEmpty);
  });

  test('targets.json: check_host, check_url и check_addresses — все 96', () {
    var checked = 0;
    for (final c in loadVectors('monitoring', 'targets.json')) {
      final input = c['input']! as _Json;
      final name = '${c['name']}';
      final Object? actual;
      switch (input['op']) {
        case 'host':
          actual = checkHost(input['value']! as String).toJson();
        case 'url':
          actual = checkUrl(input['value']! as String).toJson();
        case 'addresses':
          actual = {
            'reason': checkAddresses(
              (input['values']! as List<Object?>).cast<String>(),
            ),
          };
        default:
          fail('$name: неизвестная операция ${input['op']}');
      }
      expect(actual, c['expected'], reason: name);
      checked++;
    }
    expect(checked, 96);
  });

  test('availability.json: availabilityBp — все случаи', () {
    var checked = 0;
    for (final c in loadVectors('monitoring', 'availability.json')) {
      final input = c['input']! as _Json;
      final buckets = [
        for (final b in input['buckets']! as List<Object?>)
          Bucket(
            (b! as _Json)['hour']! as int,
            (b as _Json)['total']! as int,
            b['ok']! as int,
          ),
      ];
      final bp = availabilityBp(
        buckets,
        input['now']! as int,
        input['hours']! as int,
      );
      expect({'bp': bp}, c['expected'], reason: '${c['name']}');
      checked++;
    }
    expect(checked, 14);
  });

  group('расхождения Dart и Python закрыты (сверено на 44 500 случаях)', () {
    test('знак Кельвина в имени становится «k» (как str.lower() в Python)', () {
      expect(checkHost('exampleK.com').toJson(), {
        'valid': true,
        'host': 'examplek.com',
      });
    });

    test('«İ» (U+0130) не превращается в «i»: имя отклоняется', () {
      expect(checkHost('İ.com').reason, 'bad_chars');
      expect(checkUrl('http://İ.com').reason, 'bad_chars');
    });

    test('U+0085 и неразрывный пробел — пробельные, U+FEFF — нет', () {
      expect(checkUrl('http://a\u0085.com').reason, 'bad_chars');
      expect(checkUrl('http://a b.com').reason, 'bad_chars');
      expect(checkHost('a﻿.com').reason, 'bad_chars');
    });

    test('порядок причин URL как у urlsplit: порт раньше схемы', () {
      expect(checkUrl('ftp://example.com:99999').reason, 'bad_port');
      expect(checkUrl('ftp://example.com:80').reason, 'scheme');
      expect(checkUrl('http://[::1').reason, 'bad_url');
      expect(checkUrl('http://[1.2.3.4]/').reason, 'bad_url');
      expect(checkUrl('example.com:8080').reason, 'scheme');
    });

    test('мусор вокруг скобок IPv6 — bad_url, как у Python 3.13', () {
      for (final bad in [
        'http://[2001:4860:4860::8888]x/',
        'http://a[::1]',
        'http://u@a[::1]/',
        'http://[::1]]',
        'http://[::1][::1]/',
        'http://[::1]@a.com/',
        'http://[]/',
        'http://[::1/',
        'http://::1]/',
        'http://[2001:4860:4860::8888%]/',
      ]) {
        expect(checkUrl(bad).reason, 'bad_url', reason: bad);
      }
      expect(checkUrl('http://[2001:4860:4860::8888]/').valid, isTrue);
      expect(checkUrl('http://[2001:4860:4860::8888]:8080/x').valid, isTrue);
      expect(checkUrl('http://u@[2001:4860:4860::8888]/').reason, 'userinfo');
    });

    test('символы, которые после NFKC дают / ? # @ :, — bad_url', () {
      for (final bad in [
        'http://a\u2047b.com/', // ??
        'http://a\uff0fb.com/', // полноширинная «/»
        'http://a\uff03b.com/', // полноширинная «#»
        'http://a\u2100b.com/', // «a/c»
        'http://example.com\uff1a80/',
        'http://example.com\uff20/',
      ]) {
        expect(checkUrl(bad).reason, 'bad_url', reason: bad);
      }
      // Вне netloc те же символы безвредны для разбора.
      expect(checkUrl('http://example.com/a\uff0fb').valid, isTrue);
    });

    test('IPv6: сжатие, IPv4-хвост и «лишние» двоеточия', () {
      expect(checkHost('2606:4700:4700::1111').valid, isTrue);
      expect(checkHost('2606:4700:4700:0:0:0:0:1111').valid, isTrue);
      expect(checkHost('1::2::3').reason, 'bad_chars');
      expect(checkHost(':1:2:3:4:5:6:7').reason, 'bad_chars');
      expect(checkHost('::ffff:8.8.8.8').valid, isTrue);
      expect(checkHost('::ffff:8.8.8').reason, 'bad_chars');
      expect(checkHost('64:ff9b::808:808').reason, 'non_global_ip');
    });

    test('непубличные диапазоны IPv6 и IPv4', () {
      for (final bad in [
        '::',
        '::1',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '2002::1',
        '3fff::1',
        '100::1',
        '64:ff9b:1::1',
        '0.0.0.0',
        '10.255.255.255',
        '100.127.255.255',
        '172.31.255.255',
        '192.0.0.1',
        '198.19.255.255',
        '224.0.0.1',
        '240.0.0.1',
      ]) {
        expect(nonGlobal(bad), isTrue, reason: bad);
      }
      for (final good in [
        '8.8.8.8',
        '1.1.1.1',
        '172.32.0.1',
        '100.128.0.1',
        '192.0.0.9',
        '2606:4700::1111',
        '2001:4860:4860::8888',
        '2a00:1450::1',
      ]) {
        expect(nonGlobal(good), isFalse, reason: good);
      }
    });
  });
}
