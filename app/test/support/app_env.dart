import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';

import 'fake_server/fake_backend.dart';
import 'fake_server/fake_sync_server.dart';
import 'in_memory_opener.dart';
import 'manual_clock.dart';
import 'sync_env.dart';

/// Клиентский стек приложения (Riverpod) поверх [FakeBackend]: настоящие
/// `ApiClient`, `AuthController`, `SyncStore` и `SyncEngine`; сети нет.
class AppEnv {
  AppEnv._(this.container, this.backend, this.server, this.tokens, this.clock);

  static const url = 'http://localhost:8000';

  /// [signedIn]: сразу войти (сессия в хранилище токенов).
  static Future<AppEnv> create({
    bool serverConfigured = true,
    bool signedIn = false,
    bool autostart = false,
    MemoryTokenStore? tokens,
    ManualClock? clock,
    FakeSyncServer? server,
    FakeBackend? backend,
    List<Override> overrides = const [],
  }) async {
    final manual = clock ?? ManualClock();
    final fakeServer =
        server ?? FakeSyncServer(registry: testRegistry(), nowMs: manual.call);
    final fakeBackend =
        backend ?? FakeBackend(server: fakeServer, now: () => manual.now);
    final store = tokens ?? MemoryTokenStore();
    final container = ProviderContainer(
      overrides: [
        databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
        appConfigProvider.overrideWithValue(
          const AppConfig(allowInsecureLocalhost: true),
        ),
        clockProvider.overrideWithValue(() => manual.now),
        tokenStoreProvider.overrideWithValue(store),
        plainAdapterFactoryProvider.overrideWithValue(() => fakeBackend),
        syncRegistryProvider.overrideWithValue(testRegistry()),
        syncAutostartProvider.overrideWithValue(autostart),
        ...overrides,
      ],
    );
    final env = AppEnv._(container, fakeBackend, fakeServer, store, manual);
    // Таблицы тестового реестра создаём до первой записи.
    await createTestTables(
      container.read(appDatabaseProvider),
      container.read(syncRegistryProvider),
    );
    if (serverConfigured) {
      await container
          .read(serverConnectionRepositoryProvider)
          .save(const ServerConnectionSettings(url: url));
      // Настройки в БД, но провайдер НЕ прогрет: как при холодном старте
      // (и в изоляте WorkManager). Раньше здесь ждали
      // `serverConnectionSettingsProvider.future`, и тесты не видели, что
      // клиент API на первом чтении равен `null`. Нужен клиент — `apiClient()`.
    }
    if (signedIn) await env.login();
    await container.read(authControllerProvider.notifier).ready;
    return env;
  }

  final ProviderContainer container;
  final FakeBackend backend;
  final FakeSyncServer server;
  final MemoryTokenStore tokens;
  final ManualClock clock;

  /// Клиент API так, как его получает код приложения (после загрузки
  /// настроек сервера).
  Future<ApiClient> apiClient() async {
    final client = await container.read(apiClientResolverProvider)();
    return client!;
  }

  AuthController get auth => container.read(authControllerProvider.notifier);
  AuthState get authState => container.read(authControllerProvider);

  Future<void> login({String name = 'Test phone'}) => auth.login(
    password: backend.password,
    totpCode: backend.totpCode,
    device: DeviceInfo(name: name, platform: DevicePlatform.android),
  );

  Future<void> dispose() async {
    container.dispose();
    await server.dispose();
  }
}
