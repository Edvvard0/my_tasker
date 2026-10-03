import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/widgets/charts.dart';

import '../../support/finance_env.dart' show uuid;

const _cash = 'a1';
const _card = 'a2';

Json _account(String id, {int opening = 0, String date = '2026-01-01'}) =>
    Account(
      id: id,
      name: id,
      kind: AccountKind.debitCard,
      openingBalance: opening,
      openingDate: date,
    ).toRow();

int _n = 0;

Json _tx(
  String at,
  int amount, {
  TransactionKind kind = TransactionKind.expense,
  String account = _cash,
  String? to,
  String? category,
  String? merchant,
  String? debtId,
  TransactionStatus status = TransactionStatus.confirmed,
}) => FinanceTransaction(
  id: uuid(++_n),
  kind: kind,
  accountId: account,
  toAccountId: to,
  amount: amount,
  occurredAt: DateTime.parse(at),
  categoryId: category,
  merchant: merchant,
  debtId: debtId,
  status: status,
).toRow();

Json _category(
  String id,
  String name, {
  String? parent,
  String kind = 'expense',
}) => FinanceCategory(
  id: id,
  name: name,
  kind: CategoryKind.parse(kind),
  parentId: parent,
).toRow();

AnalyticsReport _report(
  List<Json> transactions, {
  AnalyticsPreset preset = AnalyticsPreset.quarter,
  String today = '2026-10-05',
  List<Json>? accounts,
  List<Json> categories = const [],
  List<Json> checkpoints = const [],
}) => AnalyticsReport.compute(
  preset: preset,
  today: today,
  accounts: accounts ?? [_account(_cash), _account(_card)],
  categories: categories,
  transactions: transactions,
  checkpoints: checkpoints,
);

void main() {
  setUp(() => _n = 0);

  group('период', () {
    test('варианты: с первого числа месяца по конец текущего', () {
      AnalyticsPeriod p(AnalyticsPreset x, String today) =>
          AnalyticsPeriod.of(x, today);
      expect(p(AnalyticsPreset.month, '2026-10-05').from, '2026-10-01');
      expect(p(AnalyticsPreset.month, '2026-10-05').to, '2026-10-31');
      expect(p(AnalyticsPreset.quarter, '2026-10-05').from, '2026-08-01');
      expect(p(AnalyticsPreset.half, '2026-10-05').from, '2026-05-01');
      expect(p(AnalyticsPreset.year, '2026-10-05').from, '2025-11-01');
      expect(p(AnalyticsPreset.year, '2026-02-10').from, '2025-03-01');
      expect(p(AnalyticsPreset.quarter, '2026-02-10').to, '2026-02-28');
      expect(p(AnalyticsPreset.quarter, '2028-02-10').to, '2028-02-29');
      expect(p(AnalyticsPreset.all, '2026-10-05').from, isNull);
      expect(p(AnalyticsPreset.all, '2026-10-05').to, isNull);
      expect(p(AnalyticsPreset.all, '2026-10-05').toJson(), {
        'from': null,
        'to': null,
      });
    });

    test('сдвиг и диапазон месяцев через границу года', () {
      expect(addMonths('2026-01', -1), '2025-12');
      expect(addMonths('2026-12', 1), '2027-01');
      expect(addMonths('2026-10', -22), '2024-12');
      expect(monthRange('2025-11', '2026-02'), [
        '2025-11',
        '2025-12',
        '2026-01',
        '2026-02',
      ]);
      expect(monthRange('2026-03', '2026-02'), isEmpty);
    });
  });

  group('граница месяца по Москве (spec 5.3)', () {
    final sep = _tx('2026-09-30T20:59:59Z', 100000); // 23:59:59 МСК, сентябрь
    final oct1 = _tx('2026-09-30T21:00:00Z', 200000); // 00:00:00 МСК, октябрь
    final oct2 = _tx('2026-09-30T21:30:00Z', 400000); // 00:30 МСК, октябрь
    final inc = _tx(
      '2026-09-30T21:00:00Z',
      900000,
      kind: TransactionKind.income,
    );

    test('расход в 23:59:59 30 сентября — сентябрь, в 00:00:00 — октябрь', () {
      final r = _report([sep, oct1, oct2, inc]);
      final byMonth = {for (final m in r.months) m.month: m};
      expect(byMonth['2026-09']!.expense, 100000);
      expect(byMonth['2026-09']!.income, 0);
      expect(byMonth['2026-10']!.expense, 600000);
      expect(byMonth['2026-10']!.income, 900000);
      expect(byMonth['2026-10']!.net, 300000);
    });

    test('период «Месяц» режет по московской дате, а не по UTC', () {
      final r = _report([sep, oct1, oct2], preset: AnalyticsPreset.month);
      expect(r.months.map((m) => m.month), ['2026-10']);
      expect(r.expense, 600000);
      expect(r.income, 0);
      expect(r.net, -600000);
      // в сентябрьском «сегодня» то же событие уже сентябрьское
      final back = _report(
        [sep, oct1, oct2],
        preset: AnalyticsPreset.month,
        today: '2026-09-30',
      );
      expect(back.expense, 100000);
    });

    test('категории и мерчанты тоже по московскому месяцу', () {
      final cat = [_category('c1', 'Еда')];
      final rows = [
        _tx('2026-09-30T20:59:59Z', 100000, category: 'c1', merchant: 'Лавка'),
        _tx('2026-09-30T21:00:00Z', 300000, category: 'c1', merchant: 'Лавка'),
      ];
      final r = _report(rows, preset: AnalyticsPreset.month, categories: cat);
      expect(r.expenses.total, 300000);
      expect(r.expenses.groups.single.count, 1);
      expect(r.merchantsExpense.single.total, 300000);
      expect(r.merchantsExpense.single.count, 1);
    });

    test('динамика баланса: операция 00:30 МСК 1 октября ещё не в балансе на '
        'конец сентября', () {
      final r = _report(
        [oct2],
        accounts: [_account(_cash, opening: 1000000)],
        preset: AnalyticsPreset.month,
      );
      expect(r.dynamics.map((p) => p.date), ['2026-09-30', '2026-10-05']);
      expect(r.dynamics.first.total, 1000000);
      expect(r.dynamics.last.total, 600000);
      expect(r.balances.total, 600000);
    });
  });

  group('пропуски месяцев заполняет клиент', () {
    test('3 мес: месяц без операций — нули между месяцами с данными', () {
      final r = _report([
        _tx('2026-08-10T10:00:00Z', 100000),
        _tx('2026-10-02T10:00:00Z', 50000, kind: TransactionKind.income),
      ]);
      expect(r.months.map((m) => m.month), ['2026-08', '2026-09', '2026-10']);
      expect(r.months[1].income, 0);
      expect(r.months[1].expense, 0);
      expect(r.income, 50000);
      expect(r.expense, 100000);
      expect(r.net, -50000);
      expect(r.hasOperations, isTrue);
    });

    test('год: 12 месяцев, даже если операций нет совсем', () {
      final r = _report(const [], preset: AnalyticsPreset.year);
      expect(r.months, hasLength(12));
      expect(r.months.first.month, '2025-11');
      expect(r.months.last.month, '2026-10');
      expect(r.hasOperations, isFalse);
      expect(r.income, 0);
      expect(r.net, 0);
    });

    test(
      '«Всё»: от первого месяца с данными до текущего; без данных — пусто',
      () {
        final r = _report([
          _tx('2026-06-10T10:00:00Z', 100000),
        ], preset: AnalyticsPreset.all);
        expect(r.months.map((m) => m.month), [
          '2026-06',
          '2026-07',
          '2026-08',
          '2026-09',
          '2026-10',
        ]);
        expect(_report(const [], preset: AnalyticsPreset.all).months, isEmpty);
      },
    );

    test('«Всё»: операция в будущем месяце входит в список', () {
      final r = _report([
        _tx('2026-12-10T10:00:00Z', 100000),
      ], preset: AnalyticsPreset.all);
      expect(r.months.last.month, '2026-12');
      expect(r.months.first.month, '2026-12');
    });
  });

  group('что считается', () {
    test('не доход и не расход: переводы, движение долгов, черновики', () {
      final r = _report([
        _tx('2026-10-02T10:00:00Z', 100000),
        _tx(
          '2026-10-02T10:00:00Z',
          500000,
          kind: TransactionKind.transfer,
          to: _card,
        ),
        _tx('2026-10-02T10:00:00Z', 700000, debtId: uuid(99)),
        _tx(
          '2026-10-02T10:00:00Z',
          800000,
          kind: TransactionKind.income,
          debtId: uuid(99),
        ),
        _tx('2026-10-02T10:00:00Z', 900000, status: TransactionStatus.draft),
        _tx(
          '2026-10-02T10:00:00Z',
          900000,
          status: TransactionStatus.needsReview,
        ),
      ], preset: AnalyticsPreset.month);
      expect(r.expense, 100000);
      expect(r.income, 0);
      expect(r.expenses.total, 100000);
      expect(r.incomes.isEmpty, isTrue);
      // переводы и долги двигают баланс, но не аналитику
      expect(r.balances.total, -100000 - 700000 + 800000);
    });

    test('разбивка: подкатегории, «без категории», удалённая категория', () {
      final categories = [
        _category('food', 'Еда'),
        _category('cafe', 'Кафе', parent: 'food'),
        _category('shop', 'Магазины', parent: 'food'),
        _category('fun', 'Досуг'),
        _category('pay', 'Зарплата', kind: 'income'),
      ];
      final r = _report([
        _tx('2026-10-02T10:00:00Z', 300000, category: 'food'),
        _tx('2026-10-02T11:00:00Z', 200000, category: 'cafe'),
        _tx('2026-10-02T12:00:00Z', 100000, category: 'shop'),
        _tx('2026-10-02T13:00:00Z', 150000, category: 'fun'),
        _tx('2026-10-02T14:00:00Z', 50000),
        _tx('2026-10-02T15:00:00Z', 70000, category: 'удалена'),
        _tx(
          '2026-10-03T10:00:00Z',
          1000000,
          kind: TransactionKind.income,
          category: 'pay',
        ),
      ], categories: categories);
      final e = r.expenses;
      expect(e.total, 870000);
      expect(e.groups.map((g) => g.categoryId), ['food', 'fun', null]);
      final food = e.groups.first;
      expect(food.total, 600000);
      expect(food.own, 300000);
      expect(food.count, 3);
      expect(food.children.map((c) => c.categoryId), ['cafe', 'shop']);
      expect(food.children.map((c) => c.total), [200000, 100000]);
      final none = e.groups.last;
      expect(none.total, 120000, reason: '«без категории» + удалённая');
      expect(none.count, 2);
      expect(none.children, isEmpty);
      expect(r.incomes.groups.single.categoryId, 'pay');
      expect(r.incomes.total, 1000000);
    });

    test('топ мерчантов: слияние написаний, порядок, лимит 10', () {
      final rows = [
        _tx('2026-10-02T10:00:00Z', 100000, merchant: 'Пятёрочка'),
        _tx('2026-10-03T10:00:00Z', 50000, merchant: '  ПЯТЁРОЧКА '),
        _tx('2026-10-04T10:00:00Z', 90000, merchant: 'Яндекс Go'),
        _tx('2026-10-04T11:00:00Z', 10000),
        for (var i = 0; i < 12; i++)
          _tx('2026-10-0${i % 5 + 1}T12:00:00Z', 1000 + i, merchant: 'M$i'),
        _tx(
          '2026-10-02T10:00:00Z',
          300000,
          kind: TransactionKind.income,
          merchant: 'Creora',
        ),
      ];
      final r = _report(rows);
      expect(r.merchantsExpense, hasLength(10));
      expect(r.merchantsExpense.first.merchant, 'Пятёрочка');
      expect(r.merchantsExpense.first.total, 150000);
      expect(r.merchantsExpense.first.count, 2);
      expect(r.merchantsExpense[1].merchant, 'Яндекс Go');
      expect(r.merchantsIncome.single.merchant, 'Creora');
    });

    test('остатки по счетам и общий баланс считает домен', () {
      final r = _report(
        [_tx('2026-10-02T10:00:00Z', 100000, account: _card)],
        accounts: [
          _account(_cash, opening: 500000),
          _account(_card, opening: 300000),
        ],
      );
      expect(r.balances.of(_cash), 500000);
      expect(r.balances.of(_card), 200000);
      expect(r.balances.total, 700000);
    });
  });

  group('динамика общего баланса: концы месяцев и сегодня', () {
    test('3 мес на 5 октября: конец июля, августа, сентября и сегодня', () {
      final r = _report(const []);
      expect(r.dynamics.map((p) => p.date), [
        '2026-07-31',
        '2026-08-31',
        '2026-09-30',
        '2026-10-05',
      ]);
    });

    test('в последний день месяца «сегодня» — конец месяца, без дубля', () {
      final r = _report(
        const [],
        today: '2026-09-30',
        preset: AnalyticsPreset.month,
      );
      expect(r.dynamics.map((p) => p.date), ['2026-08-31', '2026-09-30']);
    });

    test('счёт, открытый позже даты, даёт 0; значения по датам', () {
      final r = _report(
        [_tx('2026-08-20T10:00:00Z', 100000)],
        accounts: [_account(_cash, opening: 1000000, date: '2026-08-15')],
      );
      expect(r.dynamics.map((p) => p.total), [0, 900000, 900000, 900000]);
    });

    test('«Всё»: от первого месяца данных; не больше 24 точек', () {
      final r = _report(
        [_tx('2015-03-10T10:00:00Z', 100000)],
        preset: AnalyticsPreset.all,
        accounts: [_account(_cash, date: '2015-01-01')],
      );
      expect(r.dynamics, hasLength(maxDynamicsPoints));
      expect(r.dynamics.last.date, '2026-10-05');
      expect(r.dynamics[maxDynamicsPoints - 2].date, '2026-09-30');
      // без данных вообще — месяц перед текущим и сегодня
      final empty = _report(
        const [],
        preset: AnalyticsPreset.all,
        accounts: const [],
      );
      expect(empty.dynamics.map((p) => p.date), ['2026-09-30', '2026-10-05']);
    });

    test('точка сверки меняет динамику', () {
      final r = _report(
        const [],
        accounts: [_account(_cash, opening: 100000)],
        checkpoints: [
          BalanceCheckpoint(
            id: uuid(500),
            accountId: _cash,
            checkedAt: DateTime.utc(2026, 9, 10, 9),
            actualBalance: 250000,
          ).toRow(),
        ],
      );
      expect(r.dynamics.map((p) => p.total), [100000, 100000, 250000, 250000]);
    });
  });

  group('шкалы графиков', () {
    test('niceCeiling: 1, 2 или 5 × 10^k не меньше значения', () {
      expect(niceCeiling(0), 100000);
      expect(niceCeiling(-5), 100000);
      expect(niceCeiling(1), 1);
      expect(niceCeiling(3), 5);
      expect(niceCeiling(5), 5);
      expect(niceCeiling(6), 10);
      expect(niceCeiling(1250000), 2000000);
      expect(niceCeiling(2000000), 2000000);
      expect(niceCeiling(2000001), 5000000);
      expect(niceCeiling(99999999999999), 100000000000000);
    });
  });
}
