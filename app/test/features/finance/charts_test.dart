import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/charts.dart';

/// Графики Финансов рисуются собственными `CustomPainter`: проверяем, что
/// они строятся на любых данных (пусто, одна точка, отрицательные значения,
/// много месяцев) и подписывают доступно; форматы подписей осей.
Future<void> _pump(WidgetTester tester, Widget chart, {Size? size}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size ?? const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: Center(child: chart)),
    ),
  );
}

List<MonthTotals> _months(int n, {int income = 100000, int expense = 60000}) =>
    [
      for (var i = 0; i < n; i++)
        MonthTotals(
          month: addMonths('2025-09', i),
          income: income * (i + 1),
          expense: i.isEven ? expense : 0,
        ),
    ];

void main() {
  group('подписи осей', () {
    test('сокращённые суммы: «к» и «М», одна цифра, без «,0»', () {
      expect(axisAmountText(0), '0');
      expect(axisAmountText(99900), '999');
      expect(axisAmountText(100000), '1к');
      expect(axisAmountText(1250000), '12,5к');
      expect(axisAmountText(20500000), '205к');
      expect(axisAmountText(99999999), '999,9к');
      expect(axisAmountText(100000000), '1М');
      expect(axisAmountText(120000000), '1,2М');
      expect(axisAmountText(-1250000), '−12,5к');
      expect(axisAmountText(-50), '0');
      expect(axisAmountText(-5000), '−50');
    });

    test('названия месяцев', () {
      expect(axisMonthText('2026-01'), 'янв');
      expect(axisMonthText('2026-09'), 'сен');
      expect(axisMonthText('2026-12'), 'дек');
      expect(axisMonthNames, hasLength(12));
    });
  });

  group('столбики по месяцам', () {
    for (final n in [1, 3, 6, 9, 13, 24]) {
      testWidgets('$n мес.: строится, подпись для скринридера', (tester) async {
        final months = _months(n);
        await _pump(
          tester,
          MonthBarsChart(months: months, currentMonth: months.last.month),
        );
        expect(find.byKey(const Key('chart-months')), findsOneWidget);
        expect(tester.takeException(), isNull);
        final semantics = tester.getSemantics(
          find.byKey(const Key('chart-months')),
        );
        expect(semantics.label, contains('Доходы и расходы за $n мес.'));
      });
    }

    testWidgets('нет данных, нули, текущий месяц вне списка', (tester) async {
      await _pump(
        tester,
        const MonthBarsChart(months: [], currentMonth: '2026-10'),
      );
      expect(tester.takeException(), isNull);
      final semantics = tester.getSemantics(
        find.byKey(const Key('chart-months')),
      );
      expect(semantics.label, 'Нет данных по месяцам');
      await _pump(
        tester,
        const MonthBarsChart(
          months: [
            MonthTotals(month: '2026-08', income: 0, expense: 0),
            MonthTotals(month: '2026-09', income: 1, expense: 99),
          ],
          currentMonth: '2030-01',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('десктоп: график выше', (tester) async {
      await _pump(
        tester,
        MonthBarsChart(months: _months(6), currentMonth: '2026-02'),
        size: const Size(1440, 900),
      );
      expect(tester.getSize(find.byKey(const Key('chart-months'))).height, 240);
    });

    testWidgets('телефон: высота 180', (tester) async {
      await _pump(
        tester,
        MonthBarsChart(months: _months(6), currentMonth: '2026-02'),
      );
      expect(tester.getSize(find.byKey(const Key('chart-months'))).height, 180);
    });
  });

  group('линия баланса', () {
    List<BalancePoint> points(List<int> totals) => [
      for (var i = 0; i < totals.length; i++)
        BalancePoint(
          date: i == totals.length - 1
              ? '2026-10-05'
              : '${addMonths('2025-12', i)}-28',
          total: totals[i],
        ),
    ];

    testWidgets('нет точек, одна точка, одинаковые значения', (tester) async {
      await _pump(tester, const BalanceLineChart(points: []));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSemantics(find.byKey(const Key('chart-balance'))).label,
        'Нет данных о балансе',
      );
      await _pump(tester, BalanceLineChart(points: points([500000])));
      expect(tester.takeException(), isNull);
      await _pump(tester, BalanceLineChart(points: points([0, 0, 0])));
      expect(tester.takeException(), isNull);
      await _pump(tester, BalanceLineChart(points: points([700000, 700000])));
      expect(tester.takeException(), isNull);
    });

    testWidgets('рост, падение, отрицательная зона с нулевой линией', (
      tester,
    ) async {
      await _pump(
        tester,
        BalanceLineChart(points: points([100000, 250000, 900000, 1500000])),
      );
      expect(tester.takeException(), isNull);
      await _pump(
        tester,
        BalanceLineChart(points: points([300000, -200000, -50000, 400000])),
      );
      expect(tester.takeException(), isNull);
      final semantics = tester.getSemantics(
        find.byKey(const Key('chart-balance')),
      );
      expect(semantics.label, contains('Общий баланс: сейчас'));
      expect(semantics.label, contains('в начале периода'));
    });

    testWidgets('много точек: подписи оси не слипаются', (tester) async {
      await _pump(
        tester,
        BalanceLineChart(
          points: points([for (var i = 0; i < 24; i++) 100000 * (i + 1)]),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('полоса доли и пустой график', () {
    testWidgets('ShareBar: доля обрезается в 0…1', (tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 200,
          child: Column(
            children: [
              ShareBar(fraction: 1.7, highlight: true),
              ShareBar(fraction: -1),
              ShareBar(fraction: 0.25),
            ],
          ),
        ),
      );
      final widths = tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .map((w) => w.widthFactor)
          .toList();
      expect(widths, [1, 0, 0.25]);
    });

    testWidgets('EmptyChart: пунктирная ось и подпись', (tester) async {
      await _pump(tester, const SizedBox(width: 300, child: EmptyChart()));
      expect(find.text('Нет операций за этот период'), findsOneWidget);
      await _pump(
        tester,
        const SizedBox(
          width: 300,
          child: EmptyChart(text: 'Пусто', height: 80),
        ),
      );
      expect(find.text('Пусто'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
