import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/preset_categories.dart';

import '../../support/vectors.dart';

Row _map(Object? v) => (v! as Map).cast<String, Object?>();

Rows _rows(Object? v) => [for (final r in v! as List<Object?>) _map(r)];

/// Общие векторы домена `finance` (`shared-test-vectors/finance/*.json`):
/// каждый случай читается с диска; Dart обязан дать побайтно тот же результат,
/// что `backend/src/tasker/finance/reference.py`.
void main() {
  test('все файлы векторов домена finance покрыты тестами', () {
    expect(vectorFiles('finance'), [
      'adjustments.json',
      'balances.json',
      'categories.json',
      'category_ids.json',
      'debts.json',
      'dynamics.json',
      'goals.json',
      'integrity.json',
      'merchants.json',
      'monthly.json',
      'scalars.json',
      'work_links.json',
    ]);
  });

  group('scalars', () {
    final cases = loadVectors('finance', 'scalars.json');
    for (final c in cases) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = switch (input['op']) {
          'progress_bp' => progressBasisPoints(
            input['have']! as int,
            input['target']! as int,
          ),
          'opening_instant' => openingInstant(input['date']! as String),
          'end_of_day' => endOfDay(input['date']! as String),
          'month_end' => monthEnd(input['month']! as String),
          'moscow_month' => moscowMonth(input['at']! as String),
          'fold_merchant' => foldMerchant(input['text']! as String),
          'dedup_key' => dedupKey(_map(input['transaction'])),
          'effect' => effect(
            _map(input['transaction']),
            input['account_id']! as String,
          ),
          final op => fail('неизвестная операция $op'),
        };
        expect(actual, c['expected']);
      });
    }
  });

  group('balances', () {
    for (final c in loadVectors('finance', 'balances.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = accountBalances(
          _rows(input['accounts']),
          _rows(input['transactions']),
          _rows(input['checkpoints']),
          at: input['at'] as String?,
        );
        expect(actual, _map(c['expected']));
      });
    }
  });

  group('adjustments', () {
    for (final c in loadVectors('finance', 'adjustments.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = adjustments(
          _map(input['account']),
          _rows(input['transactions']),
          _rows(input['checkpoints']),
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('dynamics', () {
    for (final c in loadVectors('finance', 'dynamics.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = balanceDynamics(
          _rows(input['accounts']),
          _rows(input['transactions']),
          _rows(input['checkpoints']),
          (input['dates']! as List<Object?>).cast<String>(),
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('monthly', () {
    for (final c in loadVectors('finance', 'monthly.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final ids = input['account_ids'] as List<Object?>?;
        final period = input['period'];
        final actual = monthlyTotals(
          _rows(input['transactions']),
          accountIds: ids?.cast<String>(),
          period: period == null ? null : _map(period),
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('categories', () {
    for (final c in loadVectors('finance', 'categories.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final period = input['period'];
        final actual = categoryBreakdown(
          _rows(input['transactions']),
          _rows(input['categories']),
          input['kind']! as String,
          period: period == null ? null : _map(period),
        );
        expect(actual, _map(c['expected']));
      });
    }
  });

  group('merchants', () {
    for (final c in loadVectors('finance', 'merchants.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final period = input['period'];
        final actual = topMerchants(
          _rows(input['transactions']),
          kind: input['kind']! as String,
          period: period == null ? null : _map(period),
          limit: input['limit']! as int,
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('debts', () {
    for (final c in loadVectors('finance', 'debts.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = debtsSummary(
          _rows(input['debts']),
          _rows(input['repayments']),
          today: input['today'] as String?,
        );
        expect(actual, _map(c['expected']));
      });
    }
  });

  group('goals', () {
    for (final c in loadVectors('finance', 'goals.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = goalProgress(
          _map(input['goal']),
          _rows(input['accounts']),
          _rows(input['transactions']),
          _rows(input['checkpoints']),
          _rows(input['debts']),
          _rows(input['repayments']),
          _rows(input['projects']),
          _rows(input['change_requests']),
          _rows(input['allocations']),
        );
        expect(actual, _map(c['expected']));
      });
    }
  });

  group('work_links', () {
    for (final c in loadVectors('finance', 'work_links.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = workPaymentCoverage(
          _rows(input['payments']),
          _rows(input['transactions']),
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('integrity', () {
    for (final c in loadVectors('finance', 'integrity.json')) {
      test(c['name']! as String, () {
        final input = _map(c['input']);
        final actual = integrityProblems(
          _rows(input['categories']),
          _rows(input['transactions']),
          _rows(input['debts']),
          _rows(input['repayments']),
          _rows(input['payments']),
        );
        expect(actual, c['expected']);
      });
    }
  });

  group('category_ids', () {
    final cases = loadVectors('finance', 'category_ids.json');
    for (final c in cases) {
      test(c['name']! as String, () {
        final key = _map(c['input'])['system_key']! as String;
        expect(presetCategoryId(key), c['expected']);
      });
    }

    test('таблица предустановок совпадает с векторами и spec 3.2', () {
      final keys = {
        for (final c in cases) _map(c['input'])['system_key']! as String,
      };
      expect({for (final p in presetCategories) p.key}, keys);
      expect(presetCategories, hasLength(28));
      for (final p in presetCategories) {
        expect(p.id, presetCategoryId(p.key));
        if (p.parentKey != null) {
          final parent = presetCategories.singleWhere(
            (x) => x.key == p.parentKey,
          );
          expect(parent.parentKey, isNull, reason: 'два уровня');
          expect(parent.kind, p.kind);
          expect(p.parentId, parent.id);
        } else {
          expect(p.parentId, isNull);
        }
      }
    });
  });
}
