import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/goal_editor.dart';

import '../support/finance_ui_env.dart';
import '../support/pump_app.dart';

/// Golden-тесты Этапа 5, срез 5c: «Цели» (список, карточка, редактор) и
/// «Аналитика» на телефоне и десктопе. Эталоны — `files/*.png`; обновление
/// только этого файла: `flutter test --update-goldens
/// test/goldens/stage5_goals_goldens_test.dart` (снимать на Linux, см. README).
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

Future<void> _openGoals(WidgetTester tester, {Size size = phoneSize}) async {
  await pumpFinance(tester, size: size, seedWith: seedGoalsDemo);
  await goTo(tester, '/finance/goals');
  await settleDb(tester);
}

/// Демо Финансов с более богатой историей: июль и июнь, подкатегории.
Future<void> _seedAnalytics(ProviderContainer c) async {
  final demo = await seedFinanceDemo(c);
  final repo = financeRepo(c);
  final taxi = (await repo.categories()).firstWhere((x) => x.name == 'Такси');
  Future<void> spend(
    String at,
    int amount,
    String merchant,
    String? category,
  ) => addTx(
    c,
    account: demo.tbank,
    amount: amount,
    merchant: merchant,
    category: category,
    at: at,
  );
  await spend('2026-07-04T10:00:00', 1850000, 'Перекрёсток', demo.groceries);
  await spend('2026-07-18T18:00:00', 950000, 'Лента', demo.groceries);
  await spend('2026-08-12T09:00:00', 420000, 'Яндекс Go', taxi.id);
  await spend('2026-09-08T12:00:00', 310000, 'Яндекс Go', taxi.id);
  await spend('2026-08-03T12:00:00', 780000, 'Аптека', null);
  await addTx(
    c,
    account: demo.tbank,
    amount: 9500000,
    kind: TransactionKind.income,
    category: demo.salary,
    merchant: 'Creora',
    at: '2026-07-25T08:00:00',
  );
}

Future<void> _openAnalytics(
  WidgetTester tester, {
  Size size = phoneSize,
}) async {
  await pumpFinance(tester, size: size, seedWith: _seedAnalytics);
  await goTo(tester, '/finance/analytics');
  await settleDb(tester);
}

void main() {
  group('Цели', () {
    testWidgets('телефон', (tester) async {
      await _openGoals(tester);
      await _shot(tester, 'goals_phone');
    });

    testWidgets('десктоп', (tester) async {
      await _openGoals(tester, size: desktopSize);
      await _shot(tester, 'goals_desktop');
    });

    testWidgets('Карточка цели (телефон)', (tester) async {
      late GoalsDemo demo;
      await pumpFinance(
        tester,
        seedWith: (c) async => demo = await seedGoalsDemo(c),
      );
      await goTo(tester, '/finance/goals/${demo.vacation}');
      await settleDb(tester);
      await _shot(tester, 'goal_card_phone');
    });

    testWidgets('Редактор цели (телефон)', (tester) async {
      await pumpFinance(tester, seedWith: seedGoalsDemo);
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      await enter(tester, 'goal-name', 'Отпуск');
      await enter(tester, 'goal-target', '400 000');
      await _shot(tester, 'goal_editor_phone');
    });
  });

  group('Аналитика', () {
    testWidgets('телефон', (tester) async {
      await _openAnalytics(tester);
      await _shot(tester, 'analytics_phone');
    });

    testWidgets('десктоп', (tester) async {
      await _openAnalytics(tester, size: desktopSize);
      await _shot(tester, 'analytics_desktop');
    });
  });
}
