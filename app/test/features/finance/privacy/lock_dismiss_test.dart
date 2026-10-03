import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/privacy_env.dart';
import '../../../support/pump_app.dart';

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(_ctx(tester));

/// Раздел «Финансы» открыт PIN-ом, замок — «сразу».
Future<void> _openUnlocked(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/finance',
}) async {
  await pumpFinance(
    tester,
    size: size,
    location: location,
    privacyStore: lockedStore(),
    seedWith: seedFinanceDemo,
  );
  await enterPin(tester, testPin);
  expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
}

Future<void> _background(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  await tester.pump();
}

void main() {
  group('блокировка закрывает открытые листы и диалоги', () {
    for (final desktop in [false, true]) {
      testWidgets('редактор операции (${desktop ? 'панель' : 'лист'}): '
          'свернул при «Сразу» — окна нет, экран PIN, черновик пропал', (
        tester,
      ) async {
        await _openUnlocked(tester, size: desktop ? desktopSize : phoneSize);
        unawaited(showTransactionEditor(_ctx(tester)));
        await tester.pumpAndSettle();
        await enter(tester, 'tx-amount', '9999');
        await enter(tester, 'tx-merchant', 'Секретный магазин');
        expect(find.byKey(const Key('tx-amount')), findsOneWidget);

        // Пока приложение свёрнуто, кадры не строятся: проверяем после
        // возвращения — окна уже нет, под ним экран PIN.
        await _background(tester);
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('tx-amount')), findsNothing);
        expect(find.textContaining('Секретный магазин'), findsNothing);
        expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);
        expect(find.byKey(const Key('pin-dots')), findsOneWidget);

        // Ввели PIN: страница та же, а черновика нет.
        await enterPin(tester, testPin);
        expect(find.byKey(const Key('finance-lock-screen')), findsNothing);
        unawaited(showTransactionEditor(_ctx(tester)));
        await tester.pumpAndSettle();
        expect(fieldText(tester, 'tx-amount'), isEmpty);
        expect(fieldText(tester, 'tx-merchant'), isEmpty);
      });
    }

    testWidgets('«заблокировать сейчас»: лист, диалог и снекбар закрыты', (
      tester,
    ) async {
      await _openUnlocked(tester);
      ScaffoldMessenger.of(_ctx(tester))
          .showSnackBar(const SnackBar(content: Text('Остаток 12 345 ₽')));
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      // Поверх листа — ещё и диалог.
      unawaited(
        showDialog<void>(
          context: _ctx(tester),
          builder: (_) => const AlertDialog(content: Text('Удалить на 500 ₽?')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Удалить на 500 ₽?'), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);

      _container(tester).read(financeLockProvider.notifier).lockNow();
      await tester.pumpAndSettle();

      expect(find.text('Удалить на 500 ₽?'), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      expect(find.text('Остаток 12 345 ₽'), findsNothing);
      expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);
    });

    testWidgets('страницы роутера не трогаются: после блокировки та же '
        'страница под PIN, после PIN — она же', (tester) async {
      await _openUnlocked(tester, location: '/finance/transactions');
      expect(find.byKey(const Key('feed-search')), findsOneWidget);
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();

      _container(tester).read(financeLockProvider.notifier).lockNow();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);

      await enterPin(tester, testPin);
      expect(find.byKey(const Key('feed-search')), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
    });

    testWidgets('окно PIN из другого раздела не закрывается чужими '
        'сменами состояния замка', (tester) async {
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      // Замок уже закрыт: повторный lockNow — не переход «открыт -> закрыт».
      _container(tester).read(financeLockProvider.notifier).lockNow();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
    });
  });
}
