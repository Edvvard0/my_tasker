import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/theme/app_typography.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import '../support/fake_checker.dart';
import '../support/pump_app.dart';

void main() {
  group('экран «Настройки»', () {
    testWidgets('показывает пункты и версию, «Сервер: Не настроен»', (
      tester,
    ) async {
      await pumpApp(tester, location: '/settings');
      expect(find.byKey(const Key('settings-server')), findsOneWidget);
      expect(find.text('Не настроен'), findsOneWidget);
      expect(find.text('My Tasker 0.1.0'), findsOneWidget);
      expect(find.byKey(const Key('settings-theme')), findsOneWidget);
    });

    testWidgets('после сохранения адрес виден в подписи пункта', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await tester.runAsync(
        () => container
            .read(serverConnectionRepositoryProvider)
            .save(const ServerConnectionSettings(url: 'https://203.0.113.10')),
      );
      container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('https://203.0.113.10'), findsOneWidget);
    });

    testWidgets('пункты ведут на «Сервер» и «Внешний вид»', (tester) async {
      await pumpApp(tester, location: '/settings');
      await tester.tap(find.byKey(const Key('settings-server')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('server-url-field')), findsOneWidget);

      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-theme')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('theme-showcase')), findsOneWidget);

      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-server')), findsOneWidget);
    });

    testWidgets('«Внешний вид» на десктопе тоже открывается', (tester) async {
      await pumpApp(tester, size: desktopSize, location: '/settings/theme');
      expect(find.byKey(const Key('theme-showcase')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ConnectionCheckNotifier', () {
    test('повторный запуск во время проверки игнорируется', () async {
      final gate = Completer<void>();
      final checker = FakeConnectionChecker(
        const ConnectionResult(ConnectionOutcome.ok),
        gate: gate,
      );
      final container = ProviderContainer(
        overrides: [connectionCheckerProvider.overrideWithValue(checker)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionCheckProvider.notifier);

      final first = notifier.check(url: 'https://x', caPem: null);
      expect(
        container.read(connectionCheckProvider),
        isA<ConnectionChecking>(),
      );
      await notifier.check(url: 'https://x', caPem: null);
      expect(checker.calls, hasLength(1));

      gate.complete();
      await first;
      final state = container.read(connectionCheckProvider);
      expect(state, isA<ConnectionDone>());
      expect((state as ConnectionDone).result.isOk, isTrue);

      notifier.reset();
      expect(container.read(connectionCheckProvider), isA<ConnectionIdle>());
    });
  });

  group('тема', () {
    testWidgets('токены доступны через контекст, шрифты — из ассетов', (
      tester,
    ) async {
      await pumpApp(tester);
      final ctx = tester.element(find.byType(Scaffold).first);
      expect(ctx.colors.accent, const Color(0xFF0A84FF));
      expect(ctx.colors.bgBase, const Color(0xFF000000));
      expect(ctx.text.h1.fontFamily, 'Inter');
      expect(ctx.text.numM.fontFamily, 'Inter');
      expect(ctx.text.display.fontFeatures, tabularFigures);
      expect(Theme.of(ctx).brightness, Brightness.dark);
      expect(Theme.of(ctx).scaffoldBackgroundColor, ctx.colors.bgBase);
    });

    testWidgets('на десктопе — десктопная шкала, на телефоне — мобильная', (
      tester,
    ) async {
      await pumpApp(tester);
      var ctx = tester.element(find.byType(Scaffold).first);
      expect(ctx.text.h1.fontSize, 26);
      expect(ctx.text.body.fontSize, 15);

      await pumpApp(tester, size: desktopSize);
      ctx = tester.element(find.byType(Scaffold).first);
      expect(ctx.text.h1.fontSize, 24);
      expect(ctx.text.body.fontSize, 14);
    });
  });
}
