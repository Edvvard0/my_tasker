import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/network/trust_on_first_use.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/settings/presentation/theme_showcase_screen.dart';

import '../support/fake_checker.dart';
import '../support/pem.dart';
import '../support/pump_app.dart';
import '../support/stage2_env.dart';

/// Golden-тесты: тема и оболочка на двух размерах (телефон и десктоп) с
/// настоящими шрифтами (см. `test/flutter_test_config.dart`).
///
/// Обновление эталонов: `flutter test --update-goldens test/goldens`
/// (только на Linux — эталоны CI сняты на нём).
void main() {
  Future<void> pumpShowcase(WidgetTester tester, Size size) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final windowClass = WindowClass.fromWidth(size.width);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(windowClass),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(windowClass.gutter),
            child: const ThemeShowcase(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('тема (витрина токенов)', () {
    testWidgets('телефон 390 dp', (tester) async {
      await pumpShowcase(tester, const Size(390, 1900));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/theme_showcase_phone.png'),
      );
    });

    testWidgets('десктоп 1440 px', (tester) async {
      await pumpShowcase(tester, const Size(1440, 1200));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/theme_showcase_desktop.png'),
      );
    });
  });

  group('оболочка приложения', () {
    testWidgets('телефон 390×844: «Сегодня» с таб-баром', (tester) async {
      await pumpStage2(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/shell_phone.png'),
      );
    });

    testWidgets('десктоп 1440×900: «Сегодня» с левой панелью', (tester) async {
      await pumpStage2(tester, size: desktopSize);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/shell_desktop.png'),
      );
    });

    testWidgets('окно 800×600: рейл 72 px', (tester) async {
      await pumpStage2(tester, size: mediumSize, location: '/calendar');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/shell_rail.png'),
      );
    });
  });

  group('настройки сервера', () {
    Future<void> setUpScreen(
      WidgetTester tester,
      Size size,
      ConnectionOutcome outcome,
    ) async {
      final pem = fakePem();
      await pumpApp(
        tester,
        size: size,
        location: '/settings/server',
        checker: FakeConnectionChecker(ConnectionResult(outcome)),
        overrides: [
          rootCaFetcherProvider.overrideWithValue(
            (_) async =>
                FetchedRootCa(pem: pem, fingerprint: fakeFingerprint()),
          ),
        ],
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://203.0.113.10',
      );
      await tester.tap(find.byKey(const Key('fetch-ca-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('телефон: сверка отпечатка', (tester) async {
      await setUpScreen(tester, phoneSize, ConnectionOutcome.ok);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/server_connection_confirm_phone.png'),
      );
    });

    testWidgets('телефон: сертификат не совпал', (tester) async {
      await setUpScreen(tester, phoneSize, ConnectionOutcome.certMismatch);
      await tester.tap(find.byKey(const Key('confirm-ca-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('check-button')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/server_connection_phone.png'),
      );
    });

    testWidgets('десктоп: сверка отпечатка', (tester) async {
      await setUpScreen(tester, desktopSize, ConnectionOutcome.ok);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('files/server_connection_desktop.png'),
      );
    });
  });
}
