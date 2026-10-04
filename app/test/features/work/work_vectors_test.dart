import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

List<_Json> _rows(Object? value) => [
  for (final r in (value as List<Object?>? ?? const [])) r! as _Json,
];

List<WorkProject> _projects(Object? v) => [
  for (final r in _rows(v)) WorkProject.fromRow(r),
];
List<ChangeRequest> _crs(Object? v) => [
  for (final r in _rows(v)) ChangeRequest.fromRow(r),
];
List<Payment> _payments(Object? v) => [
  for (final r in _rows(v)) Payment.fromRow(r),
];
List<Allocation> _allocations(Object? v) => [
  for (final r in _rows(v)) Allocation.fromRow(r),
];
List<TimeEntry> _entries(Object? v) => [
  for (final r in _rows(v)) TimeEntry.fromRow(r),
];

DatePeriod? _period(Object? v) {
  if (v == null) return null;
  final m = v as _Json;
  return DatePeriod(from: m['from'] as String?, to: m['to'] as String?);
}

_Json _summaryJson(ProjectSummary s) => {
  'total': s.total,
  'received': s.received,
  'remaining': s.remaining,
  'overpaid': s.overpaid,
  'paid_bp': s.paidBp,
  'base_received': s.baseReceived,
  'base_remaining': s.baseRemaining,
  'change_requests': [
    for (final c in s.changeRequests)
      {
        'id': c.id,
        'amount': c.amount,
        'received': c.received,
        'remaining': c.remaining,
      },
  ],
};

_Json _receivablesJson(Receivables r) => {
  'total': r.total,
  'clients': [
    for (final c in r.clients)
      {
        'client_id': c.clientId,
        'remaining': c.remaining,
        'projects': [
          for (final p in c.projects) {'id': p.id, 'remaining': p.remaining},
        ],
      },
  ],
};

_Json _incomeRowJson(ProjectIncome p) => {
  'id': p.id,
  'seconds': p.seconds,
  'received': p.received,
  'accrued': p.accrued,
  'per_hour_fact': p.perHourFact,
  'per_hour_accrued': p.perHourAccrued,
};

_Json _incomeJson(IncomeReport r) => {
  'seconds': r.seconds,
  'received': r.received,
  'accrued': r.accrued,
  'per_hour_fact': r.perHourFact,
  'per_hour_accrued': r.perHourAccrued,
  'projects': [for (final p in r.projects) _incomeRowJson(p)],
};

Object? _scalar(_Json input) {
  switch (input['op']) {
    case 'paid_bp':
      return paidBasisPoints(input['received']! as int, input['total']! as int);
    case 'per_hour':
      return perHour(input['amount']! as int, input['seconds']! as int);
    case 'hourly_billable':
      return hourlyBillable(input['rate']! as int, input['seconds']! as int);
    case 'seconds':
      return entrySeconds(TimeEntry.fromRow(input['entry']! as _Json));
    case 'moscow_date':
      return moscowDate(DateTime.parse(input['at']! as String));
    case 'moscow_month':
      return moscowMonth(DateTime.parse(input['at']! as String));
  }
  fail('Неизвестная операция ${input['op']}');
}

/// Общие векторы расчётов «Работы» (`shared-test-vectors/work/`): Dart
/// обязан пройти каждый случай каждого файла; ожидаемое — эталон Python.
void main() {
  test('каталог векторов: все шесть файлов и не меньше 60 случаев', () {
    expect(vectorFiles('work'), [
      'income.json',
      'integrity.json',
      'monthly.json',
      'project_summary.json',
      'receivables.json',
      'scalars.json',
    ]);
    var total = 0;
    for (final f in vectorFiles('work')) {
      total += loadVectors('work', f).length;
    }
    expect(total, greaterThanOrEqualTo(60));
  });

  group('scalars.json', () {
    for (final c in loadVectors('work', 'scalars.json')) {
      test(c['name']! as String, () {
        expect(_scalar(c['input']! as _Json), c['expected']);
      });
    }
  });

  group('project_summary.json', () {
    for (final c in loadVectors('work', 'project_summary.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final s = projectSummary(
          WorkProject.fromRow(i['project']! as _Json),
          _crs(i['change_requests']),
          _allocations(i['allocations']),
        );
        expect(_summaryJson(s), c['expected']);
      });
    }
  });

  group('receivables.json', () {
    for (final c in loadVectors('work', 'receivables.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = receivables(
          _projects(i['projects']),
          _crs(i['change_requests']),
          _allocations(i['allocations']),
        );
        expect(_receivablesJson(r), c['expected']);
      });
    }
  });

  group('income.json', () {
    for (final c in loadVectors('work', 'income.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = income(
          projects: _projects(i['projects']),
          changeRequests: _crs(i['change_requests']),
          payments: _payments(i['payments']),
          allocations: _allocations(i['allocations']),
          timeEntries: _entries(i['time_entries']),
          period: _period(i['period']),
          projectId: i['project_id'] as String?,
        );
        expect(_incomeJson(r), c['expected']);
      });
    }
  });

  group('monthly.json', () {
    for (final c in loadVectors('work', 'monthly.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = monthlyReceived(
          _payments(i['payments']),
          _allocations(i['allocations']),
          projectId: i['project_id'] as String?,
        );
        expect([
          for (final m in r)
            {
              'month': m.month,
              'received': m.received,
              'unallocated': m.unallocated,
            },
        ], c['expected']);
      });
    }
  });

  group('integrity.json', () {
    for (final c in loadVectors('work', 'integrity.json')) {
      test(c['name']! as String, () {
        final i = c['input']! as _Json;
        final r = integrityProblems(
          _crs(i['change_requests']),
          _payments(i['payments']),
          _allocations(i['allocations']),
        );
        expect([
          for (final p in r) {'code': p.code, 'id': p.id, 'excess': p.excess},
        ], c['expected']);
      });
    }
  });
}
