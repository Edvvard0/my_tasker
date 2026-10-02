import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_coordinator.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

import 'fake_server/fake_backend.dart';

/// Состояние синхронизации, зафиксированное тестом (без живых потоков).
class FixedStatus extends SyncStatusNotifier {
  FixedStatus(this.fixed);

  final SyncStatus fixed;

  @override
  SyncStatus build() => fixed;
}

/// Статусы для тестов интерфейса.
SyncStatus statusOf(
  SyncIndicatorKind kind, {
  int unsent = 0,
  int rejected = 0,
  DateTime? lastSuccess,
  DateTime? lastPush,
  DateTime? lastPull,
  int pulledRows = 0,
  bool clockSkew = false,
}) {
  final failure = switch (kind) {
    SyncIndicatorKind.error => SyncFailure(
      SyncFailureKind.server,
      'http 503 unavailable',
      DateTime.utc(2026, 10, 1, 12),
    ),
    SyncIndicatorKind.offline => SyncFailure(
      SyncFailureKind.offline,
      'network connectionError',
      DateTime.utc(2026, 10, 1, 12),
    ),
    _ => null,
  };
  return SyncStatus(
    run: SyncRunState(
      phase: kind == SyncIndicatorKind.syncing
          ? SyncPhase.syncing
          : SyncPhase.idle,
      failure: failure,
      blockedMinSchema: kind == SyncIndicatorKind.blocked ? 2 : null,
      clockSkew: clockSkew,
      pulledRows: pulledRows,
      lastPushAt: lastPush,
      lastPullAt: lastPull,
      lastSuccessAt: lastSuccess,
    ),
    outbox: OutboxSummary(pending: unsent, rejected: rejected),
    online: kind != SyncIndicatorKind.offline,
  );
}

/// Координатор, который лишь считает вызовы.
class CountingCoordinator extends SyncCoordinator {
  CountingCoordinator(Ref ref)
    : super(
        engine: ref.read(syncEngineProvider),
        store: ref.read(syncStoreProvider),
        connectivity: ref.read(connectivityMonitorProvider),
        sse: ref.read(sseClientProvider),
      );

  int syncNowCalls = 0;

  @override
  Future<SyncOutcome> syncNow() async {
    syncNowCalls++;
    return SyncOutcome.success;
  }
}

/// Входит на втором «устройстве» того же фейкового сервера.
Future<AuthSession> loginOtherDevice(
  FakeBackend backend, {
  String name = 'Рабочий ПК',
  DevicePlatform platform = DevicePlatform.windows,
}) async {
  final client = ApiClient(
    dio: ApiClient.createDio(
      baseUrl: Uri.parse('http://localhost:8000'),
      adapter: backend,
    ),
    schemaVersion: 1,
  );
  final json = await client.postJson(
    '/auth/login',
    auth: false,
    body: {
      'password': backend.password,
      'totp_code': backend.totpCode,
      'device': DeviceInfo(name: name, platform: platform).toJson(),
    },
  );
  return AuthSession.fromJson(json);
}

/// Даёт реальному циклу событий выполнить накопившиеся асинхронные операции
/// (запросы к БД, потоки Drift) — без пауз по времени: только повороты
/// очереди событий.
Future<void> flushEvents(WidgetTester tester) =>
    tester.runAsync(pumpEventQueue).then((_) {});
