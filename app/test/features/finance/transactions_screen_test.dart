import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

Future<(ProviderContainer, FinanceDemo)> _open(
  WidgetTester tester, {
  Size size = phoneSize,
  List<Override> overrides = const [],
}) async {
  late FinanceDemo demo;
  final c = await pumpFinance(
    tester,
    size: size,
    location: '/finance/transactions',
    overrides: overrides,
    seedWith: (c) async => demo = await seedFinanceDemo(c),
  );
  return (c, demo);
}

Future<void> _scrollTo(WidgetTester tester, Finder target) =>
    tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('feed-list')),
        matching: find.byType(Scrollable),
      ),
    );

void main() {
  group('лента операций', () {
    testWidgets('данные: липкие итоги месяцев — доход, расход, итого', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('СЕНТЯБРЬ 2026'), findsOneWidget);
      expect(
        textOf(tester, 'month-sums-2026-09'),
        'Доход +20${_nb}000$_nb₽ · Расход −2${_nb}979,90$_nb₽',
      );
      expect(textOf(tester, 'month-net-2026-09'), 'Итого +17${_nb}020,10$_nb₽');
      // Перевод в итоги не входит.
      await _scrollTo(tester, find.byKey(const Key('month-header-2026-08')));
      expect(
        textOf(tester, 'month-sums-2026-08'),
        'Доход +185${_nb}000$_nb₽ · Расход −6${_nb}400$_nb₽',
      );
      expect(textOf(tester, 'month-net-2026-08'), 'Итого +178${_nb}600$_nb₽');
    });

    testWidgets('заголовок месяца остаётся на месте при прокрутке', (
      tester,
    ) async {
      await _open(tester);
      final before = tester.getTopLeft(
        find.byKey(const Key('month-header-2026-09')),
      );
      final rowBefore = tester.getTopLeft(find.text('Пятёрочка'));
      await tester.drag(
        find.byKey(const Key('feed-list')),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      final after = tester.getTopLeft(
        find.byKey(const Key('month-header-2026-09')),
      );
      // Строки ушли вверх, заголовок закреплён на месте.
      expect(after.dy, before.dy);
      expect(
        tester.getTopLeft(find.text('Пятёрочка')).dy,
        lessThan(rowBefore.dy),
      );
    });

    testWidgets('строки: доход «+», расход «−», перевод со стрелкой', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('+20${_nb}000$_nb₽'), findsOneWidget);
      expect(find.text('−1${_nb}310$_nb₽'), findsOneWidget);
      expect(find.text('5${_nb}000$_nb₽'), findsOneWidget);
      expect(find.text('Наличные → Накопительный · 22 сент., 15:00'), findsOne);
      expect(find.text('Перевод'), findsOneWidget);
      expect(
        find.text('Продукты · Т-Банк Black · Сегодня, 09:02'),
        findsOneWidget,
      );
    });

    testWidgets('фильтр по виду', (tester) async {
      await _open(tester);
      await tapKey(tester, 'feed-kind-income');
      expect(find.text('Рома · Бот'), findsOneWidget);
      expect(find.text('Пятёрочка'), findsNothing);
      await tapKey(tester, 'feed-kind-transfer');
      expect(find.text('Перевод'), findsOneWidget);
      expect(find.text('Рома · Бот'), findsNothing);
      await tapKey(tester, 'feed-kind-expense');
      expect(find.text('Пятёрочка'), findsOneWidget);
      await tapKey(tester, 'feed-kind-all');
      expect(find.text('Рома · Бот'), findsOneWidget);
    });

    testWidgets('поиск по мерчанту и по сумме', (tester) async {
      await _open(tester);
      await enter(tester, 'feed-search', 'яндекс');
      await tester.pumpAndSettle();
      expect(find.text('Яндекс Go'), findsOneWidget);
      expect(find.text('Пятёрочка'), findsNothing);
      await enter(tester, 'feed-search', '1249,90');
      await tester.pumpAndSettle();
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Яндекс Go'), findsNothing);
      await enter(tester, 'feed-search', '20 000');
      await tester.pumpAndSettle();
      expect(find.text('Рома · Бот'), findsOneWidget);
    });

    testWidgets('ничего не нашлось: сброс фильтров возвращает ленту', (
      tester,
    ) async {
      await _open(tester);
      await enter(tester, 'feed-search', 'такого нет');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-filter-empty')), findsOneWidget);
      expect(find.text('Ничего не нашлось'), findsOneWidget);
      await tester.tap(find.byKey(const Key('feed-empty-reset')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-list')), findsOneWidget);
      expect(fieldText(tester, 'feed-search'), isEmpty);
      expect(find.byKey(const Key('feed-reset')), findsNothing);
    });

    testWidgets('фильтр по счёту', (tester) async {
      final (_, demo) = await _open(tester);
      await tapKey(tester, 'feed-account');
      await tapKey(tester, 'pick-account-${demo.cash}');
      // Перевод виден и со стороны счёта «откуда».
      expect(find.text('Перевод'), findsOneWidget);
      expect(find.text('Пятёрочка'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('feed-account')),
          matching: find.text('Наличные'),
        ),
        findsOneWidget,
      );
      // «Все счета» снимает фильтр.
      await tapKey(tester, 'feed-account');
      await tapKey(tester, 'pick-account-all');
      expect(find.text('Пятёрочка'), findsOneWidget);
    });

    testWidgets('счёт-получатель перевода тоже находит операцию', (
      tester,
    ) async {
      final (_, demo) = await _open(tester);
      await tapKey(tester, 'feed-account');
      await tapKey(tester, 'pick-account-${demo.savings}');
      expect(find.text('Перевод'), findsOneWidget);
    });

    testWidgets('фильтр по категории (с подкатегориями) и «без категории»', (
      tester,
    ) async {
      final (_, demo) = await _open(tester);
      await tapKey(tester, 'feed-category');
      // Оба вида под заголовками.
      expect(find.text('РАСХОДЫ'), findsOneWidget);
      expect(find.text('ДОХОДЫ'), findsOneWidget);
      await tapKey(tester, 'pick-category-${demo.groceries}');
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Яндекс Go'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('feed-category')),
          matching: find.text('Продукты'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'feed-category');
      await tapKey(tester, 'pick-category-without');
      expect(find.text('Перевод'), findsOneWidget);
      expect(find.text('Пятёрочка'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('feed-category')),
          matching: find.text('Без категории'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'feed-category');
      await tapKey(tester, 'pick-category-none');
      expect(find.text('Пятёрочка'), findsOneWidget);
    });

    testWidgets('период: этот месяц, прошлый месяц, всё время', (tester) async {
      await _open(tester);
      await tapKey(tester, 'feed-period-month');
      expect(find.text('СЕНТЯБРЬ 2026'), findsOneWidget);
      expect(find.text('АВГУСТ 2026'), findsNothing);
      expect(find.byKey(const Key('feed-reset')), findsOneWidget);
      await tapKey(tester, 'feed-period-prev');
      expect(find.text('СЕНТЯБРЬ 2026'), findsNothing);
      expect(find.text('АВГУСТ 2026'), findsOneWidget);
      await tapKey(tester, 'feed-period-all');
      expect(find.text('СЕНТЯБРЬ 2026'), findsOneWidget);
    });

    testWidgets('период: выбор диапазона дат', (tester) async {
      final (c, _) = await _open(tester);
      await tapKey(tester, 'feed-period-pick');
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      // Отмена не меняет фильтр.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(c.read(transactionFilterProvider).from, isNull);
      // Диапазон дат: подпись «25 сент. – 30 сент.».
      c
          .read(transactionFilterProvider.notifier)
          .setPeriod(from: '2026-09-25', to: '2026-09-30');
      await tester.pumpAndSettle();
      expect(find.text('25 сент. – 30 сент.'), findsOneWidget);
      expect(find.text('Рома · Бот'), findsNothing);
      expect(find.text('Пятёрочка'), findsOneWidget);
      // Открытая граница.
      c.read(transactionFilterProvider.notifier).setPeriod(from: '2026-09-29');
      await tester.pumpAndSettle();
      expect(find.text('29 сент. – …'), findsOneWidget);
    });

    testWidgets('период: выбор диапазона датпикером', (tester) async {
      final (c, _) = await _open(tester);
      await tapKey(tester, 'feed-period-pick');
      await tester.tap(find.text('10').first);
      await tester.pump();
      await tester.tap(find.text('12').first);
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      final f = c.read(transactionFilterProvider);
      expect(f.from, isNotNull);
      expect(f.to, isNotNull);
    });

    testWidgets('нет операций вообще: «Операций нет» и кнопка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        seedWith: (c) => addAccount(c, 'Наличные'),
      );
      expect(find.byKey(const Key('feed-empty')), findsOneWidget);
      expect(find.text('Операций нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('feed-empty-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('«+» в шапке открывает редактор', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('feed-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новая операция'), findsOneWidget);
    });

    testWidgets('тап по строке — правка операции', (tester) async {
      final (_, demo) = await _open(tester);
      await tester.tap(find.byKey(Key('tx-row-${demo.shop}')));
      await tester.pumpAndSettle();
      expect(find.text('Операция'), findsOneWidget);
      expect(fieldText(tester, 'tx-amount'), '1${_nb}249,90');
      expect(fieldText(tester, 'tx-merchant'), 'Пятёрочка');
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        overrides: [transactionRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        overrides: [
          transactionRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка над лентой', (tester) async {
      await _open(
        tester,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('feed-list')), findsOneWidget);
    });

    testWidgets('назад возвращает на обзор', (tester) async {
      await _open(tester);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });
  });

  group('удаление операции', () {
    testWidgets('свайп влево: в корзину, снэкбар «Отменить» возвращает', (
      tester,
    ) async {
      final (c, demo) = await _open(tester);
      await tester.fling(
        find.byKey(Key('tx-row-${demo.shop}')),
        const Offset(-400, 0),
        1500,
      );
      await settleDb(tester);
      expect(find.byKey(Key('tx-row-${demo.shop}')), findsNothing);
      expect(find.text('Операция удалена'), findsOneWidget);
      final left = await tester.runAsync(() => financeRepo(c).transactions());
      expect(left!.any((t) => t.id == demo.shop), isFalse);
      // Итоги месяца пересчитаны.
      expect(
        textOf(tester, 'month-sums-2026-09'),
        'Доход +20${_nb}000$_nb₽ · Расход −1${_nb}730$_nb₽',
      );
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(Key('tx-row-${demo.shop}')), findsOneWidget);
      expect(
        textOf(tester, 'month-sums-2026-09'),
        'Доход +20${_nb}000$_nb₽ · Расход −2${_nb}979,90$_nb₽',
      );
    });

    testWidgets('десктоп: меню «⋯» — изменить и удалить', (tester) async {
      final (_, demo) = await _open(tester, size: desktopSize);
      expect(find.byKey(Key('dismiss-tx-${demo.shop}')), findsNothing);
      await tester.tap(find.byKey(Key('tx-menu-${demo.shop}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('tx-menu-edit-${demo.shop}')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'tx-merchant'), 'Пятёрочка');
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('tx-menu-${demo.shop}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('tx-menu-delete-${demo.shop}')));
      await settleDb(tester);
      expect(find.byKey(Key('tx-row-${demo.shop}')), findsNothing);
      expect(find.text('Операция удалена'), findsOneWidget);
    });
  });
}
