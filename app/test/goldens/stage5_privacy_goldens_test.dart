import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/finance_ui_env.dart';
import '../support/privacy_env.dart';
import '../support/pump_app.dart';

/// Golden-тесты замка «Финансов» (Этап 5d): экран ввода PIN на телефоне и
/// десктопе и состояние «неверный PIN». Эталоны — `files/*.png`; обновление:
/// `flutter test --update-goldens test/goldens/stage5_privacy_goldens_test.dart`
/// (снимать на Linux, см. README).
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Экран PIN', () {
    testWidgets('телефон', (tester) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await _shot(tester, 'finance_pin_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpFinance(
        tester,
        size: desktopSize,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await _shot(tester, 'finance_pin_desktop');
    });

    testWidgets('неверный PIN (телефон)', (tester) async {
      await pumpFinance(
        tester,
        privacyStore: lockedStore(),
        seedWith: seedFinanceDemo,
      );
      await enterPin(tester, testPinOther);
      await _shot(tester, 'finance_pin_error_phone');
    });
  });
}
