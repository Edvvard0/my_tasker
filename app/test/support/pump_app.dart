import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/app.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_opener.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import 'ai_env.dart';
import 'fake_server/fake_backend.dart';
import 'fakes.dart';
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
/// [signedIn] — сразу войти (токены в памяти); [gated] — настоящий роутер с
/// правилом входа (`authRedirect`), а не «голый» без redirect.
/// [backend] — вместо сети фейковый сервер (тогда `http://localhost`
/// разрешён); [serverUrl] — сохранить адрес сервера в БД до старта;
/// [now] — зафиксировать «текущее время» (стабильные подписи «5 мин назад»);
/// [clock] — своё «текущее время», которое можно двигать во время теста;
/// [opener] — свой способ открыть БД (например, «сломанную»);
/// [defaultAiApi] — поддельный API ИИ по умолчанию (экраны ИИ не ходят в сеть);
/// [secretStore] — защищённое хранилище PIN «Финансов» (по умолчанию память);
/// [pulsePoll] — как часто «Пульс» сам обновляется (по умолчанию не обновляется).
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/today',
  List<Override> overrides = const [],
  ConnectionChecker? checker,
  bool settle = true,
  bool signedIn = true,
  bool gated = false,
  FakeBackend? backend,
  String? serverUrl,
  DateTime? now,
  DateTime Function()? clock,
  AppDatabaseOpener? opener,
  bool defaultAiApi = true,
  SecretStore? secretStore,
  Duration? pulsePoll,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      databaseOpenerProvider.overrideWithValue(
        opener ?? InMemoryDatabaseOpener(),
      ),
      tokenStoreProvider.overrideWithValue(
        MemoryTokenStore(signedIn ? fakeSession() : null),
      ),
      connectivityMonitorProvider.overrideWithValue(FakeConnectivity()),
      syncAutostartProvider.overrideWithValue(false),
      if (!gated)
        routerProvider.overrideWith((ref) {
          final router = createRouter(initialLocation: location);
          ref.onDispose(router.dispose);
          return router;
        }),
      if (checker != null) connectionCheckerProvider.overrideWithValue(checker),
      appConfigProvider.overrideWithValue(
        AppConfig(allowInsecureLocalhost: backend != null),
      ),
      if (backend != null)
        plainAdapterFactoryProvider.overrideWithValue(() => backend),
      if (clock != null)
        clockProvider.overrideWithValue(clock)
      else if (now != null)
        clockProvider.overrideWithValue(() => now),
      // Экраны ИИ не ходят в настоящую сеть: поддельный API по умолчанию.
      if (defaultAiApi) aiApiProvider.overrideWithValue(FakeAiApi()),
      // «Пульс» не обновляет себя по таймеру: висящий таймер роняет тест.
      pulsePollIntervalProvider.overrideWithValue(pulsePoll),
      // Замок «Финансов»: PIN лежит в памяти, а не в защищённом хранилище ОС.
      secretStoreProvider.overrideWithValue(secretStore ?? MemorySecretStore()),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);

  if (serverUrl != null) {
    await tester.runAsync(
      () => container
          .read(serverConnectionRepositoryProvider)
          .save(ServerConnectionSettings(url: serverUrl)),
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const MyTaskerApp()),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}
