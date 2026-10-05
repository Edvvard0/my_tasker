import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart'
    show trimEdgeSpaces;
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/banks/domain/notification_guess.dart';

import '../../support/banks_data.dart';

/// Данные Банков и движок правил уведомлений: встроенные копии, каждое
/// правило на своих образцах, переносимое подмножество выражений.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data = loadBankDataSync();

  test('встроенные копии байт-в-байт равны shared-data/banks', () {
    for (final name in [
      'notification_rules',
      'merchant_normalization',
      'category_dictionary',
    ]) {
      expect(
        File('assets/banks/$name.json').readAsBytesSync(),
        File('../shared-data/banks/$name.json').readAsBytesSync(),
        reason: name,
      );
    }
  });

  test('BankData.load читает ассеты через rootBundle', () async {
    final loaded = await BankData.load();
    expect(loaded.notifications.banks.map((b) => b.id), ['tbank', 'vtb']);
    expect(loaded.notifications.packages, contains(tbankPackageForTest));
    expect(loaded.normalization.legalForms, contains('ооо'));
    expect(loaded.dictionary.keywords, isNotEmpty);
    expect(loaded.dictionary.mcc['5411'], 'expense.groceries');
  });

  test(
    'файл правил: подмножество выражений, группы, образцы, уникальность',
    () {
      expect(rulesProblems(data.notifications), isEmpty);
      final rules = [for (final b in data.notifications.banks) ...b.rules];
      expect(rules.length, greaterThanOrEqualTo(18));
      // Пакет принадлежит ровно одному банку.
      final packages = data.notifications.packages;
      expect(packages.toSet().length, packages.length);
    },
  );

  test('каждое правило разбирает все свои образцы: ожидаемое — подмножество '
      'результата', () {
    var samples = 0;
    for (final bank in data.notifications.banks) {
      for (final rule in bank.rules) {
        expect(rule.samples, isNotEmpty, reason: rule.id);
        for (final sample in rule.samples) {
          samples++;
          final result = parseNotification(
            data.notifications,
            package: bank.packages.first,
            title: sample.title,
            text: sample.text,
          );
          final json = result.toJson();
          expect(
            result.ruleId,
            rule.id,
            reason: 'образец «${sample.text}» должен разбирать ${rule.id}',
          );
          for (final e in sample.expected.entries) {
            expect(json[e.key], e.value, reason: '${rule.id}: ${e.key}');
          }
        }
      }
    }
    expect(samples, greaterThanOrEqualTo(26));
  });

  group('patternProblem: переносимое подмножество', () {
    test('разрешённое', () {
      for (final p in [
        r'^Покупка на ([0-9]+) ₽\.$',
        '(?:a|b)+?c{2,3}',
        '[^0-9]*',
        r'\(\)\[\]\{\}\|\^\$\\\-\/\.\*\+\?',
        'a{2}',
        'a{2,}?',
      ]) {
        expect(patternProblem(p), isNull, reason: p);
      }
    });

    test('запрещённое', () {
      for (final p in [
        r'\d+',
        r'\w',
        r'\s',
        r'\b',
        '(?i)a',
        '(?=a)',
        '(?<n>a)',
        '(?!a)',
        r'(a)\1',
        'a*+',
        'a++',
        'a?+',
        'a{1,2}+',
        'a+*',
        'a{,3}',
        'a{x}',
        '[[a]',
        '[]a]',
        '[a',
        r'a\',
        r'\é',
      ]) {
        expect(patternProblem(p), isNotNull, reason: p);
      }
    });
  });

  test('очистка текста: экзотические пробелы и переводы строк', () {
    expect(
      normalizeNotificationText('  a  b\t\r\nc d e\u000bf\u000cg  '),
      'a b c d e f g',
    );
    expect(normalizeNotificationText(''), '');
    expect(normalizeNotificationText('a​b'), 'a​b');
  });

  test('rulesProblems находит ошибки данных', () {
    final broken = NotificationRules.fromJson(const {
      'currencies': {'₽': 'RUB'},
      'banks': [
        {
          'id': 'x',
          'name': 'X',
          'packages': ['p', 'p'],
          'rules': [
            {
              'id': 'x.a',
              'kind': 'expense',
              'pattern': r'\d+',
              'groups': {'merchant': 1},
              'samples': <Object?>[],
            },
            {
              'id': 'x.a',
              'kind': 'expense',
              'pattern': r'^([0-9]+)$',
              'groups': {'amount': 1},
              'samples': [
                {'title': '', 'text': 'zzz', 'expected': <String, Object?>{}},
              ],
            },
          ],
        },
      ],
    });
    final problems = rulesProblems(broken);
    expect(problems, contains('package p listed twice'));
    expect(problems.any((p) => p.contains('duplicate id')), isTrue);
    expect(problems.any((p) => p.contains('escape')), isTrue);
    expect(problems.any((p) => p.contains('needs an amount group')), isTrue);
    expect(problems.any((p) => p.contains('no samples')), isTrue);
    expect(problems.any((p) => p.contains('is not matched')), isTrue);
  });

  group('parseNotification: крайние случаи', () {
    NotificationParse parse(String package, String title, String text) =>
        parseNotification(
          data.notifications,
          package: package,
          title: title,
          text: text,
        );

    test('неизвестный пакет, служебное, нет правила', () {
      expect(
        parse('x.y', 'Покупка', 'Покупка на 1 ₽, X. Карта *1234').toJson(),
        {
          'status': 'ignored',
          'bank': null,
          'rule_id': null,
          'reason': 'unknown_package',
        },
      );
      final ignored = parse(tbankPackageForTest, 'Акция', 'Скидки до 30%');
      expect(ignored.status, NotificationStatus.ignored);
      expect(ignored.ruleId, 'tbank.ignore_service');
      expect(ignored.toJson().containsKey('reason'), isFalse);
      final none = parse(tbankPackageForTest, 'Покупка', 'совсем другое');
      expect(none.status, NotificationStatus.unrecognized);
      expect(none.reason, 'no_rule');
    });

    test('нечитаемая сумма и неизвестная валюта: unrecognized с причиной', () {
      final rules = NotificationRules.fromJson(const {
        'currencies': {'₽': 'RUB'},
        'banks': [
          {
            'id': 'b',
            'name': 'B',
            'packages': ['p'],
            'rules': [
              {
                'id': 'b.one',
                'kind': 'expense',
                'pattern': r'^S (.+) C (.+)$',
                'groups': {'amount': 1, 'currency': 2},
                'samples': [
                  {
                    'title': '',
                    'text': 'S 5 C ₽',
                    'expected': <String, Object?>{},
                  },
                ],
              },
            ],
          },
        ],
      });
      final bad = parseNotification(
        rules,
        package: 'p',
        title: '',
        text: 'S abc C ₽',
      );
      expect(bad.reason, 'bad_amount');
      expect(bad.ruleId, 'b.one');
      final unknown = parseNotification(
        rules,
        package: 'p',
        title: '',
        text: 'S 5 C GBP',
      );
      expect(unknown.reason, 'unknown_currency');
      final ok = parseNotification(
        rules,
        package: 'p',
        title: '',
        text: 'S 5 C ₽',
      );
      expect(ok.isParsed, isTrue);
      expect(ok.amount, 500);
    });

    test('время: реальное время читается, 25:61 — нет', () {
      final withTime = parse(
        vtbPackageForTest,
        'ВТБ',
        'Оплата 100 ₽, 14:05, карта *5678, Магнит. Остаток 900 ₽',
      );
      expect(withTime.time, '14:05');
      final badTime = parse(
        vtbPackageForTest,
        'ВТБ',
        'Оплата 100 ₽, 25:61, карта *5678, Магнит. Остаток 900 ₽',
      );
      expect(badTime.isParsed, isTrue);
      expect(badTime.time, isNull);
    });

    test('NotificationParse: JSON туда и обратно', () {
      final parsed = parse(
        tbankPackageForTest,
        'Покупка',
        'Покупка на 1 234,56 ₽, Пятёрочка. Карта *1234. Доступно 10 000,50 ₽',
      );
      final copy = NotificationParse.fromJson(parsed.toJson());
      expect(copy.toJson(), parsed.toJson());
      expect(
        NotificationParse.fromJson(const {'status': 'weird'}).status,
        NotificationStatus.unrecognized,
      );
    });
  });

  group('notificationMoment', () {
    test('без времени — время публикации', () {
      final at = DateTime.utc(2026, 10, 3, 8, 30, 15);
      expect(notificationMoment(at, null), at);
    });

    test('время в тот же московский день', () {
      // 11:40 МСК = 08:40Z; в уведомлении 11:38.
      final posted = DateTime.utc(2026, 10, 3, 8, 40);
      expect(
        notificationMoment(posted, '11:38'),
        DateTime.utc(2026, 10, 3, 8, 38),
      );
    });

    test('время позже публикации до 10 минут — не в будущем: момент '
        'публикации', () {
      final posted = DateTime.utc(2026, 10, 3, 8, 40);
      expect(notificationMoment(posted, '11:46'), posted);
      expect(
        notificationMoment(posted, '11:51'),
        DateTime.utc(2026, 10, 2, 8, 51),
      );
    });

    test('время позже публикации больше чем на 10 минут — «вчера»', () {
      // Опубликовано 00:05 МСК 4 октября (21:05Z 3-го), в тексте 23:58.
      final posted = DateTime.utc(2026, 10, 3, 21, 5);
      expect(
        notificationMoment(posted, '23:58'),
        DateTime.utc(2026, 10, 3, 20, 58),
      );
    });
  });

  test('обрезка по краям: явный набор символов, одинаковый с Python', () {
    // Не режутся ни `trim()` Python-стиля (U+001C–U+001F), ни Dart (U+FEFF).
    for (final kept in ['\u001c', '\u001f', '\ufeff']) {
      expect(trimEdgeSpaces('${kept}x$kept'), '${kept}x$kept');
    }
    for (final cut in [
      '\u0009',
      '\u0085',
      '\u00a0',
      '\u1680',
      '\u2003',
      '\u202f',
      '\u205f',
      '\u3000',
    ]) {
      expect(trimEdgeSpaces('${cut}x$cut'), 'x');
    }
    expect(trimEdgeSpaces(''), '');
    expect(trimEdgeSpaces('  '), '');
  });

  test('догадка по тексту нераспознанного уведомления', () {
    final expense = guessFromNotification('Банк', 'Оплата 1 234,50 ₽ в Кафе');
    expect(expense.amount, 123450);
    expect(expense.isIncome, isFalse);
    final income = guessFromNotification('', 'Зачислено 5 000 руб. зарплата');
    expect(income.amount, 500000);
    expect(income.isIncome, isTrue);
    expect(guessFromNotification('', 'Что-то без суммы').amount, isNull);
  });

  test('BankNotification и тексты причин', () {
    expect(NotificationState.parse('processed'), NotificationState.processed);
    expect(NotificationState.parse('?'), NotificationState.unrecognized);
    for (final r in [
      'no_rule',
      'bad_amount',
      'unknown_currency',
      'no_account',
      'ambiguous_account',
      'foreign_currency',
      null,
    ]) {
      expect(reviewReasonText(r), isNotEmpty);
    }
    final fromMap = RawNotification.fromMap(const {
      'package': 'p',
      'title': 't',
      'text': 'x',
      'posted_at_ms': 1790000000000,
    });
    expect(fromMap.postedAt, DateTime.utc(2026, 9, 21, 14, 13, 20));
    expect(RawNotification.fromMap(const {}).package, '');
  });
}

const String tbankPackageForTest = 'com.idamob.tinkoff.android';
const String vtbPackageForTest = 'ru.vtb24.mobilebanking.android';
