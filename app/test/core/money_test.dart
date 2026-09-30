import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/money/money.dart';

/// Загружает все `*.json` домена из общего каталога векторов
/// (`../shared-test-vectors/<домен>` относительно `app/`).
List<Map<String, dynamic>> loadVectorCases(String domain, String file) {
  final path = '../shared-test-vectors/$domain/$file';
  final f = File(path);
  if (!f.existsSync()) fail('Файл векторов не найден: $path');
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final cases = (json['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
  if (cases.isEmpty) fail('В $path нет случаев');
  return cases;
}

bool _isError(Object? expected) =>
    expected is Map<String, dynamic> && expected['error'] == true;

void main() {
  group('parseAmount: общие векторы', () {
    final cases = loadVectorCases('money', 'parse_amount.json');
    test('файл содержит случаи', () => expect(cases, isNotEmpty));
    for (final c in cases) {
      test(c['name'] as String, () {
        final input = c['input'] as String;
        final expected = c['expected'];
        if (_isError(expected)) {
          expect(() => parseAmount(input), throwsFormatException);
          expect(tryParseAmount(input), isNull);
        } else {
          expect(parseAmount(input), expected);
          expect(tryParseAmount(input), expected);
        }
      });
    }
  });

  group('formatAmount: общие векторы', () {
    final cases = loadVectorCases('money', 'format_amount.json');
    test('файл содержит случаи', () => expect(cases, isNotEmpty));
    for (final c in cases) {
      test(c['name'] as String, () {
        final input = c['input'] as int;
        if (_isError(c['expected'])) {
          expect(() => formatAmount(input), throwsRangeError);
        } else {
          expect(formatAmount(input), c['expected']);
        }
      });
    }
  });

  group('свойства', () {
    test('parse(format(n)) == n на границах и выборке', () {
      final samples = <int>[
        0,
        1,
        -1,
        99,
        100,
        101,
        -100,
        123456,
        -123456,
        maxKopecks,
        -maxKopecks,
        for (var i = 1; i < 1000000000000; i = i * 7 + 3) i,
        for (var i = 1; i < 1000000000000; i = i * 7 + 3) -i,
      ];
      for (final n in samples) {
        expect(parseAmount(formatAmount(n)), n, reason: 'n=$n');
      }
    });

    test('formatAmount вне диапазона бросает RangeError', () {
      expect(() => formatAmount(maxKopecks + 1), throwsRangeError);
      expect(() => formatAmount(-maxKopecks - 1), throwsRangeError);
    });

    test('максимум разбирается, 13 цифр — ошибка', () {
      expect(parseAmount('999999999999,99'), maxKopecks);
      expect(tryParseAmount('1000000000000'), isNull);
    });
  });
}
