import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

/// «205 000 ₽» с неразрывными пробелами; [kopecks] — «,49» и т. п.
String _rub(int rubles, {String kopecks = '', bool signed = false}) {
  final s = rubles.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(_nb);
    out.write(s[i]);
  }
  final sign = rubles < 0 ? '−' : (signed && rubles > 0 ? '+' : '');
  return '$sign$out$kopecks$_nb₽';
}

Future<(ProviderContainer, FinanceDemo)> _open(
  WidgetTester tester, {
  Size size = phoneSize,
  List<Override> overrides = const [],
  Future<void> Function(ProviderContainer c, FinanceDemo d)? extra,
}) async {
  late FinanceDemo demo;
  final c = await pumpFinance(
    tester,
    size: size,
    overrides: overrides,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      if (extra != null) await extra(c, demo);
    },
  );
  await goTo(tester, '/finance/analytics');
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

void main() {
  group('Аналитика: состояния', () {
    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        overrides: [transactionRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('analytics-scroll')), findsNothing);
    });

    testWidgets('пусто: «Нет операций за этот период», счета и баланс '
        'остаются', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        seedWith: (c) => addAccount(c, 'Карта', opening: 150000),
      );
      expect(find.byKey(const Key('analytics-empty')), findsOneWidget);
      expect(find.text('Нет операций за этот период'), findsOneWidget);
      expect(find.byKey(const Key('chart-months')), findsNothing);
      expect(textOf(tester, 'analytics-income'), '0$_nb₽');
      expect(textOf(tester, 'analytics-net'), '0$_nb₽');
      // без операций нет ни категорий, ни мерчантов
      expect(find.byKey(const Key('analytics-categories')), findsNothing);
      expect(find.byKey(const Key('analytics-merchants')), findsNothing);
      // остатки по счетам и динамика баланса есть
      expect(textOf(tester, 'analytics-total'), _rub(1500));
      expect(find.byKey(const Key('chart-balance')), findsOneWidget);
    });

    testWidgets('совсем пусто: ни счетов, ни операций', (tester) async {
      await pumpFinance(tester, location: '/finance/analytics');
      expect(find.byKey(const Key('analytics-empty')), findsOneWidget);
      expect(find.byKey(const Key('analytics-balances')), findsNothing);
      expect(find.byKey(const Key('analytics-dynamics')), findsNothing);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        overrides: [
          categoryRowsProvider.overrideWith(
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
      await _open(tester, overrides: _offline);
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('analytics-months')), findsOneWidget);
    });
  });

  group('Аналитика: данные', () {
    testWidgets('доход, расход и итог за 3 месяца; графики на месте', (
      tester,
    ) async {
      await _open(tester);
      // доходы: 185 000 (авг) + 20 000 (сен); переводы не считаются
      expect(textOf(tester, 'analytics-income'), _rub(205000));
      // расходы: 6 400 + 1 310 + 420 + 1 249,90
      expect(textOf(tester, 'analytics-expense'), _rub(9379, kopecks: ',90'));
      expect(
        textOf(tester, 'analytics-net'),
        _rub(195620, kopecks: ',10', signed: true),
      );
      expect(find.byKey(const Key('chart-months')), findsOneWidget);
      expect(find.byKey(const Key('chart-balance')), findsOneWidget);
      expect(find.byKey(const Key('analytics-empty')), findsNothing);
      expect(find.byKey(const Key('analytics-period-quarter')), findsOneWidget);
    });

    testWidgets('период: «Месяц» оставляет только сентябрь, «Всё» — всё', (
      tester,
    ) async {
      final (c, _) = await _open(tester);
      await tapKey(tester, 'analytics-period-month');
      expect(c.read(analyticsPresetProvider), AnalyticsPreset.month);
      expect(textOf(tester, 'analytics-income'), _rub(20000));
      expect(textOf(tester, 'analytics-expense'), _rub(2979, kopecks: ',90'));
      await tapKey(tester, 'analytics-period-all');
      expect(textOf(tester, 'analytics-income'), _rub(205000));
      await tapKey(tester, 'analytics-period-year');
      expect(textOf(tester, 'analytics-income'), _rub(205000));
      await tapKey(tester, 'analytics-period-half');
      expect(textOf(tester, 'analytics-income'), _rub(205000));
    });

    testWidgets('остатки по счетам и общий баланс', (tester) async {
      final (_, d) = await _open(tester);
      expect(textOf(tester, 'analytics-balance-${d.cash}'), _rub(49000));
      expect(
        textOf(tester, 'analytics-balance-${d.tbank}'),
        _rub(195620, kopecks: ',10'),
      );
      expect(textOf(tester, 'analytics-balance-${d.vtb}'), _rub(-12500));
      expect(textOf(tester, 'analytics-balance-${d.savings}'), _rub(13000));
      expect(textOf(tester, 'analytics-total'), _rub(245120, kopecks: ',10'));
    });

    testWidgets('счёт вне общего баланса подписан; архивный не показан', (
      tester,
    ) async {
      late String outside;
      late String hidden;
      await _open(
        tester,
        extra: (c, d) async {
          outside = await addAccount(
            c,
            'Копилка',
            includeInTotal: false,
            opening: 100000,
          );
          hidden = await addAccount(c, 'Старый', archived: true);
        },
      );
      expect(find.text('Копилка · вне общего'), findsOneWidget);
      expect(find.byKey(Key('analytics-account-$outside')), findsOneWidget);
      expect(find.byKey(Key('analytics-account-$hidden')), findsNothing);
    });

    testWidgets('категории: расходы по убыванию, «Без категории»; '
        'переключение на доходы', (tester) async {
      final (_, d) = await _open(
        tester,
        extra: (c, d) => addTx(
          c,
          account: d.tbank,
          amount: 50000,
          at: '2026-09-15T10:00:00',
        ),
      );
      expect(find.byKey(Key('analytics-category-${d.groceries}')), findsOne);
      expect(find.text('Продукты'), findsOneWidget);
      expect(find.text('Без категории'), findsOneWidget);
      expect(find.text('Кафе и рестораны'), findsOneWidget);
      // Продукты (7 649,90) выше Кафе (1 310): сравниваем положение
      final top = tester.getTopLeft(
        find.byKey(Key('analytics-category-${d.groceries}')),
      );
      final cafe = tester.getTopLeft(find.text('Кафе и рестораны'));
      expect(top.dy, lessThan(cafe.dy));
      // доли — процентом усечением до одной цифры: 764 990 из 987 990
      expect(find.text('77,4 %'), findsOneWidget);
      // доходы
      await tapKey(tester, 'analytics-kind-income');
      expect(find.text('Зарплата'), findsOneWidget);
      expect(find.text('Доход с проектов'), findsOneWidget);
      expect(find.text('Продукты'), findsNothing);
      expect(find.byKey(const Key('analytics-categories-empty')), findsNothing);
    });

    testWidgets('подкатегории: группа раскрывается, свои операции отдельной '
        'строкой', (tester) async {
      late String taxi;
      late String transport;
      final (_, _) = await _open(
        tester,
        extra: (c, d) async {
          final all = await financeRepo(c).categories();
          taxi = all.firstWhere((x) => x.name == 'Такси').id;
          transport = all.firstWhere((x) => x.name == 'Транспорт').id;
          await addTx(
            c,
            account: d.tbank,
            amount: 300000,
            category: taxi,
            at: '2026-09-18T10:00:00',
          );
        },
      );
      // группа «Транспорт»: свои 420 + такси 3 000
      expect(find.byKey(Key('analytics-category-$transport')), findsOneWidget);
      expect(find.byKey(Key('analytics-category-$taxi')), findsNothing);
      await tester.tap(find.byKey(Key('analytics-category-$transport')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('analytics-category-$taxi')), findsOneWidget);
      expect(find.text('Такси'), findsOneWidget);
      expect(
        find.byKey(Key('analytics-category-$transport-own')),
        findsOneWidget,
      );
      expect(find.text('Без подкатегории'), findsOneWidget);
      // повторный тап сворачивает
      await tester.tap(find.byKey(Key('analytics-category-$transport')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('analytics-category-$taxi')), findsNothing);
    });

    testWidgets('доходов нет — подсказка вместо списка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        seedWith: (c) async {
          final a = await addAccount(c, 'Карта', opening: 100000);
          await addTx(c, account: a, amount: 1000, merchant: 'Кофе');
        },
      );
      await tapKey(tester, 'analytics-kind-income');
      expect(
        find.byKey(const Key('analytics-categories-empty')),
        findsOneWidget,
      );
      expect(find.text('Доходов за этот период нет.'), findsOneWidget);
      expect(
        find.byKey(const Key('analytics-merchants-empty')),
        findsOneWidget,
      );
    });

    testWidgets('топ мерчантов: расходы по убыванию, потом источники дохода', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const Key('analytics-merchant-0')), findsOneWidget);
      // самый крупный расход — «Перекрёсток» 6 400 ₽
      final first = tester.widget<Column>(
        find.byKey(const Key('analytics-merchant-0')),
      );
      expect(
        find.descendant(
          of: find.byWidget(first),
          matching: find.text('Перекрёсток'),
        ),
        findsOneWidget,
      );
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Додо Пицца'), findsOneWidget);
      expect(find.text('ТОП МЕРЧАНТОВ ПО РАСХОДАМ'), findsOneWidget);
      await tapKey(tester, 'analytics-kind-income');
      expect(find.text('ТОП ИСТОЧНИКОВ ДОХОДА'), findsOneWidget);
      expect(find.text('Creora'), findsOneWidget);
      expect(find.text('Рома · Бот'), findsOneWidget);
      expect(find.text('Перекрёсток'), findsNothing);
    });

    testWidgets('граница месяца по Москве: 23:59:59 — сентябрь, 00:00:00 — '
        'октябрь', (tester) async {
      late String card;
      await pumpFinance(
        tester,
        location: '/finance/analytics',
        seedWith: (c) async {
          card = await addAccount(c, 'Карта', opening: 1000000);
          // 23:59:59 МСК 30 сентября (сегодня) и 00:00:00 МСК 1 октября
          await addTx(
            c,
            account: card,
            amount: 100000,
            at: '2026-09-30T20:59:59',
            merchant: 'Вечер',
          );
          await addTx(
            c,
            account: card,
            amount: 200000,
            at: '2026-09-30T21:00:00',
            merchant: 'Полночь',
          );
        },
      );
      // «3 мес» до конца текущего месяца (сентября): октябрьская не входит
      expect(textOf(tester, 'analytics-expense'), _rub(1000));
      expect(find.text('Вечер'), findsOneWidget);
      expect(find.text('Полночь'), findsNothing);
      // «Месяц» то же самое
      await tapKey(tester, 'analytics-period-month');
      expect(textOf(tester, 'analytics-expense'), _rub(1000));
      // «Всё» — захватывает и октябрь
      await tapKey(tester, 'analytics-period-all');
      expect(textOf(tester, 'analytics-expense'), _rub(3000));
      expect(find.text('Полночь'), findsOneWidget);
      // остаток по счетам — «сейчас» по всем данным, как на экране «Финансы»
      expect(textOf(tester, 'analytics-total'), _rub(7000));
    });

    testWidgets('новая операция обновляет аналитику сразу', (tester) async {
      final (c, d) = await _open(tester);
      expect(textOf(tester, 'analytics-income'), _rub(205000));
      await _db(
        tester,
        () => addTx(
          c,
          account: d.tbank,
          amount: 100000,
          kind: TransactionKind.income,
          at: '2026-09-30T08:00:00',
        ),
      );
      expect(textOf(tester, 'analytics-income'), _rub(206000));
    });
  });

  group('Аналитика: глоссарий', () {
    testWidgets('иконка в шапке открывает «что считаем»', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('analytics-glossary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analytics-glossary-sheet')), findsOneWidget);
      Finder inSheet(String text) => find.descendant(
        of: find.byKey(const Key('analytics-glossary-sheet')),
        matching: find.text(text),
      );
      expect(inSheet('Доход месяца'), findsOneWidget);
      expect(inSheet('Расход месяца'), findsOneWidget);
      expect(inSheet('Итог месяца'), findsOneWidget);
      expect(inSheet('Общий баланс'), findsOneWidget);
      expect(inSheet('Мне должны / Я должен'), findsOneWidget);
      expect(find.textContaining('Переводы между своими счетами'), findsOne);
    });

    testWidgets('подсказки «что такое доход месяца» и «общий баланс»', (
      tester,
    ) async {
      await _open(tester);
      await tapKey(tester, 'analytics-hint-income');
      expect(find.byKey(const Key('analytics-glossary-sheet')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analytics-glossary-sheet')), findsNothing);
      await tapKey(tester, 'analytics-hint-balance');
      expect(find.byKey(const Key('analytics-glossary-sheet')), findsOneWidget);
      expect(find.textContaining('Учитывать в общем балансе'), findsOneWidget);
    });
  });

  group('Аналитика: навигация и раскладка', () {
    testWidgets('вход из «Финансы» и обратно', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      await tester.tap(find.byKey(const Key('finance-open-analytics')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analytics-scroll')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-open-analytics')), findsOneWidget);
    });

    testWidgets('десктоп: две колонки — итоги слева, категории справа', (
      tester,
    ) async {
      await _open(tester, size: desktopSize);
      final months = tester.getTopLeft(
        find.byKey(const Key('analytics-months')),
      );
      final categories = tester.getTopLeft(
        find.byKey(const Key('analytics-categories')),
      );
      expect(categories.dx, greaterThan(months.dx + 400));
      expect(find.byKey(const Key('chart-months')), findsOneWidget);
      expect(find.byKey(const Key('chart-balance')), findsOneWidget);
    });

    testWidgets('десктоп без операций: одна колонка', (tester) async {
      await pumpFinance(
        tester,
        size: desktopSize,
        location: '/finance/analytics',
        seedWith: (c) => addAccount(c, 'Карта', opening: 5000),
      );
      expect(find.byKey(const Key('analytics-empty')), findsOneWidget);
      expect(find.byKey(const Key('analytics-categories')), findsNothing);
    });
  });
}
