import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/app.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import 'in_memory_opener.dart';

/// Телефон (Galaxy A55 ≈ 411 dp; берём типовые 390×844).
const phoneSize = Size(390, 844);

/// Узкое окно десктопа (рейл 72 px).
const mediumSize = Size(800, 600);

/// Обычное окно десктопа (панель 256 px).
const expandedSize = Size(1200, 800);

/// Развёрнутое окно десктопа.
const desktopSize = Size(1440, 900);

/// Запускает приложение на экране заданного размера с БД в памяти.
///
/// [checker] подменяет проверку соединения (сеть в тестах не ходит).
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/today',
  List<Override> overrides = const [],
  ConnectionChecker? checker,
  bool settle = true,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
      routerProvider.overrideWith((ref) {
        final router = createRouter(initialLocation: location);
        ref.onDispose(router.dispose);
        return router;
      }),
      if (checker != null) connectionCheckerProvider.overrideWithValue(checker),
      appConfigProvider.overrideWithValue(
        const AppConfig(allowInsecureLocalhost: false),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const MyTaskerApp()),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}
