import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/finance_ui_env.dart';
import '../support/pump_app.dart';

/// Golden-тесты Этапа 5, срез 5b (Долги): экран «Долги» на телефоне и
/// десктопе и карточка долга. Эталоны — `files/*.png`; обновление только
/// этого файла: `flutter test --update-goldens
/// test/goldens/stage5_debts_goldens_test.dart` (снимать на Linux, см. README).
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

Future<void> _open(WidgetTester tester, {Size size = phoneSize}) async {
  await pumpFinance(tester, size: size, seedWith: seedDebtsDemo);
  await goTo(tester, '/finance/debts');
  await settleDb(tester);
}

void main() {
  group('Долги', () {
    testWidgets('телефон', (tester) async {
      await _open(tester);
      await _shot(tester, 'debts_phone');
    });

    testWidgets('десктоп', (tester) async {
      await _open(tester, size: desktopSize);
      await _shot(tester, 'debts_desktop');
    });
  });

  testWidgets('Карточка долга (телефон)', (tester) async {
    late DebtsDemo demo;
    await pumpFinance(
      tester,
      seedWith: (c) async => demo = await seedDebtsDemo(c),
    );
    await goTo(tester, '/finance/debts/${demo.nastya}');
    await settleDb(tester);
    await _shot(tester, 'debt_card_phone');
  });
}
