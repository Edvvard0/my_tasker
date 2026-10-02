import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/background_sync.dart';
import 'package:my_tasker/core/sync/connectivity_monitor.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_coordinator.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

/// Реестр синхронизируемых таблиц. Тесты подставляют свои.
final syncRegistryProvider = Provider<SyncRegistry>(
  (ref) => SyncRegistry(registeredSyncTables),
);

final syncStoreProvider = Provider<SyncStore>((ref) {
  final clock = ref.watch(clockProvider);
  final store = SyncStore(
    db: ref.watch(appDatabaseProvider),
    registry: ref.watch(syncRegistryProvider),
    nowMs: () => clock().millisecondsSinceEpoch,
  );
  ref.onDispose(store.dispose);
  return store;
});

final syncRemoteProvider = Provider<SyncRemote>(
  (ref) => HttpSyncRemote(() => resolveApiClient(ref)),
);

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    store: ref.watch(syncStoreProvider),
    remote: ref.watch(syncRemoteProvider),
    clientSchemaVersion: ref.watch(appConfigProvider).clientSchemaVersion,
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final connectivityMonitorProvider = Provider<ConnectivityMonitor>(
  (ref) => PlatformConnectivityMonitor(),
);

/// Фоновый планировщик ОС; на Android — WorkManager (см. `main.dart`).
final backgroundSyncProvider = Provider<BackgroundSync>(
  (ref) => const NoBackgroundSync(),
);

final sseClientProvider = Provider<SseClient>((ref) {
  final client = SseClient(
    connect: () async {
      final api = await resolveApiClient(ref);
      if (api == null) throw StateError('Сервер не настроен');
      return await api.openStream('/events');
    },
  );
  ref.onDispose(client.dispose);
  return client;
});

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  final coordinator = SyncCoordinator(
    engine: ref.watch(syncEngineProvider),
    store: ref.watch(syncStoreProvider),
    connectivity: ref.watch(connectivityMonitorProvider),
    sse: ref.watch(sseClientProvider),
    background: ref.watch(backgroundSyncProvider),
    onRevoked: () => ref
        .read(authControllerProvider.notifier)
        .onDeviceRevoked('device_revoked'),
  );
  ref.onDispose(() => unawaited(coordinator.stop()));
  return coordinator;
});

/// Запускать ли синхронизацию сама при входе. Виджет-тесты отключают.
final syncAutostartProvider = Provider<bool>((ref) => true);

/// Связывает вход и синхронизацию: вошли — запускаем координатор,
/// вышли — останавливаем. Следит за ним корень приложения.
final syncLifecycleProvider = Provider<void>((ref) {
  if (!ref.watch(syncAutostartProvider)) return;
  final coordinator = ref.watch(syncCoordinatorProvider);
  final observer = _LifecycleObserver(coordinator);
  WidgetsBinding.instance.addObserver(observer);
  ref
    ..onDispose(() => WidgetsBinding.instance.removeObserver(observer))
    ..listen<AuthState>(authControllerProvider, (previous, next) {
      if (next is SignedIn) {
        unawaited(coordinator.start());
      } else if (next is SignedOut) {
        unawaited(coordinator.stop());
      }
    }, fireImmediately: true);
});

/// Передаёт координатору смену состояния приложения (возврат из фона =
/// цикл синхронизации, отметка «на переднем плане» для WorkManager).
class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._coordinator);

  final SyncCoordinator _coordinator;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      unawaited(_coordinator.onLifecycle(state));
}

/// Что показывать в индикаторе (02, 2.9.4 и 4.12).
enum SyncIndicatorKind { synced, syncing, offline, error, blocked }

/// Сводное состояние синхронизации для интерфейса.
@immutable
class SyncStatus {
  const SyncStatus({
    this.run = const SyncRunState(),
    this.outbox = const OutboxSummary(),
    this.online = true,
  });

  final SyncRunState run;
  final OutboxSummary outbox;
  final bool online;

  SyncIndicatorKind get indicator {
    if (run.isBlocked) return SyncIndicatorKind.blocked;
    if (run.isBusy) return SyncIndicatorKind.syncing;
    if (!online || run.failure?.kind == SyncFailureKind.offline) {
      return SyncIndicatorKind.offline;
    }
    if (run.failure != null || outbox.rejected > 0) {
      return SyncIndicatorKind.error;
    }
    return SyncIndicatorKind.synced;
  }

  SyncStatus copyWith({
    SyncRunState? run,
    OutboxSummary? outbox,
    bool? online,
  }) => SyncStatus(
    run: run ?? this.run,
    outbox: outbox ?? this.outbox,
    online: online ?? this.online,
  );
}

class SyncStatusNotifier extends Notifier<SyncStatus> {
  @override
  SyncStatus build() {
    final engine = ref.watch(syncEngineProvider);
    final store = ref.watch(syncStoreProvider);
    final connectivity = ref.watch(connectivityMonitorProvider);
    final subscriptions = <StreamSubscription<Object?>>[
      engine.changes.listen((run) => state = state.copyWith(run: run)),
      store.watchOutboxSummary().listen(
        (outbox) => state = state.copyWith(outbox: outbox),
      ),
      connectivity.onlineChanges.listen(
        (online) => state = state.copyWith(online: online),
      ),
    ];
    ref.onDispose(() {
      for (final s in subscriptions) {
        unawaited(s.cancel());
      }
    });
    unawaited(
      connectivity.isOnline().then((online) {
        if (ref.mounted) state = state.copyWith(online: online);
      }),
    );
    return SyncStatus(run: engine.state);
  }
}

final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(
  SyncStatusNotifier.new,
);
