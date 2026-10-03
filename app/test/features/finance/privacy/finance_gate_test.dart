import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/privacy_env.dart';
import '../../../support/pump_app.dart';

/// Все маршруты `/finance/**`: охранник стоит на каждом. Новый маршрут без
/// охранника должен попасть сюда — иначе тест `набор маршрутов` упадёт.
const _financeRoutes = {
  '/finance': '/finance',
  '/finance/transactions': '/finance/transactions',
  '/finance/categories': '/finance/categories',
  '/finance/debts': '/finance/debts',
  '/finance/debts/:id': '/finance/debts/x',
  '/finance/goals': '/finance/goals',
  '/finance/goals/:id': '/finance/goals/x',
  '/finance/analytics': '/finance/analytics',
  '/finance/privacy': '/finance/privacy',
  '/finance/accounts/:id': '/finance/accounts/x',
  '/finance/accounts/:id/reconcile': '/finance/accounts/x/reconcile',
};

List<String> _declaredFinancePaths(GoRouter router) {
  final out = <String>[];
  void walk(List<RouteBase> routes, String prefix) {
    for (final r in routes) {
      if (r is GoRoute) {
        final full = r.path.startsWith('/') ? r.path : '$prefix/${r.path}';
        out.add(full);
        walk(r.routes, full);
      } else if (r is StatefulShellRoute) {
        for (final b in r.branches) {
          walk(b.routes, prefix);
        }
      } else {
        walk(r.routes, prefix);
      }
    }
  }

  walk(router.configuration.routes, '');
  return [
    for (final p in out)
      if (p == '/finance' || p.startsWith('/finance/')) p,
  ];
}

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

void _expectLocked(WidgetTester tester) {
  expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);
  expect(find.byKey(const Key('pin-dots')), findsOneWidget);
  expect(find.textContaining('₽'), findsNothing);
}

void main() {
  group('охранник маршрутов Финансов', () {
    testWidgets('набор маршрутов: каждый /finance/** учтён в тесте', (
      tester,
    ) async {
      await pumpFinance(tester);
      final router = GoRouter.of(_ctx(tester));
      expect(
        _declaredFinancePaths(router).toSet(),
        _financeRoutes.keys.toSet(),
        reason:
            'Новый маршрут /finance/** нужно закрыть FinanceGate и '
            'добавить сюда',
      );
    });

    for (final entry in _financeRoutes.entries) {
      testWidgets('замок закрыт: ${entry.key} (глубокая ссылка) — экран PIN, '
          'без сумм', (tester) async {
        await pumpFinance(
          tester,
          location: entry.value,
          privacyStore: lockedStore(),
          seedWith: seedFinanceDemo,
        );
        _expectLocked(tester);
        expect(find.byKey(const Key('finance-total')), findsNothing);
        expect(find.byKey(const Key('feed-search')), findsNothing);
      });
    }

    testWidgets('верный PIN открывает ту же страницу, на которую вела '
        'ссылка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      _expectLocked(tester);
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
      expect(find.byKey(const Key('feed-search')), findsOneWidget);
    });

    testWidgets('холодный старт: замок включён — «Финансы» закрыты, суммы '
        'не мелькают', (tester) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      _expectLocked(tester);
      expect(find.byKey(const Key('finance-overview')), findsNothing);
    });

    testWidgets('замок выключен: раздел открыт без PIN', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('неверный PIN: дрожь, подсказка, поле очищено', (tester) async {
      await pumpFinance(tester, privacyStore: lockedStore());
      await enterPin(tester, testPinOther);
      _expectLocked(tester);
      expect(pinMessage(tester), contains('Неверный PIN'));
      expect(pinMessage(tester), contains('4'));
      // Точки очищены: заполненных нет.
      final filled = tester.widgetList<Container>(
        find.descendant(
          of: find.byKey(const Key('pin-dots')),
          matching: find.byType(Container),
        ),
      );
      for (final dot in filled) {
        expect((dot.decoration! as BoxDecoration).color, Colors.transparent);
      }
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
    });

    testWidgets('пять ошибок: пауза с обратным отсчётом, ввод закрыт, '
        'потом снова открыт', (tester) async {
      var now = demoNow;
      await pumpFinance(tester, privacyStore: lockedStore(), clock: () => now);
      for (var i = 0; i < 5; i++) {
        await enterPin(tester, testPinOther);
      }
      expect(pinMessage(tester), 'Слишком много попыток. Повторите через 0:30');
      // Верный PIN во время паузы не принимается: клавиши отключены.
      await enterPin(tester, testPin);
      _expectLocked(tester);

      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(pinMessage(tester), 'Слишком много попыток. Повторите через 0:20');

      now = now.add(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('pin-message')), findsNothing);
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
    });

    testWidgets('цифры работают и с клавиатуры, Backspace стирает', (
      tester,
    ) async {
      await pumpFinance(tester, privacyStore: lockedStore());
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad4);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit6);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad8);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
    });

    testWidgets('биометрия: при показе — системный запрос и вход без PIN', (
      tester,
    ) async {
      final bio = FakeBiometric(available: true);
      await pumpFinance(
        tester,
        privacyStore: lockedStore(biometric: true),
        biometric: bio,
      );
      expect(bio.prompts, 1);
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
    });

    testWidgets('биометрия отклонена: кнопка на клавиатуре, PIN как запасной '
        'путь', (tester) async {
      final bio = FakeBiometric(available: true, result: false);
      await pumpFinance(
        tester,
        privacyStore: lockedStore(biometric: true),
        biometric: bio,
      );
      _expectLocked(tester);
      expect(find.byKey(const Key('pin-biometric')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pin-biometric')));
      await tester.pumpAndSettle();
      expect(bio.prompts, 2);
      bio.result = true;
      await tester.tap(find.byKey(const Key('pin-biometric')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
    });

    testWidgets('биометрия недоступна: кнопки нет', (tester) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(biometric: true),
        biometric: FakeBiometric(),
      );
      expect(find.byKey(const Key('pin-biometric')), findsNothing);
    });
  });

  group('блокировка по времени в приложении', () {
    Future<void> background(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
    }

    Future<void> foreground(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    testWidgets('«сразу»: свернул и вернулся — снова PIN', (tester) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
      await background(tester);
      await foreground(tester);
      _expectLocked(tester);
    });

    testWidgets('«сразу»: ушёл в другой раздел — по возвращении PIN', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await enterPin(tester, testPin);
      await goTo(tester, '/today');
      await goTo(tester, '/finance');
      _expectLocked(tester);
    });

    testWidgets('шторка и потеря фокуса (inactive) раздел не закрывают', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await enterPin(tester, testPin);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await foreground(tester);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('сетка «Разделы» вне оболочки — тоже уход из раздела', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await enterPin(tester, testPin);
      await goTo(tester, '/sections');
      await settleDb(tester);
      await goTo(tester, '/finance');
      _expectLocked(tester);
    });

    testWidgets('сетка «Разделы» дольше срока «через 5 мин» — закрыто, '
        'короче — открыто', (tester) async {
      var now = demoNow;
      await pumpFinance(
        tester,
        privacyStore: lockedStore(timing: LockTiming.minute5),
        seedWith: seedFinanceDemo,
        clock: () => now,
      );
      await enterPin(tester, testPin);
      await goTo(tester, '/sections');
      now = now.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2));
      await goTo(tester, '/finance');
      expect(find.byKey(const Key('finance-total')), findsOneWidget);

      await goTo(tester, '/sections');
      now = now.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      await goTo(tester, '/finance');
      _expectLocked(tester);
    });

    testWidgets('«через 1 мин»: 30 с — открыто, после минуты — закрыто', (
      tester,
    ) async {
      var now = demoNow;
      await pumpFinance(
        tester,
        privacyStore: lockedStore(timing: LockTiming.minute1),
        seedWith: seedFinanceDemo,
        clock: () => now,
      );
      await enterPin(tester, testPin);

      await background(tester);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await foreground(tester);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);

      await background(tester);
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await foreground(tester);
      _expectLocked(tester);
    });

    testWidgets('«через 5 мин»: выход из раздела на 4 мин — открыто, на 6 — '
        'закрыто', (tester) async {
      var now = demoNow;
      await pumpFinance(
        tester,
        privacyStore: lockedStore(timing: LockTiming.minute5),
        seedWith: seedFinanceDemo,
        clock: () => now,
      );
      await enterPin(tester, testPin);

      await goTo(tester, '/today');
      now = now.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      await goTo(tester, '/finance');
      expect(find.byKey(const Key('finance-total')), findsOneWidget);

      await goTo(tester, '/today');
      now = now.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      await goTo(tester, '/finance');
      _expectLocked(tester);
    });
  });

  group('«+» и создание операции при закрытом замке', () {
    testWidgets('из другого раздела: сначала PIN, потом редактор', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsNothing);

      await enterPin(tester, testPinOther);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      expect(pinMessage(tester), contains('Неверный PIN'));

      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('отмена окна PIN: редактор не открывается, раздел закрыт', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-unlock-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      final container = ProviderScope.containerOf(_ctx(tester));
      expect(container.read(financeLockProvider).closed, isTrue);
    });

    testWidgets('общая «+» в разделе «Финансы» при закрытом замке — окно PIN', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await tester.tap(find.byKey(const Key('create-fab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
    });

    testWidgets('замок снят: редактор открывается сразу, окна PIN нет', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await ProviderScope.containerOf(_ctx(tester))
          .read(financeLockProvider.notifier)
          .unlock(testPin);
      await tester.pumpAndSettle();
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('десктоп: окно PIN из другого раздела', (tester) async {
      await pumpFinance(
        tester,
        size: desktopSize,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });
  });

  group('маска сумм и замок', () {
    testWidgets('закрытый замок маскирует суммы для всех потребителей', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      final container = ProviderScope.containerOf(_ctx(tester));
      expect(container.read(amountsMaskedProvider), isTrue);
      await container.read(financeLockProvider.notifier).unlock(testPin);
      expect(container.read(amountsMaskedProvider), isFalse);
    });
  });
}
