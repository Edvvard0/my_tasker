import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/privacy_env.dart';

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

void main() {
  group('замок не прочитался: раздел закрыт, а не открыт', () {
    testWidgets('хранилище недоступно: «Хранилище недоступно», «Повторить» '
        're-читает; запись не тронута', (tester) async {
      final store = MemoryFinancePrivacyStore(record: lockRecordFor(testPin))
        ..readError = StateError('keystore');
      await pumpFinance(tester, privacyStore: store, seedWith: seedFinanceDemo);
      expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);
      expect(find.byKey(const Key('lock-problem-storage')), findsOneWidget);
      expect(find.text('Хранилище недоступно'), findsOneWidget);
      expect(find.byKey(const Key('pin-dots')), findsNothing);
      expect(find.byKey(const Key('finance-total')), findsNothing);
      expect(find.textContaining('₽'), findsNothing);

      // Повтор при том же сбое — всё то же.
      await tester.tap(find.byKey(const Key('lock-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lock-problem-storage')), findsOneWidget);

      // Хранилище ожило: запись цела, замок включён — экран PIN.
      store.readError = null;
      await tester.tap(find.byKey(const Key('lock-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lock-problem-storage')), findsNothing);
      expect(find.byKey(const Key('pin-dots')), findsOneWidget);
      expect(store.lockClears, 0);
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets(
      'хранилище ожило, замка не было: «Повторить» открывает раздел',
      (tester) async {
        final store = MemoryFinancePrivacyStore()..readError = StateError('x');
        await pumpFinance(
          tester,
          privacyStore: store,
          seedWith: seedFinanceDemo,
        );
        expect(find.byKey(const Key('lock-problem-storage')), findsOneWidget);
        store.readError = null;
        await tester.tap(find.byKey(const Key('lock-retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('finance-total')), findsOneWidget);
      },
    );

    testWidgets('повреждённая запись: понятный текст, «Сбросить замок» с '
        'подтверждением', (tester) async {
      final store = MemoryFinancePrivacyStore(corrupt: true);
      await pumpFinance(tester, privacyStore: store, seedWith: seedFinanceDemo);
      expect(find.byKey(const Key('lock-problem-corrupt')), findsOneWidget);
      expect(find.text('Замок повреждён'), findsOneWidget);
      expect(find.textContaining('Данные не потеряны'), findsOneWidget);
      expect(find.byKey(const Key('finance-total')), findsNothing);
      expect(find.byKey(const Key('lock-retry')), findsNothing);

      // Отказ от сброса: всё закрыто, запись на месте.
      await tester.tap(find.byKey(const Key('lock-reset')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(find.textContaining('сбрасывается только PIN'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(store.corrupt, isTrue);
      expect(find.byKey(const Key('lock-problem-corrupt')), findsOneWidget);

      // Подтверждение: замок сброшен, раздел открыт, данные на месте.
      await tester.tap(find.byKey(const Key('lock-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(store.corrupt, isFalse);
      expect(store.lockClears, 1);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('окно из другого раздела: то же состояние; «Повторить» '
        'закрывает окно, когда раздел открыт', (tester) async {
      final store = MemoryFinancePrivacyStore()..readError = StateError('x');
      await pumpFinance(
        tester,
        location: '/today',
        privacyStore: store,
        seedWith: seedFinanceDemo,
      );
      unawaited(showTransactionEditor(_ctx(tester)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(find.byKey(const Key('lock-problem-storage')), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsNothing);

      store.readError = null;
      await tester.tap(find.byKey(const Key('lock-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect(
        ProviderScope.containerOf(_ctx(tester))
            .read(financeLockProvider)
            .closed,
        isFalse,
      );
    });
  });
}
