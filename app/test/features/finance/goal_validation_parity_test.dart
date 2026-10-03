import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';

/// Проверка формулы цели на клиенте — зеркало серверной
/// (`backend/src/tasker/finance/schema.py`: `GOAL_COLUMNS`, `formula_problem`,
/// `goal_problem`; spec Этапа 5, 1.7 и 3.1). Константы читаются из самого
/// `schema.py`, поведение сверяется таблицей случаев.
void main() {
  final schema = File('../backend/src/tasker/finance/schema.py')
      .readAsStringSync();

  const good = '01900000-0000-7000-8000-000000000001';

  Map<String, Object?> term(
    String kind, {
    String sign = '+',
    Object? extra,
    String? extraKey,
  }) => {'kind': kind, 'sign': sign, ?extraKey: extra};

  List<String> ids(int n) => [
    for (var i = 0; i < n; i++)
      '01900000-0000-7000-8000-${i.toString().padLeft(12, '0')}',
  ];

  group('константы совпадают с schema.py', () {
    test('виды слагаемых и знаки', () {
      final kinds = RegExp(r'GOAL_TERM_KINDS = \(([^)]*)\)')
          .firstMatch(schema)!
          .group(1)!;
      expect([
        for (final m in RegExp(r'"(\w+)"').allMatches(kinds)) m.group(1),
      ], GoalTermKind.values.map((k) => k.wire).toList());
      final signs = RegExp(r'GOAL_SIGNS = \(([^)]*)\)')
          .firstMatch(schema)!
          .group(1)!;
      expect([
        for (final m in RegExp('"([+-])"').allMatches(signs)) m.group(1),
      ], GoalSign.values.map((s) => s.wire).toList());
    });

    test('лимиты: слагаемых, id в слагаемом, размер формулы', () {
      expect(
        int.parse(
          RegExp(r'MAX_GOAL_TERMS = (\d+)').firstMatch(schema)!.group(1)!,
        ),
        maxGoalTerms,
      );
      expect(
        int.parse(
          RegExp(r'MAX_TERM_IDS = (\d+)').firstMatch(schema)!.group(1)!,
        ),
        maxTermIds,
      );
      expect(
        int.parse(
          RegExp(r'json_column\("formula", max_bytes=(\d+)\)')
              .firstMatch(schema)!
              .group(1)!,
        ),
        maxFormulaBytes,
      );
    });

    test('«свои» ключи каждого вида', () {
      final block = RegExp(
        r'_TERM_KEYS = \{(.*?)\n\}',
        dotAll: true,
      ).firstMatch(schema)!.group(1)!;
      final server = <String, Set<String>>{};
      for (final line in block.split('\n')) {
        final m = RegExp(r'"(\w+)": \{([^}]*)\}').firstMatch(line);
        if (m == null) continue;
        server[m.group(1)!] = {
          for (final k in RegExp(r'"(\w+)"').allMatches(m.group(2)!))
            k.group(1)!,
        };
      }
      expect(goalTermKeys, server);
    });

    test('сообщения не нужны: код проверки — те же ветки', () {
      // Серверная функция проверяет uuid каноничной строчной записью.
      expect(schema, contains('str(uuid.UUID(item)) == item'));
    });
  });

  group('формула (formula_problem)', () {
    test('нормальные формулы', () {
      expect(formulaProblem([term('all_accounts')]), isNull);
      expect(
        formulaProblem(formulaToJson(defaultGoalFormula())),
        isNull,
        reason: 'формула по умолчанию из spec 6.2',
      );
      expect(
        formulaProblem([
          term('accounts', extraKey: 'account_ids', extra: ids(1)),
          term('accounts', sign: '-', extraKey: 'account_ids', extra: ids(50)),
          term('my_debts', sign: '-'),
          term('debts_to_me'),
          term('receivables', extraKey: 'client_ids'),
          term('receivables', extraKey: 'client_ids', extra: ids(50)),
        ]),
        isNull,
      );
      expect(
        formulaProblem([for (var i = 0; i < 30; i++) term('my_debts')]),
        isNull,
      );
    });

    test('не список и число слагаемых: 1–30', () {
      for (final bad in <Object?>[
        null,
        'x',
        5,
        <String, Object?>{},
        <Object?>[],
      ]) {
        expect(formulaProblem(bad), isNotNull, reason: '$bad');
      }
      expect(
        formulaProblem([for (var i = 0; i < 31; i++) term('my_debts')]),
        isNotNull,
      );
    });

    test('вид и знак', () {
      for (final bad in <Object?>[
        'accounts',
        1,
        null,
        <String, Object?>{},
        {'sign': '+'},
        {'kind': 'unknown', 'sign': '+'},
        {'kind': null, 'sign': '+'},
        {'kind': 5, 'sign': '+'},
      ]) {
        expect(formulaProblem([bad]), isNotNull, reason: '$bad');
      }
      for (final sign in <Object?>['*', '', '−', null, 1, true, '+-']) {
        expect(
          formulaProblem([
            {'kind': 'my_debts', 'sign': sign},
          ]),
          isNotNull,
          reason: '$sign',
        );
      }
      expect(
        formulaProblem([
          {'kind': 'my_debts'},
        ]),
        isNotNull,
        reason: 'знак обязателен',
      );
    });

    test('только свои ключи вида', () {
      expect(
        formulaProblem([
          term('all_accounts', extraKey: 'account_ids', extra: ids(1)),
        ]),
        isNotNull,
      );
      expect(
        formulaProblem([term('debts_to_me', extraKey: 'client_ids')]),
        isNotNull,
      );
      expect(
        formulaProblem([
          term('accounts', extraKey: 'client_ids', extra: ids(1)),
        ]),
        isNotNull,
        reason: 'у accounts нет client_ids (и нет account_ids)',
      );
      expect(
        formulaProblem([
          term('receivables', extraKey: 'account_ids', extra: ids(1)),
        ]),
        isNotNull,
      );
      expect(
        formulaProblem([
          {'kind': 'my_debts', 'sign': '+', 'note': 'x'},
        ]),
        isNotNull,
      );
    });

    test('account_ids: обязательны, 1–50 строчных uuid', () {
      expect(formulaProblem([term('accounts')]), isNotNull);
      for (final bad in <Object?>[
        null,
        <Object?>[],
        'x',
        5,
        ids(51),
        ['not-a-uuid'],
        ['01900000-0000-7000-8000-00000000000A'],
        ['{01900000-0000-7000-8000-000000000001}'],
        ['01900000000070008000000000000001'],
        [5],
        [null],
        ['urn:uuid:01900000-0000-7000-8000-000000000001'],
        [good, 'x'],
      ]) {
        expect(
          formulaProblem([
            term('accounts', extraKey: 'account_ids', extra: bad),
          ]),
          isNotNull,
          reason: '$bad',
        );
      }
    });

    test('client_ids: null или 1–50 строчных uuid', () {
      expect(
        formulaProblem([term('receivables', extraKey: 'client_ids')]),
        isNull,
      );
      expect(
        formulaProblem([term('receivables')]),
        isNull,
        reason: 'ключа нет — как null: сервер берёт term.get',
      );
      for (final bad in <Object?>[
        <Object?>[],
        ids(51),
        ['X'],
        'x',
        [5],
      ]) {
        expect(
          formulaProblem([
            term('receivables', extraKey: 'client_ids', extra: bad),
          ]),
          isNotNull,
          reason: '$bad',
        );
      }
    });

    test('размер: не больше 8 КБ', () {
      // 30 слагаемых по 50 счетов — далеко за 8 КБ, хотя каждое по лимитам.
      final big = [
        for (var i = 0; i < 30; i++)
          term('accounts', extraKey: 'account_ids', extra: ids(50)),
      ];
      expect(utf8.encode(jsonEncode(big)).length, greaterThan(maxFormulaBytes));
      expect(formulaProblem(big), contains('8 КБ'));
      // граница: 4 слагаемых по 50 счетов ≈ 7,7 КБ ещё проходят
      final fits = [
        for (var i = 0; i < 4; i++)
          term('accounts', extraKey: 'account_ids', extra: ids(50)),
      ];
      expect(utf8.encode(jsonEncode(fits)).length, lessThan(maxFormulaBytes));
      expect(formulaProblem(fits), isNull);
      final over = [
        for (var i = 0; i < 5; i++)
          term('accounts', extraKey: 'account_ids', extra: ids(50)),
      ];
      expect(
        utf8.encode(jsonEncode(over)).length,
        greaterThan(maxFormulaBytes),
      );
      expect(formulaProblem(over), isNotNull);
    });
  });

  group('цель (GOAL_COLUMNS, goal_problem)', () {
    Goal goal({
      String name = 'Отпуск',
      int target = 40000000,
      String? deadline,
      List<GoalTerm>? formula,
    }) => Goal(
      id: 'g',
      name: name,
      targetAmount: target,
      deadlineDate: deadline,
      formula: formula ?? defaultGoalFormula(),
    );

    test('нормальная цель', () {
      expect(goalProblem(goal()), isNull);
      expect(goalProblem(goal(name: 'x' * 200)), isNull);
      expect(goalProblem(goal(target: 1)), isNull);
      expect(goalProblem(goal(target: 99999999999999)), isNull);
      expect(goalProblem(goal(deadline: '2026-12-31')), isNull);
    });

    test('название: 1–200, не пустое', () {
      expect(goalProblem(goal(name: '')), isNotNull);
      expect(goalProblem(goal(name: '   ')), isNotNull);
      expect(goalProblem(goal(name: 'x' * 201)), isNotNull);
    });

    test('сумма: 1…максимум', () {
      expect(goalProblem(goal(target: 0)), isNotNull);
      expect(goalProblem(goal(target: -5)), isNotNull);
      expect(goalProblem(goal(target: 99999999999999 + 1)), isNotNull);
    });

    test('срок: реальная дата', () {
      for (final bad in ['2026-02-30', '1.10.2026', '', '2026-13-01']) {
        expect(goalProblem(goal(deadline: bad)), isNotNull, reason: bad);
      }
    });

    test('формула цели проверяется как на сервере', () {
      expect(goalProblem(goal(formula: const [])), isNotNull);
      expect(
        goalProblem(
          goal(formula: const [GoalTerm(kind: GoalTermKind.accounts)]),
        ),
        isNotNull,
        reason: 'у accounts список счетов обязателен',
      );
      expect(
        goalProblem(
          goal(
            formula: [
              for (var i = 0; i < 31; i++)
                const GoalTerm(kind: GoalTermKind.myDebts),
            ],
          ),
        ),
        isNotNull,
      );
    });
  });
}
