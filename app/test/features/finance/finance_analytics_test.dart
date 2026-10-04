import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = phoneSize,
    DateTime? now,
    Future<void> Function(ProviderContainer c)? more,
  }) => pumpFinance(
    tester,
    location: '/finance/analytics',
    size: size,
    now: now,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      if (more != null) await more(c);
    },
  );

  group('«Аналитика»', () {
    testWidgets('месяц: доход, расход, итог — без переводов и черновика', (
      tester,
    ) async {
      await pump(tester);
      expect(_textOf(tester, 'analytics-month-title'), 'СЕНТЯБРЬ 2026');
      expect(_textOf(tester, 'analytics-income'), '+${nb('85 000 ₽')}');
      expect(_textOf(tester, 'analytics-expense'), nb('11 500 ₽'));
      expect(_textOf(tester, 'analytics-net'), '+${nb('73 500 ₽')}');
    });

    testWidgets('выбор месяца столбиком: август', (tester) async {
      await pump(tester);
      await tapKey(tester, 'month-bar-2026-08');
      expect(_textOf(tester, 'analytics-month-title'), 'АВГУСТ 2026');
      expect(_textOf(tester, 'analytics-income'), nb('0 ₽'));
      expect(_textOf(tester, 'analytics-expense'), nb('7 000 ₽'));
      expect(_textOf(tester, 'analytics-net'), '-${nb('7 000 ₽')}');
      // Месяц без операций — пропуск заполнен нулями, а не выпал.
      await tapKey(tester, 'month-bar-2026-07');
      expect(_textOf(tester, 'analytics-expense'), nb('0 ₽'));
      expect(
        find.byKey(const Key('analytics-categories-empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('analytics-merchants-empty')),
        findsOneWidget,
      );
    });

    testWidgets('6 и 12 месяцев', (tester) async {
      await pump(tester);
      expect(find.byType(MonthBars), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('month-bar-'),
        ),
        findsNWidgets(6),
      );
      await tapKey(tester, 'analytics-months-12');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('month-bar-'),
        ),
        findsNWidgets(12),
      );
    });

    testWidgets('категории с подкатегориями, проценты, бары; доходы', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(Key('analytics-cat-${groceriesId()}')), findsOneWidget);
      // Продукты 6 500 из 11 500 — 56 %.
      expect(find.text('56%'), findsOneWidget);
      expect(find.text(nb('6 500 ₽')), findsWidgets);
      // «Транспорт» складывается из подкатегории «Такси».
      expect(find.byKey(Key('analytics-cat-${transportId()}')), findsOneWidget);
      expect(find.byKey(Key('analytics-cat-${taxiId()}')), findsOneWidget);
      expect(find.text('Такси'), findsOneWidget);
      // Кафе: черновик 999 ₽ не вошёл — 3 000.
      expect(find.text(nb('3 000 ₽')), findsWidgets);
      expect(find.text(nb('3 999 ₽')), findsNothing);

      await tapKey(tester, 'analytics-kind-income');
      expect(
        find.byKey(Key('analytics-cat-${salaryCategoryId()}')),
        findsOneWidget,
      );
      expect(find.text('100%'), findsOneWidget);
      expect(find.byKey(Key('analytics-cat-${groceriesId()}')), findsNothing);
    });

    testWidgets('удалённая категория: деньги идут в «Без категории»', (
      tester,
    ) async {
      await pump(
        tester,
        more: (c) =>
            c.read(financeRepositoryProvider).deleteCategory(groceriesId()),
      );
      expect(find.byKey(const Key('analytics-cat-none')), findsOneWidget);
      expect(find.text('Без категории'), findsWidgets);
      expect(find.byKey(Key('analytics-cat-${groceriesId()}')), findsNothing);
    });

    testWidgets('топ мерчантов за месяц', (tester) async {
      await pump(tester);
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Кофемания'), findsOneWidget);
      // Лента, Рынок и такси — тоже, по убыванию суммы: Пятёрочка первой.
      expect(
        tester.getTopLeft(find.text('Пятёрочка')).dy,
        lessThan(tester.getTopLeft(find.text('Кофемания')).dy),
      );
      expect(find.text('1 операция'), findsWidgets);
      expect(find.text(nb('4 249,90 ₽')), findsWidgets);
      // Черновик из уведомления не мерчант аналитики.
      expect(find.text('Черновик из уведомления'), findsNothing);
      await tapKey(tester, 'analytics-kind-income');
      expect(find.text('Работодатель'), findsOneWidget);
    });

    testWidgets('динамика общего баланса и остатки по счетам', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('analytics-dynamics')), findsOneWidget);
      expect(_textOf(tester, 'analytics-dynamics-now'), nb('361 000 ₽'));
      for (final id in [demo.cash, demo.bank, demo.savings, demo.credit]) {
        expect(find.byKey(Key('analytics-account-$id')), findsOneWidget);
      }
    });

    testWidgets('граница суток по Москве: 23:59:59 — сентябрь, 00:00:00 — '
        'октябрь', (tester) async {
      await pump(
        tester,
        now: DateTime.utc(2026, 10, 15, 9),
        more: (c) async {
          final repo = c.read(financeRepositoryProvider);
          Future<void> expense(DateTime at, int amount) =>
              repo.createTransaction(
                FinTransaction(
                  id: repo.newId(),
                  kind: TxKind.expense,
                  accountId: demo.cash,
                  amount: amount,
                  occurredAt: at,
                ),
              );
          // 23:59:59 по Москве 30 сентября и 00:00:00 1 октября.
          await expense(DateTime.utc(2026, 9, 30, 20, 59, 59), 100000);
          await expense(DateTime.utc(2026, 9, 30, 21), 200000);
          // 00:30 по Москве 1 октября — всё ещё 30 сентября в UTC.
          await expense(DateTime.utc(2026, 9, 30, 21, 30), 50000);
        },
      );
      // Октябрь — текущий месяц: 2 000 + 500.
      expect(_textOf(tester, 'analytics-month-title'), 'ОКТЯБРЬ 2026');
      expect(_textOf(tester, 'analytics-expense'), nb('2 500 ₽'));
      await tapKey(tester, 'month-bar-2026-09');
      // Сентябрь: 11 500 + 1 000 на границе.
      expect(_textOf(tester, 'analytics-expense'), nb('12 500 ₽'));
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(_textOf(tester, 'analytics-income'), '+${nb('85 000 ₽')}');
    });

    testWidgets('пусто: нет счетов и операций', (tester) async {
      await pumpFinance(tester, location: '/finance/analytics');
      expect(find.byKey(const Key('analytics-empty')), findsOneWidget);
    });

    testWidgets('есть счёт, нет операций: нули, пустые списки', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        seedWith: seedAccountOnly,
      );
      expect(_textOf(tester, 'analytics-income'), nb('0 ₽'));
      expect(
        find.byKey(const Key('analytics-categories-empty')),
        findsOneWidget,
      );
    });

    testWidgets('режим «скрыть суммы» прячет суммы в графиках и списках', (
      tester,
    ) async {
      final container = await pump(tester);
      await pumpFinanceHidden(tester, container);
      expect(find.text(nb('85 000 ₽')), findsNothing);
      expect(_textOf(tester, 'analytics-income'), '••• ₽');
    });
  });
}
