import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

import '../support/finance_ui_env.dart';
import '../support/pump_app.dart';

/// Golden-тесты Этапа 5 (Финансы) на телефоне и десктопе: «Финансы со
/// счетами» и «Редактор операции». Эталоны — `files/*.png`; обновление:
/// `flutter test --update-goldens test/goldens/stage5_goldens_test.dart`
/// (снимать на Linux, см. README).
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

BuildContext _context(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

Future<void> _openEditor(WidgetTester tester) async {
  unawaited(showTransactionEditor(_context(tester)));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('tx-merchant')), 'Пятёрочка');
  await tester.enterText(find.byKey(const Key('tx-amount')), '1249,9');
  await tester.pumpAndSettle();
  // Форма прокручена к полю в фокусе: для снимка показываем её сверху.
  await tester.drag(
    find.byType(SingleChildScrollView).last,
    const Offset(0, 600),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Финансы со счетами', () {
    testWidgets('телефон', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      await _shot(tester, 'finance_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpFinance(tester, size: desktopSize, seedWith: seedFinanceDemo);
      await _shot(tester, 'finance_desktop');
    });
  });

  group('Редактор операции', () {
    testWidgets('телефон', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      await _openEditor(tester);
      await _shot(tester, 'tx_editor_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpFinance(tester, size: desktopSize, seedWith: seedFinanceDemo);
      await _openEditor(tester);
      await _shot(tester, 'tx_editor_desktop');
    });

    testWidgets('перевод (телефон)', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      unawaited(
        showTransactionEditor(_context(tester), kind: TransactionKind.transfer),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '5000');
      await tester.pumpAndSettle();
      await _shot(tester, 'tx_editor_transfer_phone');
    });
  });
}
