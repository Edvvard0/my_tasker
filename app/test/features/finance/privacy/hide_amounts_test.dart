import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/pump_app.dart';

/// Сумма с «₽»: цифры (разряды через пробелы), необязательные копейки, «₽».
final RegExp _amount = RegExp(r'\d[\d\s  ]*(?:,\d{1,2})?\s*₽');

const _nb = ' ';

class _Ids {
  late FinanceDemo finance;
  late DebtsDemo debts;
  late String goal;
}

/// Тексты всех `Text` на экране (включая `Text.rich`).
Iterable<String> _texts(WidgetTester tester) sync* {
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final text = t.data ?? t.textSpan?.toPlainText();
    if (text != null) yield text;
  }
}

List<String> _amountTexts(WidgetTester tester) => [
  for (final t in _texts(tester))
    if (_amount.hasMatch(t)) t,
];

/// Ни один текст и ни одна семантическая подпись не содержат сумму.
void _expectNoAmounts(WidgetTester tester, String where) {
  expect(
    _amountTexts(tester),
    isEmpty,
    reason: '$where: на экране видны суммы',
  );
  expect(
    find.bySemanticsLabel(_amount),
    findsNothing,
    reason: '$where: суммы в подписях доступности',
  );
}

typedef _Screen = ({String name, String Function(_Ids) path, bool amounts});

final List<_Screen> _screens = [
  (name: 'Финансы', path: (_) => '/finance', amounts: true),
  (name: 'Операции', path: (_) => '/finance/transactions', amounts: true),
  (
    name: 'Счёт',
    path: (i) => '/finance/accounts/${i.finance.tbank}',
    amounts: true,
  ),
  (
    name: 'Сверка',
    path: (i) => '/finance/accounts/${i.finance.tbank}/reconcile',
    amounts: true,
  ),
  (name: 'Долги', path: (_) => '/finance/debts', amounts: true),
  (
    name: 'Долг',
    path: (i) => '/finance/debts/${i.debts.nastya}',
    amounts: true,
  ),
  (name: 'Цели', path: (_) => '/finance/goals', amounts: true),
  (name: 'Цель', path: (i) => '/finance/goals/${i.goal}', amounts: true),
  (name: 'Аналитика', path: (_) => '/finance/analytics', amounts: true),
  (name: 'Категории', path: (_) => '/finance/categories', amounts: false),
];

Future<_Ids> _seed(ProviderContainer c) async {
  final ids = _Ids()
    ..finance = await seedFinanceDemo(c)
    ..debts = await seedDebtsDemo(c)
    ..goal = await addGoal(
      c,
      name: 'Отпуск',
      target: 40000000,
      deadline: '2026-12-31',
    );
  return ids;
}

Future<_Ids> _pumpHidden(
  WidgetTester tester, {
  Size size = phoneSize,
  bool hidden = true,
  MemoryFinancePrivacyStore? store,
}) async {
  final ids = _Ids();
  await pumpFinance(
    tester,
    size: size,
    privacyStore: store ?? MemoryFinancePrivacyStore(hidden: hidden),
    seedWith: (c) async {
      final seeded = await _seed(c);
      ids
        ..finance = seeded.finance
        ..debts = seeded.debts
        ..goal = seeded.goal;
    },
  );
  return ids;
}

Future<void> _open(WidgetTester tester, String path) async {
  await goTo(tester, path);
  await settleDb(tester);
}

void main() {
  group('«скрыть суммы»: на каждом экране Финансов нет ни одной суммы', () {
    for (final screen in _screens) {
      testWidgets('${screen.name} (телефон)', (tester) async {
        final ids = await _pumpHidden(tester);
        await _open(tester, screen.path(ids));
        _expectNoAmounts(tester, screen.name);
        if (screen.amounts) {
          expect(
            find.textContaining(hiddenMoneyText),
            findsWidgets,
            reason: '${screen.name}: суммы должны быть заменены на маску',
          );
        }
      });
    }

    for (final screen in _screens.where((s) => s.amounts)) {
      testWidgets('${screen.name} (десктоп)', (tester) async {
        final ids = await _pumpHidden(tester, size: desktopSize);
        await _open(tester, screen.path(ids));
        _expectNoAmounts(tester, '${screen.name} (десктоп)');
        expect(find.textContaining(hiddenMoneyText), findsWidgets);
      });
    }

    testWidgets('контроль: без режима те же экраны показывают суммы', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester, hidden: false);
      for (final screen in _screens.where((s) => s.amounts)) {
        await _open(tester, screen.path(ids));
        expect(
          _amountTexts(tester),
          isNotEmpty,
          reason: '${screen.name}: в обычном режиме суммы должны быть видны',
        );
        expect(find.textContaining(hiddenMoneyText), findsNothing);
      }
    });

    testWidgets('конкретные суммы: ни одного фрагмента демо-данных', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester);
      for (final fragment in const [
        '245${_nb}120',
        '195${_nb}620',
        '1${_nb}249',
        '12${_nb}500',
      ]) {
        for (final screen in _screens) {
          await _open(tester, screen.path(ids));
          expect(
            find.textContaining(fragment),
            findsNothing,
            reason: '${screen.name}: фрагмент «$fragment»',
          );
        }
      }
    });

    testWidgets('ось графиков скрыта: подписи «••••», перерисовка по режиму', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester);
      await _open(tester, '/finance/analytics');
      for (final key in const ['chart-months', 'chart-balance']) {
        final finder = find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(CustomPaint),
        );
        expect(finder, findsWidgets, reason: key);
        final painter = tester.widget<CustomPaint>(finder.first).painter!;
        expect((painter as dynamic).hideAmounts, isTrue, reason: key);
      }
      expect(ids.goal, isNotEmpty);
    });

    testWidgets('ось графиков в обычном режиме показывает суммы', (
      tester,
    ) async {
      await _pumpHidden(tester, hidden: false);
      await _open(tester, '/finance/analytics');
      final finder = find.descendant(
        of: find.byKey(const Key('chart-months')),
        matching: find.byType(CustomPaint),
      );
      final painter = tester.widget<CustomPaint>(finder.first).painter!;
      expect((painter as dynamic).hideAmounts, isFalse);
    });
  });

  group('«скрыть суммы»: листы и подтверждения', () {
    testWidgets('архивация счёта: в окне подтверждения маска, не сумма', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester);
      await _open(tester, '/finance/accounts/${ids.finance.tbank}');
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-archive')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(find.textContaining('На счёте $hiddenMoneyText'), findsOneWidget);
      _expectNoAmounts(tester, 'подтверждение архивации');
    });

    testWidgets('удаление счёта: в окне подтверждения маска', (tester) async {
      final ids = await _pumpHidden(tester);
      await _open(tester, '/finance/accounts/${ids.finance.tbank}');
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(find.textContaining('На счёте $hiddenMoneyText'), findsOneWidget);
      _expectNoAmounts(tester, 'подтверждение удаления счёта');
    });

    testWidgets('лист погашения: остаток и «Закрыть остаток» — маска', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester);
      await _open(tester, '/finance/debts/${ids.debts.emir}');
      await tapKey(tester, 'debt-repay');
      expect(
        textOf(tester, 'repay-context'),
        'Эмир · остаток $hiddenMoneyText',
      );
      _expectNoAmounts(tester, 'лист погашения');
    });
  });

  group('«скрыть суммы»: свой ввод остаётся видимым', () {
    testWidgets('новая операция: набранная сумма видна, баланс — нет', (
      tester,
    ) async {
      final ids = await _pumpHidden(tester);
      await tester.tap(find.byKey(const Key('finance-quick-expense')));
      await tester.pumpAndSettle();
      await enter(tester, 'tx-amount', '1249,9');
      final typed = fieldText(tester, 'tx-amount');
      expect(typed, contains('249'));
      expect(typed, isNot(contains('•')));
      _expectNoAmounts(tester, 'редактор операции');
      expect(ids.finance.tbank, isNotEmpty);
    });

    testWidgets('правка операции: поле суммы показывает настоящее значение, '
        'лента — маску', (tester) async {
      final ids = await _pumpHidden(tester);
      final row = find.byKey(Key('tx-row-${ids.finance.shop}'));
      await tester.ensureVisible(row);
      expect(
        find.descendant(of: row, matching: find.text(hiddenMoneyText)),
        findsOneWidget,
      );
      await tapKey(tester, 'tx-row-${ids.finance.shop}');
      expect(fieldText(tester, 'tx-amount'), '1${_nb}249,90');
    });
  });

  group('«глаз» и настройка', () {
    testWidgets('глаз переключает режим и запоминает его на устройстве', (
      tester,
    ) async {
      final store = MemoryFinancePrivacyStore();
      await _pumpHidden(tester, hidden: false, store: store);
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(find.byTooltip('Скрыть суммы'), findsOneWidget);

      await tester.tap(find.byKey(const Key('finance-toggle-hide')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'finance-total'), hiddenMoneyText);
      expect(store.hidden, isTrue);
      expect(find.byTooltip('Показать суммы'), findsOneWidget);
      _expectNoAmounts(tester, 'после «глаза»');

      await tester.tap(find.byKey(const Key('finance-toggle-hide')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(store.hidden, isFalse);
    });

    testWidgets('режим пережил перезапуск: суммы скрыты с первого кадра', (
      tester,
    ) async {
      final store = MemoryFinancePrivacyStore(hidden: true);
      await _pumpHidden(tester, store: store);
      expect(textOf(tester, 'finance-total'), hiddenMoneyText);
      expect(
        ProviderScope.containerOf(tester.element(find.byType(Scaffold).first))
            .read(hideAmountsProvider)
            .hidden,
        isTrue,
      );
    });

    testWidgets('в шапке не больше трёх иконок', (tester) async {
      await _pumpHidden(tester, hidden: false);
      for (final key in const [
        'finance-open-feed',
        'finance-toggle-hide',
        'finance-open-privacy',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      // В шапке не больше трёх иконок (02): поиск, «глаз», приватность.
      final scaffold = tester.widget<ScreenScaffold>(
        find.byType(ScreenScaffold).first,
      );
      expect(scaffold.actions, hasLength(3));
    });
  });

  group('единая точка форматирования сумм', () {
    test('экраны Финансов не обходят `context.money`', () {
      final root = Directory('lib/features/finance');
      expect(root.existsSync(), isTrue);
      const allowedFiles = {
        // Сами форматеры и маска.
        'finance_format.dart',
        'finance_money.dart',
        // Подписи чипов-шагов «+100»: константы интерфейса, не суммы.
        'amount_field.dart',
        // Ось графика: маска применяется в `_axisText`.
        'charts.dart',
      };
      final raw = RegExp(
        r'\b(moneyText|transactionAmountText|axisAmountText|formatAmount)\b',
      );
      final offenders = <String>[];
      for (final file in root.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final name = file.uri.pathSegments.last;
        final inLogic =
            file.path.contains('domain') ||
            file.path.contains(
              '${Platform.pathSeparator}data${Platform.pathSeparator}',
            ) ||
            file.path.contains(
              '${Platform.pathSeparator}application${Platform.pathSeparator}',
            );
        if (allowedFiles.contains(name) || inLogic) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          // Параметр по умолчанию чистых функций подписей.
          if (line.contains('MoneyFormat money = moneyText')) continue;
          if (raw.hasMatch(line)) offenders.add('${file.path}:${i + 1}: $line');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
