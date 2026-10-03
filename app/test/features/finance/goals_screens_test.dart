import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/presentation/goal_editor.dart';
import 'package:my_tasker/features/finance/presentation/goal_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

String _rub(int rubles, {bool signed = false}) {
  final s = rubles.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(_nb);
    out.write(s[i]);
  }
  final sign = rubles < 0 ? '−' : (signed && rubles > 0 ? '+' : '');
  return '$sign$out$_nb₽';
}

Future<(ProviderContainer, GoalsDemo)> _open(
  WidgetTester tester, {
  String location = '/finance/goals',
  Size size = phoneSize,
  List<Override> overrides = const [],
}) async {
  late GoalsDemo demo;
  final c = await pumpFinance(
    tester,
    size: size,
    overrides: overrides,
    seedWith: (c) async => demo = await seedGoalsDemo(c),
  );
  if (location != '/finance') await goTo(tester, location);
  await settleDb(tester);
  return (c, demo);
}

Future<T> _db<T>(WidgetTester tester, Future<T> Function() action) async {
  final result = await tester.runAsync(action);
  await settleDb(tester);
  return result as T;
}

List<Override> get _offline => [
  syncStatusProvider.overrideWith(
    () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
  ),
];

/// Ширина заполненной части полосы цели внутри [within].
double _fill(WidgetTester tester, Finder within) => tester
    .widget<FractionallySizedBox>(
      find.descendant(of: within, matching: find.byType(FractionallySizedBox)),
    )
    .widthFactor!;

void main() {
  group('Цели: список', () {
    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/goals',
        overrides: [goalRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('goals-list')), findsNothing);
    });

    testWidgets('пусто: «Целей пока нет» и «Добавить цель»', (tester) async {
      await pumpFinance(tester, location: '/finance/goals');
      expect(find.byKey(const Key('goals-empty')), findsOneWidget);
      expect(find.text('Целей пока нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goals-empty-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новая цель'), findsOneWidget);
      expect(find.byKey(const Key('goal-name')), findsOneWidget);
    });

    testWidgets('данные: «Есть», «Не хватает», процент усечением, срок', (
      tester,
    ) async {
      final (_, d) = await _open(tester);
      // «Отпуск»: 361 000 + 13 100 + 0 (Работы нет) = 374 100 из 400 000
      expect(textOf(tester, 'goal-have-${d.vacation}'), _rub(374100));
      expect(textOf(tester, 'goal-missing-${d.vacation}'), _rub(25900));
      expect(textOf(tester, 'goal-percent-${d.vacation}'), '93,5 %');
      expect(
        textOf(tester, 'goal-deadline-${d.vacation}'),
        contains('31 дек.'),
      );
      expect(
        textOf(tester, 'goal-deadline-${d.vacation}'),
        'Срок 31 дек. · осталось 92 дня',
      );
      // «Ноутбук»: 80 + 540 = 62 000 из 150 000
      expect(textOf(tester, 'goal-have-${d.laptop}'), _rub(62000));
      expect(textOf(tester, 'goal-missing-${d.laptop}'), _rub(88000));
      expect(textOf(tester, 'goal-percent-${d.laptop}'), '41,3 %');
      expect(
        textOf(tester, 'goal-deadline-${d.laptop}'),
        'Срок 15 нояб. · осталось 46 дней',
      );
      // «Подушка»: 361 000 − 15 000 = 346 000 из 300 000 — достигнута
      expect(textOf(tester, 'goal-have-${d.cushion}'), _rub(346000));
      expect(
        textOf(tester, 'goal-missing-${d.cushion}'),
        'Цель достигнута, ${_rub(46000, signed: true)}',
      );
      expect(textOf(tester, 'goal-percent-${d.cushion}'), '115,3 %');
      expect(find.byKey(Key('goal-deadline-${d.cushion}')), findsNothing);
    });

    testWidgets('полоса обрезается на 100 %', (tester) async {
      final (_, d) = await _open(tester);
      expect(
        _fill(tester, find.byKey(Key('goal-row-${d.cushion}'))),
        1,
        reason: '115,3 % рисуются полной полосой',
      );
      expect(
        _fill(tester, find.byKey(Key('goal-row-${d.vacation}'))),
        closeTo(0.9352, 0.0001),
      );
    });

    testWidgets('порядок: ближайший срок выше, без срока — внизу; архив '
        'свёрнут', (tester) async {
      final (_, d) = await _open(tester);
      double top(String id) =>
          tester.getTopLeft(find.byKey(Key('goal-row-$id'))).dy;
      expect(top(d.laptop), lessThan(top(d.vacation)));
      expect(top(d.vacation), lessThan(top(d.cushion)));
      expect(find.byKey(Key('goal-row-${d.courses}')), findsNothing);
      expect(find.text('АРХИВ · 1'), findsOneWidget);
      await tapKey(tester, 'goals-archive-toggle');
      expect(find.byKey(Key('goal-row-${d.courses}')), findsOneWidget);
    });

    testWidgets('честная пометка о «Работе» — только у цели с receivables', (
      tester,
    ) async {
      await _open(tester);
      // «Отпуск» — единственная цель с ожидаемыми поступлениями
      expect(find.text(goalReceivablesNote), findsOneWidget);
    });

    testWidgets('с подключённой Работой пометки нет', (tester) async {
      await _open(
        tester,
        overrides: [workDataProvider.overrideWithValue(excelWorkData())],
      );
      expect(find.text(goalReceivablesNote), findsNothing);
    });

    testWidgets('все цели в архиве: подсказка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/goals',
        seedWith: (c) =>
            addGoal(c, name: 'Старая', target: 100000, archived: true),
      );
      expect(find.byKey(const Key('goals-none-active')), findsOneWidget);
      expect(find.text('Все цели в архиве.'), findsOneWidget);
    });

    testWidgets('десктоп: карточки в две колонки', (tester) async {
      final (_, d) = await _open(tester, size: desktopSize);
      final a = tester.getTopLeft(find.byKey(Key('goal-row-${d.laptop}')));
      final b = tester.getTopLeft(find.byKey(Key('goal-row-${d.vacation}')));
      expect(b.dx, greaterThan(a.dx + 300));
      expect(b.dy, a.dy);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/goals',
        overrides: [
          debtRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка, данные работают', (tester) async {
      final (_, d) = await _open(tester, overrides: _offline);
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(Key('goal-row-${d.vacation}')), findsOneWidget);
    });

    testWidgets('вход из «Финансы», карточка и обратно', (tester) async {
      final (_, d) = await _open(tester, location: '/finance');
      await tapKey(tester, 'finance-open-goals');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goals-list')), findsOneWidget);
      await tester.tap(find.byKey(Key('goal-row-${d.laptop}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-have')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goals-list')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-open-goals')), findsOneWidget);
    });

    testWidgets('«+» в шапке открывает редактор новой цели', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('goals-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новая цель'), findsOneWidget);
    });
  });

  group('Цель: карточка', () {
    Future<(ProviderContainer, GoalsDemo)> card(
      WidgetTester tester,
      String Function(GoalsDemo) id, {
      Size size = phoneSize,
      List<Override> overrides = const [],
    }) async {
      final (c, d) = await _open(tester, size: size, overrides: overrides);
      await goTo(tester, '/finance/goals/${id(d)}');
      await settleDb(tester);
      return (c, d);
    }

    testWidgets('данные: «Есть», «Не хватает», процент, срок, разбор формулы', (
      tester,
    ) async {
      await card(tester, (d) => d.vacation);
      expect(textOf(tester, 'goal-have'), _rub(374100));
      expect(textOf(tester, 'goal-missing'), _rub(25900));
      expect(textOf(tester, 'goal-percent'), '93,5 % от ${_rub(400000)}');
      expect(textOf(tester, 'goal-target-line'), 'Цель ${_rub(400000)}');
      expect(textOf(tester, 'goal-deadline'), 'Срок 31 дек. · осталось 92 дня');
      // таблица разбора: слагаемые со знаками и итог
      expect(find.byKey(const Key('goal-terms')), findsOneWidget);
      expect(find.text('Все счета'), findsOneWidget);
      expect(textOf(tester, 'goal-term-value-0'), _rub(361000, signed: true));
      expect(find.text('Мне должны'), findsOneWidget);
      expect(textOf(tester, 'goal-term-value-1'), _rub(13100, signed: true));
      expect(find.text('Ожидаемые поступления (Работа)'), findsOneWidget);
      expect(textOf(tester, 'goal-term-value-2'), '0$_nb₽');
      expect(textOf(tester, 'goal-terms-total'), _rub(374100));
      expect(find.byKey(const Key('goal-archived-pill')), findsNothing);
    });

    testWidgets('честная пометка о «Работе»: формула со слагаемым '
        'receivables', (tester) async {
      await card(tester, (d) => d.vacation);
      expect(find.byKey(const Key('goal-receivables-note')), findsOneWidget);
      expect(find.text(goalReceivablesNote), findsOneWidget);
      expect(find.text('Раздел «Работа» не подключён'), findsOneWidget);
      expect(
        goalReceivablesNote,
        'Раздел «Работа» ещё не подключён — ожидаемые поступления сейчас '
        'считаются как 0',
      );
    });

    testWidgets('без слагаемого receivables пометки нет', (tester) async {
      await card(tester, (d) => d.laptop);
      expect(find.byKey(const Key('goal-receivables-note')), findsNothing);
      expect(find.text(goalReceivablesNote), findsNothing);
      // слагаемое с названиями счетов
      expect(find.text('Счета: Накопительный, Наличные'), findsOneWidget);
    });

    testWidgets('достигнутая цель: «+X», вычет «−», полоса не длиннее 100 %', (
      tester,
    ) async {
      await card(tester, (d) => d.cushion);
      expect(textOf(tester, 'goal-have'), _rub(346000));
      expect(
        textOf(tester, 'goal-missing'),
        'Цель достигнута, ${_rub(46000, signed: true)}',
      );
      expect(textOf(tester, 'goal-percent'), '115,3 % от ${_rub(300000)}');
      expect(textOf(tester, 'goal-term-value-1'), _rub(-15000));
      expect(find.text('Я должен'), findsOneWidget);
      expect(find.byKey(const Key('goal-deadline')), findsNothing);
      expect(_fill(tester, find.byKey(const Key('goal-scroll'))), 1);
    });

    testWidgets('Excel заказчика через интерфейс (данные Работы подставлены): '
        '454 600, «+54 600», 113,6 %; пометки о Работе нет', (tester) async {
      late String goal;
      await pumpFinance(
        tester,
        overrides: [workDataProvider.overrideWithValue(excelWorkData())],
        seedWith: (c) async {
          await seedExcelAccounts(c);
          // в Excel «Мне должны» — 7 500 + 2 600 + 3 000, мой долг не в формуле
          goal = await addGoal(c, name: 'Excel', target: 40000000);
        },
      );
      await goTo(tester, '/finance/goals/$goal');
      await settleDb(tester);
      expect(textOf(tester, 'goal-have'), _rub(454600));
      expect(
        textOf(tester, 'goal-missing'),
        'Цель достигнута, ${_rub(54600, signed: true)}',
      );
      expect(textOf(tester, 'goal-percent'), '113,6 % от ${_rub(400000)}');
      expect(textOf(tester, 'goal-term-value-0'), _rub(361000, signed: true));
      expect(textOf(tester, 'goal-term-value-1'), _rub(13100, signed: true));
      expect(textOf(tester, 'goal-term-value-2'), _rub(80500, signed: true));
      expect(find.text(goalReceivablesNote), findsNothing);
      expect(find.text('Раздел «Работа» не подключён'), findsNothing);
    });

    testWidgets(
      'Excel без кредитки (три счёта): 329 600 и «Не хватает 70 400»',
      (tester) async {
        late String goal;
        await pumpFinance(
          tester,
          overrides: [workDataProvider.overrideWithValue(excelWorkData())],
          seedWith: (c) async {
            final d = await seedExcelAccounts(c);
            goal = await addGoal(
              c,
              name: 'Excel',
              target: 40000000,
              formula: [
                GoalTerm(
                  kind: GoalTermKind.accounts,
                  accountIds: [d.cash, d.tbank, d.savings],
                ),
                const GoalTerm(kind: GoalTermKind.debtsToMe),
                const GoalTerm(kind: GoalTermKind.receivables),
              ],
            );
          },
        );
        await goTo(tester, '/finance/goals/$goal');
        await settleDb(tester);
        expect(textOf(tester, 'goal-have'), _rub(329600));
        expect(textOf(tester, 'goal-missing'), _rub(70400));
        expect(textOf(tester, 'goal-percent'), '82,4 % от ${_rub(400000)}');
      },
    );

    testWidgets('цель в архиве: пилюля; нет такой цели: «Цель не найдена»', (
      tester,
    ) async {
      await card(tester, (d) => d.courses);
      expect(find.byKey(const Key('goal-archived-pill')), findsOneWidget);
      await goTo(tester, '/finance/goals/нет-такой');
      await settleDb(tester);
      expect(find.byKey(const Key('goal-not-found')), findsOneWidget);
      await tester.tap(find.text('К целям'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goals-list')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/goals/x',
        overrides: [goalRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка чтения: плашка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/goals/x',
        overrides: [
          goalRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка, данные работают', (tester) async {
      await card(tester, (d) => d.vacation, overrides: _offline);
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('goal-have')), findsOneWidget);
    });

    testWidgets('десктоп: карточка по центру', (tester) async {
      await card(tester, (d) => d.vacation, size: desktopSize);
      expect(textOf(tester, 'goal-have'), _rub(374100));
    });

    testWidgets('«Есть» живёт вместе с данными: новая операция меняет '
        'карточку', (tester) async {
      final (c, d) = await card(tester, (d) => d.laptop);
      expect(textOf(tester, 'goal-have'), _rub(62000));
      await _db(
        tester,
        () => addTx(
          c,
          account: d.savings,
          amount: 1000000,
          kind: TransactionKind.income,
        ),
      );
      expect(textOf(tester, 'goal-have'), _rub(72000));
      expect(textOf(tester, 'goal-missing'), _rub(78000));
    });

    testWidgets('архив из меню и возврат; цель уходит из основного списка', (
      tester,
    ) async {
      final (c, d) = await card(tester, (d) => d.laptop);
      await tester.tap(find.byKey(const Key('goal-menu')));
      await tester.pumpAndSettle();
      expect(find.text('В архив'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goal-menu-archive')));
      await settleDb(tester);
      expect(find.byKey(const Key('goal-archived-pill')), findsOneWidget);
      expect(
        (await _db(tester, () => financeRepo(c).getGoal(d.laptop)))!.archived,
        isTrue,
      );
      // «Отменить» в снэкбаре возвращает
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(const Key('goal-archived-pill')), findsNothing);
      await tester.tap(find.byKey(const Key('goal-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goal-menu-archive')));
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('goal-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Вернуть из архива'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goal-menu-archive')));
      await settleDb(tester);
      expect(find.byKey(const Key('goal-archived-pill')), findsNothing);
    });

    testWidgets('удаление: подтверждение, возврат к списку, «Отменить»', (
      tester,
    ) async {
      final (c, d) = await card(tester, (d) => d.laptop);
      await tester.tap(find.byKey(const Key('goal-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goal-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await _db(tester, () => financeRepo(c).goals()), hasLength(4));
      await tester.tap(find.byKey(const Key('goal-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goal-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await settleDb(tester);
      expect(find.byKey(const Key('goals-list')), findsOneWidget);
      expect(find.byKey(Key('goal-row-${d.laptop}')), findsNothing);
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(Key('goal-row-${d.laptop}')), findsOneWidget);
    });
  });

  group('Корзина', () {
    testWidgets('удалённая цель видна в корзине и восстанавливается', (
      tester,
    ) async {
      final (c, d) = await _open(tester);
      final repo = financeRepo(c);
      await _db(tester, () => repo.deleteGoal(d.cushion));
      await goTo(tester, '/settings/trash');
      await settleDb(tester);
      expect(find.byKey(const Key('trash-list')), findsOneWidget);
      expect(find.text('Подушка безопасности'), findsOneWidget);
      expect(find.textContaining('Цель · удалено'), findsOneWidget);
      await tester.tap(find.byKey(Key('restore-${d.cushion}')));
      await settleDb(tester);
      expect(find.text('Корзина пуста'), findsOneWidget);
      final goals = await _db(tester, repo.goals);
      expect(goals.map((g) => g.id), contains(d.cushion));
      // формула цели после восстановления цела
      expect(goals.firstWhere((g) => g.id == d.cushion).formula, [
        const GoalTerm(kind: GoalTermKind.allAccounts),
        GoalTerm.initial(GoalTermKind.myDebts),
      ]);
    });
  });

  group('Цель: редактор', () {
    Future<ProviderContainer> openNew(
      WidgetTester tester, {
      Size size = phoneSize,
    }) async {
      late GoalsDemo d;
      final c = await pumpFinance(
        tester,
        size: size,
        seedWith: (c) async => d = await seedExcelAccounts(c),
      );
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      expect(d.cash, isNotEmpty);
      return c;
    }

    SegmentedPill<GoalSign> signPill(WidgetTester tester, int index) =>
        tester.widget<SegmentedPill<GoalSign>>(
          find.byType(SegmentedPill<GoalSign>).at(index),
        );

    Future<void> addKind(WidgetTester tester, GoalTermKind kind) async {
      await tapKey(tester, 'formula-add');
      await tester.tap(find.byKey(Key('add-kind-${kind.wire}')));
      await tester.pumpAndSettle();
    }

    testWidgets('новая цель: формула по умолчанию из spec 6.2 и честная '
        'пометка о receivables', (tester) async {
      await openNew(tester);
      expect(find.text('Новая цель'), findsOneWidget);
      expect(find.byKey(const Key('formula-builder')), findsOneWidget);
      expect(textOf(tester, 'term-kind-0'), 'Все счета');
      expect(textOf(tester, 'term-kind-1'), 'Мне должны');
      expect(textOf(tester, 'term-kind-2'), 'Ожидаемые поступления');
      expect(find.byKey(const Key('term-3')), findsNothing);
      for (var i = 0; i < 3; i++) {
        expect(signPill(tester, i).selected, GoalSign.plus);
      }
      // слагаемое receivables — пометка, что Работа не подключена
      expect(find.byKey(const Key('goal-receivables-note')), findsOneWidget);
      expect(find.text(goalReceivablesNote), findsOneWidget);
      expect(find.text('Все заказчики'), findsOneWidget);
    });

    testWidgets('сохранение: формула по умолчанию уходит как есть, '
        'receivables сохраняется', (tester) async {
      final c = await openNew(tester);
      await enter(tester, 'goal-name', '  Отпуск ');
      await enter(tester, 'goal-target', '400 000');
      await tapKey(tester, 'goal-deadline-tomorrow');
      await tapKey(tester, 'goal-save');
      await settleDb(tester);
      final goals = await _db(tester, () => financeRepo(c).goals());
      final g = goals.single;
      expect(g.name, 'Отпуск');
      expect(g.targetAmount, 40000000);
      expect(g.deadlineDate, '2026-10-01');
      expect(g.archived, isFalse);
      expect(formulaToJson(g.formula), [
        {'kind': 'all_accounts', 'sign': '+'},
        {'kind': 'debts_to_me', 'sign': '+'},
        {'kind': 'receivables', 'sign': '+', 'client_ids': null},
      ]);
      expect(find.text('Новая цель'), findsNothing);
    });

    testWidgets('ошибки: сумма, название, пустая формула, слагаемое без '
        'счетов', (tester) async {
      final c = await openNew(tester);
      await tapKey(tester, 'goal-save');
      expect(find.text('Введи сумму цели больше нуля'), findsOneWidget);
      await enter(tester, 'goal-target', '1000');
      await tapKey(tester, 'goal-save');
      expect(find.byKey(const Key('goal-error')), findsOneWidget);
      expect(find.text('Название цели не может быть пустым'), findsOneWidget);
      await enter(tester, 'goal-name', 'Ц');
      // слагаемое «выбранные счета» без счетов
      await addKind(tester, GoalTermKind.accounts);
      expect(find.byKey(const Key('term-3-empty')), findsOneWidget);
      await tapKey(tester, 'goal-save');
      expect(
        find.text('Список счетов — от 1 до 50 идентификаторов'),
        findsOneWidget,
      );
      // убрали все слагаемые
      for (var i = 0; i < 4; i++) {
        await tapKey(tester, 'term-remove-0');
      }
      expect(find.byKey(const Key('formula-empty')), findsOneWidget);
      await tapKey(tester, 'goal-save');
      expect(find.text('В формуле — от 1 до 30 слагаемых'), findsOneWidget);
      expect(await _db(tester, () => financeRepo(c).goals()), isEmpty);
    });

    testWidgets('«мои долги»: знак по умолчанию «−»; знак меняется и '
        'сохраняется', (tester) async {
      final c = await openNew(tester);
      await addKind(tester, GoalTermKind.myDebts);
      expect(textOf(tester, 'term-kind-3'), 'Я должен');
      expect(signPill(tester, 3).selected, GoalSign.minus);
      // у остальных видов по умолчанию «+»
      await addKind(tester, GoalTermKind.debtsToMe);
      expect(signPill(tester, 4).selected, GoalSign.plus);
      // переключили знак у «Все счета» на «−», у «Я должен» — на «+»
      await tapKey(tester, 'term-sign-0-minus');
      await tapKey(tester, 'term-sign-3-plus');
      expect(signPill(tester, 0).selected, GoalSign.minus);
      expect(signPill(tester, 3).selected, GoalSign.plus);
      await enter(tester, 'goal-name', 'Ц');
      await enter(tester, 'goal-target', '100');
      await tapKey(tester, 'goal-save');
      await settleDb(tester);
      final g = (await _db(tester, () => financeRepo(c).goals())).single;
      expect(g.formula.map((t) => t.sign.wire), ['-', '+', '+', '+', '+']);
      expect(g.formula[3].kind, GoalTermKind.myDebts);
    });

    testWidgets('счета: выбор в порядке нажатия, подписи, удаление счёта из '
        'слагаемого', (tester) async {
      late GoalsDemo d;
      final c = await pumpFinance(
        tester,
        seedWith: (c) async => d = await seedExcelAccounts(c),
      );
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      await addKind(tester, GoalTermKind.accounts);
      await tapKey(tester, 'term-accounts-3');
      expect(find.byKey(const Key('accounts-multi-picker')), findsOneWidget);
      await tester.tap(find.byKey(Key('multi-account-${d.savings}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('multi-account-${d.cash}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('multi-account-${d.credit}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('multi-account-${d.credit}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('multi-accounts-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('term-3-account-${d.savings}')), findsOneWidget);
      expect(find.byKey(Key('term-3-account-${d.cash}')), findsOneWidget);
      expect(find.byKey(Key('term-3-account-${d.credit}')), findsNothing);
      // крестик на чипе убирает счёт
      final close = find.descendant(
        of: find.byKey(Key('term-3-account-${d.cash}')),
        matching: find.byIcon(LucideIcons.x),
      );
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('term-3-account-${d.cash}')), findsNothing);
      await enter(tester, 'goal-name', 'Ц');
      await enter(tester, 'goal-target', '100');
      await tapKey(tester, 'goal-save');
      await settleDb(tester);
      final g = (await _db(tester, () => financeRepo(c).goals())).single;
      expect(g.formula[3].kind, GoalTermKind.accounts);
      expect(g.formula[3].accountIds, [d.savings]);
    });

    testWidgets('предупреждение: счёт есть и в «Все счета», и в «Выбранные '
        'счета»', (tester) async {
      late GoalsDemo d;
      await pumpFinance(
        tester,
        seedWith: (c) async {
          d = await seedExcelAccounts(c);
          await addAccount(
            c,
            'Вне общего',
            includeInTotal: false,
            opening: 100000,
          );
        },
      );
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('formula-overlap')), findsNothing);
      await addKind(tester, GoalTermKind.accounts);
      // пока счета не выбраны — пересечения нет
      expect(find.byKey(const Key('formula-overlap')), findsNothing);
      await tapKey(tester, 'term-accounts-3');
      await tester.tap(find.byKey(Key('multi-account-${d.tbank}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('multi-accounts-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('formula-overlap')), findsOneWidget);
      expect(
        find.textContaining('Т-Банк Black'),
        findsWidgets,
        reason: 'в предупреждении названы счета',
      );
      expect(find.textContaining('учтутся дважды'), findsOneWidget);
      // уберём «Все счета» — предупреждение исчезает
      await tapKey(tester, 'term-remove-0');
      expect(find.byKey(const Key('formula-overlap')), findsNothing);
    });

    testWidgets('счёт вне общего баланса не пересекается с «Все счета»', (
      tester,
    ) async {
      late String outside;
      await pumpFinance(
        tester,
        seedWith: (c) async {
          outside = await addAccount(
            c,
            'Вне общего',
            includeInTotal: false,
            opening: 100000,
          );
        },
      );
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      await addKind(tester, GoalTermKind.accounts);
      await tapKey(tester, 'term-accounts-3');
      await tester.tap(find.byKey(Key('multi-account-$outside')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('multi-accounts-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('formula-overlap')), findsNothing);
    });

    testWidgets('лимит: не больше 30 слагаемых', (tester) async {
      late String goal;
      await pumpFinance(
        tester,
        seedWith: (c) async {
          goal = await addGoal(
            c,
            name: 'Много',
            target: 100000,
            formula: [
              for (var i = 0; i < 29; i++)
                const GoalTerm(kind: GoalTermKind.debtsToMe),
            ],
          );
        },
      );
      unawaited(
        showGoalEditor(
          tester.element(find.byType(Scaffold).first),
          goalId: goal,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('formula-limit')), findsNothing);
      await addKind(tester, GoalTermKind.myDebts);
      expect(find.byKey(const Key('term-29')), findsOneWidget);
      expect(find.byKey(const Key('formula-limit')), findsOneWidget);
      expect(find.text('Не больше 30 слагаемых в формуле.'), findsOneWidget);
      final add = tester.widget<ElevatedButton>(
        find.byKey(const Key('formula-add')),
      );
      expect(add.onPressed, isNull);
      // убрали одно — добавлять снова можно
      await tapKey(tester, 'term-remove-5');
      expect(find.byKey(const Key('formula-limit')), findsNothing);
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('formula-add')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('лимит: не больше 50 счетов в слагаемом', (tester) async {
      final ids = <String>[];
      await pumpFinance(
        tester,
        seedWith: (c) async {
          for (var i = 0; i < 51; i++) {
            ids.add(await addAccount(c, 'Счёт ${i + 1}'));
          }
        },
      );
      unawaited(showGoalEditor(tester.element(find.byType(Scaffold).first)));
      await tester.pumpAndSettle();
      await addKind(tester, GoalTermKind.accounts);
      await tapKey(tester, 'term-accounts-3');
      for (final id in ids) {
        final row = find.byKey(Key('multi-account-$id'));
        await tester.ensureVisible(row);
        await tester.pump();
        await tester.tap(row);
        await tester.pump();
      }
      expect(find.byKey(const Key('multi-accounts-limit')), findsOneWidget);
      await tester.tap(find.byKey(const Key('multi-accounts-done')));
      await tester.pumpAndSettle();
      // выбрано ровно 50 — 51-й не добавился
      expect(find.byKey(Key('term-3-account-${ids[49]}')), findsOneWidget);
      expect(find.byKey(Key('term-3-account-${ids[50]}')), findsNothing);
    });

    testWidgets('правка: поля заполнены, формула и client_ids сохраняются '
        'как есть', (tester) async {
      late String goal;
      late GoalsDemo d;
      final c = await pumpFinance(
        tester,
        seedWith: (c) async {
          d = await seedExcelAccounts(c);
          goal = await addGoal(
            c,
            name: 'Машина',
            target: 90000000,
            deadline: '2027-05-20',
            formula: [
              GoalTerm(kind: GoalTermKind.accounts, accountIds: [d.savings]),
              const GoalTerm(
                kind: GoalTermKind.receivables,
                sign: GoalSign.minus,
                clientIds: ['01900000-0000-7000-8000-000000000700'],
              ),
            ],
          );
        },
      );
      await goTo(tester, '/finance/goals/$goal');
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('goal-edit')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'goal-name'), 'Машина');
      expect(fieldText(tester, 'goal-target'), '900${_nb}000');
      expect(find.text('Заказчики Работы: 1'), findsOneWidget);
      expect(signPill(tester, 1).selected, GoalSign.minus);
      await enter(tester, 'goal-name', 'Машина мечты');
      await tapKey(tester, 'goal-deadline-none');
      await tapKey(tester, 'goal-save');
      await settleDb(tester);
      final g = (await _db(tester, () => financeRepo(c).getGoal(goal)))!;
      expect(g.name, 'Машина мечты');
      expect(g.deadlineDate, isNull);
      expect(g.targetAmount, 90000000);
      expect(formulaToJson(g.formula), [
        {
          'kind': 'accounts',
          'sign': '+',
          'account_ids': [d.savings],
        },
        {
          'kind': 'receivables',
          'sign': '-',
          'client_ids': ['01900000-0000-7000-8000-000000000700'],
        },
      ]);
      // карточка показывает новое название
      expect(find.text('Машина мечты'), findsWidgets);
    });

    testWidgets('цель пропала: «Цель не найдена»', (tester) async {
      await pumpFinance(tester);
      unawaited(
        showGoalEditor(
          tester.element(find.byType(Scaffold).first),
          goalId: 'нет',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-editor-missing')), findsOneWidget);
    });

    testWidgets('десктоп: редактор открывается панелью', (tester) async {
      await openNew(tester, size: desktopSize);
      expect(find.byKey(const Key('formula-builder')), findsOneWidget);
      expect(find.byKey(const Key('goal-save')), findsOneWidget);
    });
  });
}
