import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/privacy_env.dart';

final RegExp _amount = RegExp(r'\d[\d\s  ]*(?:,\d{1,2})?\s*₽');

const _placeholder = 'Финансовая запись';

/// Корзина с удалённой «Пятёрочкой» (и счётом «Наличные»).
Future<({ProviderContainer container, FinanceDemo demo})> _pumpTrash(
  WidgetTester tester, {
  MemoryFinancePrivacyStore? store,
}) async {
  late FinanceDemo demo;
  final c = await pumpFinance(
    tester,
    privacyStore: store,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      await financeRepo(c).deleteTransaction(demo.shop);
    },
  );
  await goTo(tester, '/settings/trash');
  await settleDb(tester);
  return (container: c, demo: demo);
}

Iterable<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    if (t.data != null) t.data!,
];

void main() {
  group('корзина и замок «Финансов»', () {
    testWidgets('«скрыть суммы» включено: нейтральный заголовок', (
      tester,
    ) async {
      final r = await _pumpTrash(
        tester,
        store: MemoryFinancePrivacyStore(hidden: true),
      );
      expect(find.byKey(Key('trash-transactions-${r.demo.shop}')), findsOne);
      expect(find.text(_placeholder), findsOneWidget);
      expect(find.textContaining('Пятёрочка'), findsNothing);
      expect(_texts(tester).where(_amount.hasMatch), isEmpty);
    });

    testWidgets('замок закрыт: нейтральный заголовок, без сумм и имён', (
      tester,
    ) async {
      final r = await _pumpTrash(tester, store: lockedStore());
      expect(find.byKey(Key('trash-transactions-${r.demo.shop}')), findsOne);
      expect(find.text(_placeholder), findsOneWidget);
      expect(find.textContaining('Пятёрочка'), findsNothing);
      expect(_texts(tester).where(_amount.hasMatch), isEmpty);
    });

    testWidgets('суммы не скрыты: заголовок настоящий, но без суммы', (
      tester,
    ) async {
      await _pumpTrash(tester);
      expect(find.text('Расход · Пятёрочка'), findsOneWidget);
      expect(find.text(_placeholder), findsNothing);
      expect(_texts(tester).where(_amount.hasMatch), isEmpty);
    });

    testWidgets('«скрыть суммы»: снекбар восстановления тоже нейтральный', (
      tester,
    ) async {
      final r = await _pumpTrash(
        tester,
        store: MemoryFinancePrivacyStore(hidden: true),
      );
      await tester.tap(find.byKey(Key('restore-${r.demo.shop}')));
      await settleDb(tester);
      expect(find.text('«$_placeholder» восстановлено'), findsOneWidget);
      expect(find.textContaining('Пятёрочка'), findsNothing);
    });

    testWidgets('суммы не скрыты: снекбар называет запись без суммы', (
      tester,
    ) async {
      final r = await _pumpTrash(tester);
      await tester.tap(find.byKey(Key('restore-${r.demo.shop}')));
      await settleDb(tester);
      expect(find.text('«Расход · Пятёрочка» восстановлено'), findsOneWidget);
    });

    testWidgets('замок закрыт: восстановление требует PIN; отмена — '
        'запись остаётся в корзине', (tester) async {
      final r = await _pumpTrash(tester, store: lockedStore());
      await tester.tap(find.byKey(Key('restore-${r.demo.shop}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('finance-unlock-cancel')));
      await settleDb(tester);
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(find.byKey(Key('trash-transactions-${r.demo.shop}')), findsOne);
      expect(find.textContaining('восстановлено'), findsNothing);
      final txs = (await tester.runAsync(
        financeRepo(r.container).transactions,
      ))!;
      expect(txs.map((t) => t.id), isNot(contains(r.demo.shop)));
    });

    testWidgets('замок закрыт: верный PIN — запись восстановлена', (
      tester,
    ) async {
      final r = await _pumpTrash(tester, store: lockedStore());
      await tester.tap(find.byKey(Key('restore-${r.demo.shop}')));
      await tester.pumpAndSettle();
      await enterPin(tester, testPin);
      await settleDb(tester);
      expect(r.container.read(financeLockProvider).closed, isFalse);
      expect(
        find.byKey(Key('trash-transactions-${r.demo.shop}')),
        findsNothing,
      );
      final txs = (await tester.runAsync(
        financeRepo(r.container).transactions,
      ))!;
      expect(txs.map((t) => t.id), contains(r.demo.shop));
      expect(find.textContaining('восстановлено'), findsOneWidget);
    });
  });
}
