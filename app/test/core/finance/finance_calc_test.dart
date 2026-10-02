import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/work_receivables.dart';

/// Дополнительные случаи сверх общих векторов: ожидаемые значения получены
/// эталоном `backend/src/tasker/finance/reference.py` (и `work/reference.py`).
const String _fixture = '''
{
 "cats": [
  {
   "id": "food",
   "kind": "expense",
   "parent_id": null
  },
  {
   "id": "cafe",
   "kind": "expense",
   "parent_id": "food"
  },
  {
   "id": "shop",
   "kind": "expense",
   "parent_id": "food"
  },
  {
   "id": "rest",
   "kind": "expense",
   "parent_id": "food"
  },
  {
   "id": "car",
   "kind": "expense",
   "parent_id": null
  }
 ],
 "txs": [
  {
   "id": "1",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 500,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "cafe",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "2",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 500,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "shop",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "3",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 100,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "shop",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "4",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 900,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "rest",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "5",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 50,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "food",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "6",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 70,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "zzz",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "7",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 30,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": null,
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  },
  {
   "id": "8",
   "kind": "expense",
   "account_id": "a",
   "to_account_id": null,
   "amount": 1000,
   "occurred_at": "2026-10-05T09:00:00Z",
   "category_id": "car",
   "merchant": null,
   "status": "confirmed",
   "external_id": null,
   "dedup_hash": null,
   "work_payment_id": null,
   "debt_id": null
  }
 ],
 "breakdown": {
  "total": 3150,
  "groups": [
   {
    "category_id": "food",
    "total": 2050,
    "own": 50,
    "count": 5,
    "children": [
     {
      "category_id": "rest",
      "total": 900,
      "count": 1
     },
     {
      "category_id": "shop",
      "total": 600,
      "count": 2
     },
     {
      "category_id": "cafe",
      "total": 500,
      "count": 1
     }
    ]
   },
   {
    "category_id": "car",
    "total": 1000,
    "own": 1000,
    "count": 1,
    "children": []
   },
   {
    "category_id": null,
    "total": 100,
    "own": 100,
    "count": 2,
    "children": []
   }
  ]
 },
 "projects": [
  {
   "id": "p1",
   "client_id": "c1",
   "status": "active",
   "base_amount": 1000
  },
  {
   "id": "p2",
   "client_id": "c1",
   "status": "completed",
   "base_amount": 500
  },
  {
   "id": "p3",
   "client_id": null,
   "status": "lead",
   "base_amount": 300
  },
  {
   "id": "p4",
   "client_id": "c2",
   "status": null,
   "base_amount": 5000
  },
  {
   "id": "p5",
   "client_id": null,
   "status": "paused",
   "base_amount": 5000
  },
  {
   "id": "p6",
   "client_id": "c2",
   "status": "cancelled",
   "base_amount": 999
  },
  {
   "id": "p7",
   "client_id": "c3",
   "status": "active",
   "base_amount": 5000
  }
 ],
 "crs": [
  {
   "id": "cr1",
   "project_id": "p1",
   "amount": 400,
   "status": "closed"
  },
  {
   "id": "cr2",
   "project_id": "p1",
   "amount": 999,
   "status": "cancelled"
  }
 ],
 "allocs": [
  {
   "project_id": "p1",
   "amount": 100
  },
  {
   "project_id": "p2",
   "amount": 700
  },
  {
   "project_id": "p7",
   "amount": 5000
  }
 ],
 "receivables": {
  "total": 11300,
  "clients": [
   {
    "client_id": "c2",
    "remaining": 5000,
    "projects": [
     {
      "id": "p4",
      "remaining": 5000
     }
    ]
   },
   {
    "client_id": null,
    "remaining": 5000,
    "projects": [
     {
      "id": "p5",
      "remaining": 5000
     }
    ]
   },
   {
    "client_id": "c1",
    "remaining": 1300,
    "projects": [
     {
      "id": "p1",
      "remaining": 1300
     }
    ]
   }
  ]
 }
}
''';

Row _map(Object? v) => (v! as Map).cast<String, Object?>();

Rows _rows(Object? v) => [for (final r in v! as List<Object?>) _map(r)];

void main() {
  final data = _map(jsonDecode(_fixture));

  test(
    'разбивка по категориям: несколько подкатегорий, мусорная категория',
    () {
      final actual = categoryBreakdown(
        _rows(data['txs']),
        _rows(data['cats']),
        'expense',
      );
      expect(actual, _map(data['breakdown']));
    },
  );

  test('дебиторка Работы: доп. работы, статусы, переплата, порядок', () {
    final actual = workReceivables(
      _rows(data['projects']),
      _rows(data['crs']),
      _rows(data['allocs']),
    );
    expect(actual, _map(data['receivables']));
  });

  test('цель: слагаемое receivables с client_ids и неизвестный счёт', () {
    final goal = {
      'id': 'g',
      'target_amount': 10000,
      'formula': [
        {
          'kind': 'receivables',
          'sign': '+',
          'client_ids': ['c2', 'zz'],
        },
        {
          'kind': 'accounts',
          'sign': '-',
          'account_ids': ['nope', 'nope'],
        },
        {'kind': 'my_debts', 'sign': '-'},
      ],
    };
    final actual = goalProgress(
      goal,
      const [],
      const [],
      const [],
      [
        {'id': 'd1', 'direction': 'i_owe', 'amount': 300, 'due_date': null},
      ],
      const [],
      _rows(data['projects']),
      _rows(data['crs']),
      _rows(data['allocs']),
    );
    expect(actual['have'], 5000 - 300);
    expect(actual['missing'], 10000 - 4700);
    expect(actual['reached'], isFalse);
    expect(actual['surplus'], 0);
    expect(actual['progress_bp'], 4700);
  });

  group('время', () {
    test('доли секунды отбрасываются, смещение и пробел понимаются', () {
      expect(
        instantSeconds('2026-10-05T09:00:00.999Z'),
        instantSeconds('2026-10-05T09:00:00Z'),
      );
      expect(
        instantSeconds('2026-10-05T12:00:00+03:00'),
        instantSeconds('2026-10-05T09:00:00Z'),
      );
      expect(
        instantSeconds('2026-10-05 09:00:00Z'),
        instantSeconds('2026-10-05T09:00:00Z'),
      );
      expect(
        instantSeconds('2026-10-05T09:00:00'),
        instantSeconds('2026-10-05T09:00:00Z'),
      );
      expect(() => instantSeconds('вчера'), throwsFormatException);
      expect(
        formatSeconds(instantSeconds('2026-10-05T09:00:00.5Z')),
        '2026-10-05T09:00:00Z',
      );
      expect(financeEpochSeconds, instantSeconds(financeEpoch));
    });

    test('московские границы', () {
      expect(moscowDate('2026-12-31T21:00:00Z'), '2027-01-01');
      expect(moscowDate('2026-12-31T20:59:59Z'), '2026-12-31');
      expect(moscowMonth('2026-12-31T21:00:00Z'), '2027-01');
      expect(openingInstant('2027-01-01'), '2026-12-31T21:00:00Z');
      expect(endOfDay('2026-12-31'), '2026-12-31T20:59:59Z');
      expect(monthEnd('2026-12'), '2026-12-31');
    });

    test('период', () {
      expect(inPeriod('2026-10-05', null), isTrue);
      expect(inPeriod(null, null), isTrue);
      expect(inPeriod(null, {'from': null, 'to': null}), isFalse);
      expect(
        inPeriod('2026-10-05', {'from': '2026-10-05', 'to': '2026-10-05'}),
        isTrue,
      );
      expect(
        inPeriod('2026-10-04', {'from': '2026-10-05', 'to': null}),
        isFalse,
      );
      expect(
        inPeriod('2026-10-06', {'from': null, 'to': '2026-10-05'}),
        isFalse,
      );
    });
  });
}
