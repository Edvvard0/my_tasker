import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<List<Goal>> _goals(WidgetTester tester, ProviderContainer c) async =>
    (await tester.runAsync(
      () async => [
        for (final r in await c.read(syncStoreProvider).visibleRows('goals'))
          Goal.fromRow(r),
      ],
    ))!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = phoneSize,
    bool seed = true,
    Future<void> Function(ProviderContainer c)? more,
  }) => pumpFinance(
    tester,
    location: '/finance/goals',
    size: size,
    seedWith: (c) async {
      if (seed) demo = await seedFinanceDemo(c);
      if (more != null) await more(c);
    },
  );

  group('«Цели»', () {
    testWidgets('случай Excel: Есть 454 600, цель достигнута, +54 600', (
      tester,
    ) async {
      await pump(tester);
      expect(
        _textOf(tester, 'goal-have-${demo.goal}'),
        'Есть ${nb('454 600 ₽')} из ${nb('400 000 ₽')}',
      );
      expect(
        _textOf(tester, 'goal-missing-${demo.goal}'),
        'Цель достигнута +${nb('54 600 ₽')}',
      );
      expect(_textOf(tester, 'goal-percent-${demo.goal}'), '113,6 %');
      // Разбор формулы по слагаемым: все счета 361 000 + долги 13 100 + 80 500.
      expect(find.text('Все счета в общем балансе'), findsOneWidget);
      expect(find.text(nb('361 000 ₽')), findsWidgets);
      expect(find.text('Долги мне'), findsOneWidget);
      expect(find.text(nb('13 100 ₽')), findsOneWidget);
      expect(find.text('Ожидаемые из «Работы»'), findsOneWidget);
      expect(find.text(nb('80 500 ₽')), findsOneWidget);
      expect(find.textContaining('Срок 15 нояб.'), findsOneWidget);
    });

    testWidgets('без кредитки «Есть» 329 600, не хватает 70 400', (
      tester,
    ) async {
      late String goal;
      await pump(
        tester,
        more: (c) async {
          final repo = c.read(financeRepositoryProvider);
          goal = repo.newId();
          await repo.createGoal(
            Goal(
              id: goal,
              name: 'Без кредитки',
              targetAmount: 40000000,
              formula: [
                GoalTerm(
                  kind: GoalTermKind.accounts,
                  accountIds: [demo.cash, demo.bank, demo.savings],
                ),
                const GoalTerm(kind: GoalTermKind.debtsToMe),
                const GoalTerm(kind: GoalTermKind.receivables),
              ],
            ),
          );
        },
      );
      expect(
        _textOf(tester, 'goal-have-$goal'),
        'Есть ${nb('329 600 ₽')} из ${nb('400 000 ₽')}',
      );
      expect(
        _textOf(tester, 'goal-missing-$goal'),
        'Не хватает ${nb('70 400 ₽')}',
      );
      expect(_textOf(tester, 'goal-percent-$goal'), '82,4 %');
      expect(find.text('Счета: Наличные, Т-Банк, ВТБ'), findsOneWidget);
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(find.byKey(Key('goal-${demo.goal}')), findsOneWidget);
    });

    testWidgets('пусто: подсказка и добавление', (tester) async {
      await pump(tester, seed: false);
      expect(find.byKey(const Key('goals-empty')), findsOneWidget);
      await tapKey(tester, 'goals-empty-add');
      expect(find.byKey(const Key('goal-name')), findsOneWidget);
    });

    testWidgets('архив: цель уходит в архив и возвращается', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'goal-${demo.goal}');
      await tapKey(tester, 'goal-archived');
      await tapKey(tester, 'goal-save');
      expect((await _goals(tester, container)).single.archived, isTrue);
      expect(find.byKey(Key('goal-${demo.goal}')), findsNothing);
      expect(find.byKey(const Key('goals-empty')), findsOneWidget);
      await tapKey(tester, 'goals-filter-archive');
      expect(find.byKey(Key('goal-${demo.goal}')), findsOneWidget);
      await tapKey(tester, 'goals-filter-open');
      expect(find.byKey(Key('goal-${demo.goal}')), findsNothing);
    });
  });

  group('конструктор формулы «Есть»', () {
    testWidgets('новая цель: формула по умолчанию воспроизводит Excel, '
        'предпросмотр', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'goals-add');
      // Три слагаемых по умолчанию.
      expect(find.byKey(const Key('goal-term-0')), findsOneWidget);
      expect(find.byKey(const Key('goal-term-1')), findsOneWidget);
      expect(find.byKey(const Key('goal-term-2')), findsOneWidget);
      expect(find.byKey(const Key('goal-term-3')), findsNothing);
      await tester.enterText(find.byKey(const Key('goal-name')), 'Отпуск');
      await tester.enterText(find.byKey(const Key('goal-target')), '500 000');
      await tester.pumpAndSettle();
      expect(
        _textOf(tester, 'goal-preview-have'),
        'Сейчас: есть ${nb('454 600 ₽')}',
      );
      expect(
        _textOf(tester, 'goal-preview-missing'),
        'Не хватает ${nb('45 400 ₽')}',
      );
      await tapKey(tester, 'goal-deadline-tomorrow');
      await tapKey(tester, 'goal-save');
      final goal = (await _goals(
        tester,
        container,
      )).firstWhere((g) => g.name == 'Отпуск');
      expect(goal.targetAmount, 50000000);
      expect(goal.deadlineDate, '2026-10-01');
      expect(goal.formula.map((t) => t.kind), [
        GoalTermKind.allAccounts,
        GoalTermKind.debtsToMe,
        GoalTermKind.receivables,
      ]);
      expect(goal.formula.every((t) => t.plus), isTrue);
      expect(goal.formula.last.clientIds, isNull);
    });

    testWidgets('знак слагаемого переключается; «мои долги» — со знаком '
        'минус; слагаемое можно убрать', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'goal-${demo.goal}');
      // Долги мне: вычесть вместо прибавить.
      await tapKey(tester, 'goal-term-sign-1');
      expect(
        _textOf(tester, 'goal-preview-have'),
        'Сейчас: есть ${nb('428 400 ₽')}',
      );
      // Мои долги добавляются со знаком «−».
      await tapKey(tester, 'goal-add-term');
      await tester.tap(find.byKey(const Key('goal-add-term-my_debts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-term-3')), findsOneWidget);
      await tapKey(tester, 'goal-term-remove-2');
      await tapKey(tester, 'goal-save');
      final goal = (await _goals(tester, container)).single;
      expect(goal.formula.map((t) => t.kind), [
        GoalTermKind.allAccounts,
        GoalTermKind.debtsToMe,
        GoalTermKind.myDebts,
      ]);
      expect(goal.formula.map((t) => t.plus), [true, false, false]);
    });

    testWidgets('конкретные счета и выбранные заказчики; предупреждение о '
        'пересечении', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'goal-${demo.goal}');
      await tapKey(tester, 'goal-add-term');
      await tester.tap(find.byKey(const Key('goal-add-term-accounts')));
      await tester.pumpAndSettle();
      // «Все счета» вместе с «Конкретными счетами» — предупреждение.
      expect(find.byKey(const Key('goal-overlap')), findsOneWidget);
      await tapKey(tester, 'goal-term-3-account-${demo.cash}');
      await tapKey(tester, 'goal-term-3-account-${demo.savings}');
      // Заказчик: только Рома (25 000 из дебиторки 80 500).
      await tapKey(tester, 'goal-term-sign-0');
      await tapKey(tester, 'goal-term-2-client-${demo.work.roma}');
      expect(
        _textOf(tester, 'goal-preview-have'),
        // −361 000 + 13 100 + 25 000 + (54 000 + 8 000)
        'Сейчас: есть ${nb('-260 900 ₽')}',
      );
      await tapKey(tester, 'goal-save');
      final goal = (await _goals(tester, container)).single;
      expect(goal.formula[3].accountIds, [demo.cash, demo.savings]);
      expect(goal.formula[2].clientIds, [demo.work.roma]);
      expect(goal.formula[0].plus, isFalse);
      // Сняли единственного заказчика — снова «все».
      await tapKey(tester, 'goal-${demo.goal}');
      await tapKey(tester, 'goal-term-2-client-${demo.work.roma}');
      await tapKey(tester, 'goal-save');
      expect(
        (await _goals(tester, container)).single.formula[2].clientIds,
        isNull,
      );
      // Счёт снимается повторным касанием.
      await tapKey(tester, 'goal-${demo.goal}');
      await tapKey(tester, 'goal-term-3-account-${demo.cash}');
      await tapKey(tester, 'goal-save');
      expect((await _goals(tester, container)).single.formula[3].accountIds, [
        demo.savings,
      ]);
      final data = container.read(financeDataProvider).requireValue;
      expect(data.goals.single.formula, hasLength(4));
    });

    testWidgets('ошибки: нет названия, нет цели, пустая формула, слагаемое '
        '«счета» без счетов', (tester) async {
      await pump(tester);
      await tapKey(tester, 'goals-add');
      await tapKey(tester, 'goal-save');
      expect(find.text('Укажите целевую сумму'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('goal-target')), '100');
      await tapKey(tester, 'goal-save');
      expect(find.textContaining('не может быть пустым'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('goal-name')), 'Цель');
      await tapKey(tester, 'goal-add-term');
      await tester.tap(find.byKey(const Key('goal-add-term-accounts')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'goal-save');
      expect(find.textContaining('от 1 до 50 счетов'), findsOneWidget);
      for (var i = 3; i >= 0; i--) {
        await tapKey(tester, 'goal-term-remove-$i');
      }
      await tapKey(tester, 'goal-save');
      expect(find.textContaining('от 1 до 30 слагаемых'), findsOneWidget);
    });

    testWidgets('правка цели и удаление', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'goal-${demo.goal}');
      await tester.enterText(find.byKey(const Key('goal-target')), '500 000');
      await tapKey(tester, 'goal-save');
      expect((await _goals(tester, container)).single.targetAmount, 50000000);
      expect(
        _textOf(tester, 'goal-missing-${demo.goal}'),
        'Не хватает ${nb('45 400 ₽')}',
      );
      await tapKey(tester, 'goal-${demo.goal}');
      await tapKey(tester, 'goal-delete');
      await tapKey(tester, 'confirm-ok');
      expect(await _goals(tester, container), isEmpty);
      expect(find.byKey(const Key('goals-empty')), findsOneWidget);
    });

    testWidgets('цель, удалённая на другом устройстве', (tester) async {
      await pump(tester);
      await tapKey(tester, 'goal-${demo.goal}');
      expect(find.byKey(const Key('goal-name')), findsOneWidget);
    });
  });
}
