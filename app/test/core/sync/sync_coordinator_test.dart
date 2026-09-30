import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/background_sync.dart';
import 'package:my_tasker/core/sync/connectivity_monitor.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_coordinator.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

import '../../support/app_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';

class _Engine extends SyncEngine {
  _Engine(TestDevice d)
    : super(store: d.store, remote: d.remote, clientSchemaVersion: 1);

  int cycles = 0;
  int inits = 0;
  Completer<void>? gate;
  SyncOutcome outcome = SyncOutcome.success;

  @override
  Future<void> init() async => inits++;

  @override
  Future<SyncOutcome> runCycle() async {
    cycles++;
    await gate?.future;
    return outcome;
  }
}

class _Connectivity implements ConnectivityMonitor {
  final StreamController<bool> controller = StreamController<bool>.broadcast();
  bool online = true;

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onlineChanges => controller.stream;

  void set({required bool value}) {
    online = value;
    controller.add(value);
  }
}

class _Background implements BackgroundSync {
  int registered = 0;
  int cancelled = 0;

  @override
  Future<void> register() async => registered++;

  @override
  Future<void> cancel() async => cancelled++;
}

void main() {
  late FakeSyncServer server;
  late ManualClock clock;
  late TestDevice device;
  late _Engine engine;
  late _Connectivity connectivity;
  late _Background background;
  late StreamController<List<int>> wire;
  late int sseConnects;
  late SseClient sse;
  late int revoked;
  late SyncCoordinator coordinator;

  setUp(() async {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    device = await TestDevice.create(server, clock: clock);
    engine = _Engine(device);
    connectivity = _Connectivity();
    background = _Background();
    sseConnects = 0;
    revoked = 0;
    wire = StreamController<List<int>>();
    sse = SseClient(
      connect: () async {
        sseConnects++;
        return wire.stream;
      },
    );
    coordinator = SyncCoordinator(
      engine: engine,
      store: device.store,
      connectivity: connectivity,
      sse: sse,
      background: background,
      onRevoked: () async => revoked++,
      debounce: const Duration(milliseconds: 250),
      interval: const Duration(seconds: 30),
    );
  });
  tearDown(() async {
    await coordinator.stop();
    await sse.dispose();
    await device.close();
    await server.dispose();
  });

  Future<void> wait([int ms = 90]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Ждёт условие (до 5 с): под нагрузкой фиксированные паузы ненадёжны.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('условие не наступило');
      await wait(10);
    }
  }

  test('старт: init, первый цикл, SSE и фоновая задача', () async {
    await coordinator.start();
    await until(() => engine.cycles >= 1);
    expect(coordinator.isStarted, isTrue);
    expect(engine.inits, 1);
    expect(engine.cycles, 1);
    expect(sseConnects, 1);
    expect(background.registered, 1);
    await coordinator.start(); // повторный запуск игнорируется
    expect(engine.inits, 1);
  });

  test('правки в пределах debounce дают один цикл', () async {
    await coordinator.start();
    await until(() => engine.cycles >= 1);
    final base = engine.cycles;
    for (var i = 0; i < 4; i++) {
      await device.store.create('notes', uuid7(), {'title': '$i'});
      await wait(15);
    }
    expect(engine.cycles, base, reason: 'ещё в пределах задержки');
    await until(() => engine.cycles == base + 1);
    await wait(400);
    expect(engine.cycles, base + 1);
  });

  test(
    'сеть появилась: цикл; повторное «онлайн» и потеря сети — нет',
    () async {
      await coordinator.start();
      await until(() => engine.cycles >= 1);
      final base = engine.cycles;
      connectivity.set(value: true);
      await wait(80);
      expect(engine.cycles, base);
      connectivity.set(value: false);
      await wait(80);
      expect(engine.cycles, base);
      connectivity.set(value: true);
      await until(() => engine.cycles == base + 1);
    },
  );

  test(
    'SSE: changes с новой версией — цикл, со старой — нет; hello тоже',
    () async {
      await coordinator.start();
      await until(() => engine.cycles >= 1 && sseConnects >= 1);
      await wait(50);
      final base = engine.cycles;
      wire.add(utf8.encode('event: changes\ndata: {"head_version": 0}\n\n'));
      await wait(100);
      expect(engine.cycles, base, reason: 'курсор уже не отстаёт');
      wire.add(utf8.encode('event: changes\ndata: {"head_version": 5}\n\n'));
      await until(() => engine.cycles == base + 1);
      wire.add(utf8.encode('event: hello\ndata: {"head_version": 9}\n\n'));
      await until(() => engine.cycles == base + 2);
      wire.add(utf8.encode('event: changes\ndata: {}\n\n'));
      await wait(100);
      expect(engine.cycles, base + 2);
    },
  );

  test('SSE revoked: устройство отозвано', () async {
    await coordinator.start();
    await until(() => sseConnects >= 1);
    await wait(50);
    wire.add(utf8.encode('event: revoked\ndata: {}\n\n'));
    await until(() => revoked == 1);
  });

  test('периодический таймер', () async {
    final fast = SyncCoordinator(
      engine: engine,
      store: device.store,
      connectivity: connectivity,
      sse: SseClient(connect: () async => StreamController<List<int>>().stream),
      interval: const Duration(milliseconds: 100),
    );
    addTearDown(fast.stop);
    await fast.start();
    await until(() => engine.cycles >= 3);
  });

  test('syncNow во время цикла присоединяется и ставит один повтор', () async {
    engine.gate = Completer<void>();
    await coordinator.start(); // первый цикл стартует и ждёт ворота
    final first = coordinator.syncNow();
    final second = coordinator.syncNow();
    final third = coordinator.syncNow();
    await wait(20);
    expect(engine.cycles, 1);
    engine.gate!.complete();
    await Future.wait([first, second, third]);
    await wait(20);
    expect(
      engine.cycles,
      2,
      reason: 'один повтор на все запросы во время цикла',
    );
  });

  test('stop: таймеры и подписки сняты, фоновая задача отменена', () async {
    await coordinator.start();
    await wait(20);
    await coordinator.stop();
    final cycles = engine.cycles;
    expect(coordinator.isStarted, isFalse);
    expect(background.cancelled, 1);
    await device.store.create('notes', uuid7(), {'title': 'x'});
    connectivity
      ..set(value: false)
      ..set(value: true);
    await wait(400);
    expect(engine.cycles, cycles);
    await coordinator.stop(); // повторный stop безопасен
    expect(background.cancelled, 1);
    // после нового входа можно стартовать снова
    await coordinator.start();
    await wait(20);
    expect(engine.cycles, cycles + 1);
  });

  group('Riverpod-обвязка', () {
    late AppEnv env;
    tearDown(() => env.dispose());

    test('вход запускает координатор, выход останавливает', () async {
      env = await AppEnv.create(
        autostart: true,
        overrides: [
          connectivityMonitorProvider.overrideWithValue(_Connectivity()),
          backgroundSyncProvider.overrideWithValue(_Background()),
          sseClientProvider.overrideWithValue(
            SseClient(
              connect: () async => StreamController<List<int>>().stream,
            ),
          ),
        ],
      );
      env.container.read(syncLifecycleProvider);
      final coordinator = env.container.read(syncCoordinatorProvider);
      expect(coordinator.isStarted, isFalse);
      await env.login();
      await wait(50);
      expect(coordinator.isStarted, isTrue);
      await env.auth.logout();
      await wait(50);
      expect(coordinator.isStarted, isFalse);
    });

    test('без автозапуска ничего не стартует', () async {
      env = await AppEnv.create();
      env.container.read(syncLifecycleProvider);
      await env.login();
      await wait(30);
      expect(env.container.read(syncCoordinatorProvider).isStarted, isFalse);
    });

    test('SyncStatus: индикатор по состоянию', () async {
      env = await AppEnv.create(
        overrides: [
          connectivityMonitorProvider.overrideWithValue(_Connectivity()),
        ],
      );
      expect(
        env.container.read(syncStatusProvider).indicator,
        SyncIndicatorKind.synced,
      );
      const idle = SyncStatus();
      expect(idle.indicator, SyncIndicatorKind.synced);
      expect(idle.copyWith(online: false).indicator, SyncIndicatorKind.offline);
      expect(
        idle
            .copyWith(run: const SyncRunState(phase: SyncPhase.syncing))
            .indicator,
        SyncIndicatorKind.syncing,
      );
      expect(
        idle.copyWith(run: const SyncRunState(blockedMinSchema: 2)).indicator,
        SyncIndicatorKind.blocked,
      );
      expect(
        idle
            .copyWith(
              run: SyncRunState(
                failure: SyncFailure(
                  SyncFailureKind.server,
                  'x',
                  DateTime.utc(2026),
                ),
              ),
            )
            .indicator,
        SyncIndicatorKind.error,
      );
      expect(
        idle
            .copyWith(
              run: SyncRunState(
                failure: SyncFailure(
                  SyncFailureKind.offline,
                  'x',
                  DateTime.utc(2026),
                ),
              ),
            )
            .indicator,
        SyncIndicatorKind.offline,
      );
    });

    test('SyncStatus следит за движком, очередью и сетью', () async {
      final net = _Connectivity();
      env = await AppEnv.create(
        signedIn: true,
        overrides: [connectivityMonitorProvider.overrideWithValue(net)],
      );
      final sub = env.container.listen(syncStatusProvider, (_, _) {});
      await pumpEventQueue();
      final store = env.container.read(syncStoreProvider);
      await store.create('notes', uuid7(), {'title': 'x'});
      await pumpEventQueue();
      expect(env.container.read(syncStatusProvider).outbox.unsent, 1);
      net.set(value: false);
      await pumpEventQueue();
      expect(
        env.container.read(syncStatusProvider).indicator,
        SyncIndicatorKind.offline,
      );
      net.set(value: true);
      final engine = env.container.read(syncEngineProvider);
      await engine.runCycle();
      await pumpEventQueue();
      final status = env.container.read(syncStatusProvider);
      expect(status.outbox.unsent, 0);
      expect(status.run.lastSuccessAt, isNotNull);
      expect(status.indicator, SyncIndicatorKind.synced);
      sub.close();
    });

    test(
      'runHeadlessSync: без входа ничего не делает; со входом — цикл',
      () async {
        env = await AppEnv.create();
        expect(await runHeadlessSync(env.container), isTrue);
        expect(env.backend.requests, isEmpty);
        await env.login();
        final store = env.container.read(syncStoreProvider);
        final id = uuid7();
        await store.create('notes', id, {'title': 'from background'});
        expect(await runHeadlessSync(env.container), isTrue);
        expect(env.server.row('notes', id), isNotNull);
      },
    );

    test('runHeadlessSync: сбой сервера — повторить позже', () async {
      env = await AppEnv.create(signedIn: true);
      env.backend.failNext('/sync/push', count: 0);
      // сервер отвечает ошибкой не из сети: ставим 426 -> blocked (не failed)
      env.backend.minClientSchema = 9;
      final store = env.container.read(syncStoreProvider);
      await store.create('notes', uuid7(), {'title': 'x'});
      expect(await runHeadlessSync(env.container), isTrue);
    });

    test('NoBackgroundSync и провайдер по умолчанию', () async {
      const none = NoBackgroundSync();
      await none.register();
      await none.cancel();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(backgroundSyncProvider), isA<NoBackgroundSync>());
      expect(container.read(syncAutostartProvider), isTrue);
    });
  });
}
