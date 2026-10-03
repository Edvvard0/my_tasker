import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_nav.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';

const _labels = ['Операции', 'Долги', 'Цели', 'Аналитика', 'Категории'];

/// Ключ экрана, который открывает пункт навигации.
const _targets = {
  'transactions': 'feed-search',
  'debts': 'debts-list',
  'goals': 'goals-list',
  'analytics': 'analytics-scroll',
  'categories': 'cats-list',
};

Future<ProviderContainer> _demo(WidgetTester tester, {Size size = phoneSize}) =>
    pumpFinance(
      tester,
      size: size,
      seedWith: (c) async {
        await seedFinanceDemo(c);
        await seedDebtsDemo(c);
        await addGoal(c, name: 'Отпуск', target: 40000000);
      },
    );

void main() {
  group('блок навигации «Финансов» (телефон)', () {
    testWidgets('одна лента с подписями: Операции · Долги · Цели · Аналитика · '
        'Категории', (tester) async {
      await _demo(tester);
      final nav = find.byKey(const Key('finance-nav'));
      expect(nav, findsOneWidget);
      for (final label in _labels) {
        expect(
          find.descendant(of: nav, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        tester.widget<SingleChildScrollView>(nav).scrollDirection,
        Axis.horizontal,
      );
      expect(financeNavItems.map((i) => i.label), _labels);
    });

    testWidgets('иконки-без-подписей из шапки и карточки убраны', (
      tester,
    ) async {
      await _demo(tester);
      // Каждый ключ входа — ровно один (плитка ленты), не иконка в шапке.
      for (final name in _targets.keys.where((k) => k != 'transactions')) {
        expect(find.byKey(Key('finance-open-$name')), findsOneWidget);
      }
      // В шапке — поиск, «глаз», приватность; подсказок «Долги»/«Цели» там нет.
      for (final tooltip in ['Долги', 'Цели', 'Аналитика', 'Категории']) {
        expect(find.byTooltip(tooltip), findsNothing, reason: tooltip);
      }
      expect(find.byKey(const Key('finance-open-feed')), findsOneWidget);
      expect(find.byKey(const Key('finance-toggle-hide')), findsOneWidget);
      expect(find.byKey(const Key('finance-open-privacy')), findsOneWidget);
    });

    testWidgets('плитки не помещаются на узком экране — лента прокручивается', (
      tester,
    ) async {
      await _demo(tester);
      final last = find.byKey(const Key('finance-open-categories'));
      expect(tester.getTopLeft(last).dx, greaterThan(phoneSize.width - 100));
      await tester.drag(
        find.byKey(const Key('finance-nav')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(last).dx, lessThan(phoneSize.width - 100));
    });

    for (final entry in _targets.entries) {
      testWidgets('«${entry.key}» открывает свой экран и возвращает назад', (
        tester,
      ) async {
        await _demo(tester);
        await tapKey(tester, 'finance-open-${entry.key}');
        expect(find.byKey(Key(entry.value)), findsOneWidget);
        await tester.tap(find.byTooltip('Назад'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('finance-nav')), findsOneWidget);
      });
    }

    testWidgets('«Операции» открывают ленту без прежнего фильтра', (
      tester,
    ) async {
      final c = await _demo(tester);
      c
          .read(transactionFilterProvider.notifier)
          .setKind(TransactionKind.income);
      await tapKey(tester, 'finance-open-transactions');
      expect(c.read(transactionFilterProvider).kind, isNull);
    });

    testWidgets('счетов нет: лента навигации всё равно доступна', (
      tester,
    ) async {
      await pumpFinance(tester);
      expect(find.byKey(const Key('finance-empty')), findsOneWidget);
      expect(find.byKey(const Key('finance-nav')), findsOneWidget);
      await tapKey(tester, 'finance-open-categories');
      expect(find.byKey(const Key('cats-empty')), findsOneWidget);
    });
  });

  group('блок навигации «Финансов» (десктоп)', () {
    testWidgets('вертикальный список в левой панели под счетами', (
      tester,
    ) async {
      await _demo(tester, size: desktopSize);
      final panel = find.byKey(const Key('finance-accounts-panel'));
      final nav = find.descendant(
        of: panel,
        matching: find.byKey(const Key('finance-nav')),
      );
      expect(nav, findsOneWidget);
      // Вертикальный список, не лента.
      expect(tester.widget(nav), isA<Column>());
      for (final label in _labels) {
        expect(
          find.descendant(of: nav, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      // Под списком счетов.
      final accountsBottom = tester
          .getBottomLeft(find.byKey(const Key('accounts-list')))
          .dy;
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(accountsBottom));
    });

    for (final entry in _targets.entries) {
      testWidgets('«${entry.key}» открывает свой экран', (tester) async {
        await _demo(tester, size: desktopSize);
        await tester.tap(find.byKey(Key('finance-open-${entry.key}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(entry.value)), findsOneWidget);
      });
    }

    testWidgets('счетов нет: сверху горизонтальная лента', (tester) async {
      await pumpFinance(tester, size: desktopSize);
      expect(find.byKey(const Key('finance-empty')), findsOneWidget);
      expect(find.byKey(const Key('finance-nav')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-open-debts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debts-empty')), findsOneWidget);
    });
  });
}
