import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart' show moscowMonth;
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

List<_Json> _rows(Object? value) => [
  for (final r in (value as List<Object?>? ?? const [])) r! as _Json,
];

List<Account> _accounts(Object? v) => [
  for (final r in _rows(v)) Account.fromRow(r),
];
List<FinTransaction> _txs(Object? v) => [
  for (final r in _rows(v)) FinTransaction.fromRow(r),
];
List<BalanceCheckpoint> _cps(Object? v) => [
  for (final r in _rows(v)) BalanceCheckpoint.fromRow(r),
];
List<FinCategory> _cats(Object? v) => [
  for (final r in _rows(v)) FinCategory.fromRow(r),
];
List<Debt> _debts(Object? v) => [for (final r in _rows(v)) Debt.fromRow(r)];
List<DebtRepayment> _repayments(Object? v) => [
  for (final r in _rows(v)) DebtRepayment.fromRow(r),
];
List<Payment> _payments(Object? v) => [
  for (final r in _rows(v)) Payment.fromRow(r),
];

DatePeriod? _period(Object? v) {
  if (v == null) return null;
  final m = v as _Json;
  return DatePeriod(from: m['from'] as String?, to: m['to'] as String?);
}

DateTime? _at(Object? v) => v == null ? null : parseFinanceInstant(v);

Object? _scalar(_Json input) {
  switch (input['op']) {
    case 'progress_bp':
      return progressBasisPoints(
        input['have']! as int,
        input['target']! as int,
      );
    case 'opening_instant':
      return financeInstantText(openingInstant(input['date']! as String));
    case 'end_of_day':
      return financeInstantText(endOfDay(input['date']! as String));
    case 'month_end':
      return monthEnd(input['month']! as String);
    case 'moscow_month':
      return moscowMonth(DateTime.parse(input['at']! as String));
    case 'fold_merchant':
      return foldMerchant(input['text']! as String);
    case 'dedup_key':
      return dedupKey(FinTransaction.fromRow(input['transaction']! as _Json));
    case 'effect':
      return effect(
        FinTransaction.fromRow(input['transaction']! as _Json),
        input['account_id']! as String,
      );
  }
  fail('Неизвестная операция ${input['op']}');
}

/// Общие векторы расчётов «Финансов» (`shared-test-vectors/finance/`): Dart
/// обязан пройти каждый случай каждого файла; ожидаемое — эталон Python.
void main() {
  test('каталог векторов: все файлы домена и не меньше 70 случаев', () {
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
    var total = 0;
    for (final f in vectorFiles('finance')) {
      total += loadVectors('finance', f).length;
    }
    expect(total, greaterThanOrEqualTo(70));
  });

  group('scalars.json', () {
    for (final c in loadVectors('finance', 'scalars.json')) {
      test(c['name']! as String, () {
        expect(_scalar(c['input']! as _Json), c['expected']);
      });
    }
  });

  group('balances.json', () {
    for (final c in loadVectors('finance', 'balances.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = accountBalances(
          _accounts(i['accounts']),
          _txs(i['transactions']),
          _cps(i['checkpoints']),
          at: _at(i['at']),
        );
        expect({
          'accounts': [
            for (final a in r.accounts)
              {'id': a.id, 'balance': a.balance, 'in_total': a.inTotal},
          ],
          'total': r.total,
        }, c['expected']);
      });
    }
  });

  group('adjustments.json', () {
    for (final c in loadVectors('finance', 'adjustments.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = adjustments(
          Account.fromRow(i['account']! as _Json),
          _txs(i['transactions']),
          _cps(i['checkpoints']),
        );
        expect([
          for (final a in r)
            {
              'checkpoint_id': a.checkpointId,
              'checked_at': financeInstantText(a.checkedAt),
              'actual': a.actual,
              'expected': a.expected,
              'adjustment': a.adjustment,
            },
        ], c['expected']);
      });
    }
  });

  group('monthly.json', () {
    for (final c in loadVectors('finance', 'monthly.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final ids = i['account_ids'];
        final r = monthlyTotals(
          _txs(i['transactions']),
          accountIds: ids == null ? null : (ids as List<Object?>).cast(),
          period: _period(i['period']),
        );
        expect([
          for (final m in r)
            {
              'month': m.month,
              'income': m.income,
              'expense': m.expense,
              'net': m.net,
            },
        ], c['expected']);
      });
    }
  });

  group('categories.json', () {
    for (final c in loadVectors('finance', 'categories.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = categoryBreakdown(
          _txs(i['transactions']),
          _cats(i['categories']),
          TxKind.parse(i['kind']),
          period: _period(i['period']),
        );
        expect({
          'total': r.total,
          'groups': [
            for (final g in r.groups)
              {
                'category_id': g.categoryId,
                'total': g.total,
                'own': g.own,
                'count': g.count,
                'children': [
                  for (final k in g.children)
                    {
                      'category_id': k.categoryId,
                      'total': k.total,
                      'count': k.count,
                    },
                ],
              },
          ],
        }, c['expected']);
      });
    }
  });

  group('merchants.json', () {
    for (final c in loadVectors('finance', 'merchants.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = topMerchants(
          _txs(i['transactions']),
          kind: TxKind.parse(i['kind']),
          period: _period(i['period']),
          limit: i['limit']! as int,
        );
        expect([
          for (final m in r)
            {'merchant': m.merchant, 'total': m.total, 'count': m.count},
        ], c['expected']);
      });
    }
  });

  group('dynamics.json', () {
    for (final c in loadVectors('finance', 'dynamics.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = balanceDynamics(
          _accounts(i['accounts']),
          _txs(i['transactions']),
          _cps(i['checkpoints']),
          (i['dates']! as List<Object?>).cast<String>(),
        );
        expect([
          for (final p in r) {'date': p.date, 'total': p.total},
        ], c['expected']);
      });
    }
  });

  group('debts.json', () {
    for (final c in loadVectors('finance', 'debts.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = debtsSummary(
          _debts(i['debts']),
          _repayments(i['repayments']),
          today: i['today'] as String?,
        );
        expect({
          'owed_to_me': r.owedToMe,
          'i_owe': r.iOwe,
          'debts': [
            for (final d in r.debts)
              {
                'id': d.id,
                'direction': d.direction.wire,
                'amount': d.amount,
                'repaid': d.repaid,
                'remaining': d.remaining,
                'overpaid': d.overpaid,
                'status': d.status.wire,
                'overdue': d.overdue,
              },
          ],
        }, c['expected']);
      });
    }
  });

  group('goals.json', () {
    for (final c in loadVectors('finance', 'goals.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = goalProgress(
          Goal.fromRow(i['goal']! as _Json),
          accounts: _accounts(i['accounts']),
          transactions: _txs(i['transactions']),
          checkpoints: _cps(i['checkpoints']),
          debts: _debts(i['debts']),
          repayments: _repayments(i['repayments']),
          projects: [
            for (final p in _rows(i['projects'])) WorkProject.fromRow(p),
          ],
          changeRequests: [
            for (final p in _rows(i['change_requests']))
              ChangeRequest.fromRow(p),
          ],
          allocations: [
            for (final p in _rows(i['allocations'])) Allocation.fromRow(p),
          ],
        );
        expect({
          'have': r.have,
          'target': r.target,
          'missing': r.missing,
          'reached': r.reached,
          'surplus': r.surplus,
          'progress_bp': r.progressBp,
          'terms': [
            for (final t in r.terms) {'kind': t.kind.wire, 'value': t.value},
          ],
        }, c['expected']);
      });
    }
  });

  group('work_links.json', () {
    for (final c in loadVectors('finance', 'work_links.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = workPaymentCoverage(
          _payments(i['payments']),
          _txs(i['transactions']),
        );
        expect([
          for (final l in r)
            {
              'payment_id': l.paymentId,
              'amount': l.amount,
              'linked': l.linked,
              'unlinked': l.unlinked,
            },
        ], c['expected']);
      });
    }
  });

  group('integrity.json', () {
    for (final c in loadVectors('finance', 'integrity.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = integrityProblems(
          categories: _cats(i['categories']),
          transactions: _txs(i['transactions']),
          debts: _debts(i['debts']),
          repayments: _repayments(i['repayments']),
          payments: _payments(i['payments']),
        );
        expect([
          for (final p in r) {'code': p.code, 'id': p.id, 'excess': p.excess},
        ], c['expected']);
      });
    }
  });

  group('category_ids.json', () {
    final cases = loadVectors('finance', 'category_ids.json');
    for (final c in cases) {
      test(c['name']! as String, () {
        final key = (c['input']! as _Json)['system_key']! as String;
        expect(categoryPresetId(key), c['expected']);
      });
    }

    test('таблица предустановок совпадает с векторами: ключи, родители', () {
      final keys = {
        for (final c in cases) (c['input']! as _Json)['system_key']! as String,
      };
      expect({for (final p in categoryPresets) p.key}, keys);
      expect(categoryPresets, hasLength(28));
      final byKey = {for (final p in categoryPresets) p.key: p};
      for (final p in categoryPresets) {
        if (p.parentKey != null) {
          expect(byKey[p.parentKey], isNotNull, reason: p.key);
          expect(byKey[p.parentKey]!.kind, p.kind);
          expect(byKey[p.parentKey]!.parentKey, isNull);
        }
      }
      expect(
        categoryPresets.where((p) => p.kind == CategoryKind.expense),
        hasLength(23),
      );
      expect(
        categoryPresets.where((p) => p.kind == CategoryKind.income),
        hasLength(5),
      );
    });
  });
}
