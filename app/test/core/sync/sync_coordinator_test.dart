import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/core/sync/background_sync.dart';
import 'package:my_tasker/core/sync/connectivity_monitor.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sse_client.dart';
import 'package:my_tasker/core/sync/sync_coordinator.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';

import '../../support/app_env.dart';
import '../../support/fake_server/fake_backend.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/fakes.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';
import '../../support/ui_helpers.dart';

/// Хранилище без БД: координатору нужны лишь поток локальных записей,
/// курсор и отметка «на переднем плане». Так тесты идут на виртуальном
/// времени (драйвер БД в `fakeAsync` не работает).
class _Store implements SyncStore {
  final StreamController<void> writes = StreamController<void>.broadcast();
  int cursorValue = 0;
  bool foreground = false;
  int beats = 0;

  @override
  Stream<void> get localWrites => writes.stream;

  @override
  Future<int> cursor() async => cursorValue;

  @override
  Future<void> markForeground() async {
    foreground = true;
    beats++;
  }

  @override
  Future<void> clearForeground() async => foreground = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoRemote implements SyncRemote {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine extends SyncEngine {
  _Engine(SyncStore store)
    : super(store: store, remote: _NoRemote(), clientSchemaVersion: 1);

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

class _Sse extends SseClient {
  _Sse(Future<Stream<List<int>>> Function() connect)
    : super(connect: connect, jitter: 0);

  int nudges = 0;

  @override
  void nudge() {
    nudges++;
    super.nudge();
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

/// Прогоняет микрозадачи и нулевые таймеры (отмена подписок и т. п.
/// завершается через них) до тишины.
void settle(FakeAsync async) {
  for (var i = 0; i < 10; i++) {
    async
      ..flushMicrotasks()
      ..elapse(Duration.zero);
  }
}

void main() {
  late _Store store;
  late _Engine engine;
  late _Connectivity connectivity;
  late _Background background;
  late StreamController<List<int>> wire;
  late int sseConnects;
  late _Sse sse;
  late int revoked;
  late SyncCoordinator coordinator;

  /// Фикстуры создаются внутри виртуальной зоны: у потоков, созданных вне
  /// её, продолжения `await` (например, отмена подписки) идут по реальному
  /// циклу событий и не подчиняются виртуальному времени.
  void initFixtures() {
    store = _Store();
    engine = _Engine(store);
    connectivity = _Connectivity();
    background = _Background();
    sseConnects = 0;
    revoked = 0;
    wire = StreamController<List<int>>();
    sse = _Sse(() async {
      sseConnects++;
      return wire.stream;
    });
    coordinator = SyncCoordinator(
      engine: engine,
      store: store,
      connectivity: connectivity,
      sse: sse,
      background: background,
      onRevoked: () async => revoked++,
      debounce: const Duration(milliseconds: 250),
      interval: const Duration(seconds: 30),
    );
  }

  /// Тест на виртуальном времени: без реальных пауз. [elapse] двигает и
  /// таймеры координатора, и часы устройства (метка «на переднем плане»
  /// сравнивается с ними).
  void fake(
    String name,
    void Function(FakeAsync async, void Function(Duration) elapse) body,
  ) {
    test(name, () {
      fakeAsync((async) {
        initFixtures();
        void elapse(Duration d) => async.elapse(d);

        body(async, elapse);
        // Всё, что стартовало в виртуальной зоне, останавливаем в ней же:
        // иначе продолжения Future останутся в очереди, которую никто не
        // прокрутит, и tearDown повиснет.
        if (!(engine.gate?.isCompleted ?? true)) engine.gate!.complete();
        unawaited(coordinator.stop());
        unawaited(sse.dispose());
        settle(async);
      });
    });
  }

  void start(FakeAsync async) {
    unawaited(coordinator.start());
    settle(async);
  }

  fake('старт: init, первый цикл, SSE и фоновая задача', (async, elapse) {
    start(async);
    expect(coordinator.isStarted, isTrue);
    expect(engine.inits, 1);
    expect(engine.cycles, 1);
    expect(sseConnects, 1);
    expect(background.registered, 1);
    unawaited(coordinator.start()); // повторный запуск игнорируется
    settle(async);
    expect(engine.inits, 1);
  });

  fake('правки в пределах debounce дают один цикл', (async, elapse) {
    start(async);
    final base = engine.cycles;
    for (var i = 0; i < 4; i++) {
      store.writes.add(null);
      elapse(const Duration(milliseconds: 15));
    }
    expect(engine.cycles, base, reason: 'ещё в пределах задержки');
    elapse(const Duration(milliseconds: 250));
    expect(engine.cycles, base + 1);
    elapse(const Duration(seconds: 1));
    expect(engine.cycles, base + 1);
  });

  fake('L5: непрерывные правки не откладывают цикл дольше 10 с', (
    async,
    elapse,
  ) {
    final slow = SyncCoordinator(
      engine: engine,
      store: store,
      connectivity: connectivity,
      sse: sse,
      interval: const Duration(hours: 1),
    );
    unawaited(slow.start());
    settle(async);
    final base = engine.cycles;
    // правка каждые 2 с: debounce 3 с никогда не истекает сам
    for (var i = 0; i < 6; i++) {
      store.writes.add(null);
      elapse(const Duration(seconds: 2));
    }
    expect(engine.cycles, base + 1, reason: 'сработал предел ожидания 10 с');
    for (var i = 0; i < 6; i++) {
      store.writes.add(null);
      elapse(const Duration(seconds: 2));
    }
    expect(engine.cycles, base + 2);
    elapse(const Duration(seconds: 3)); // правки закончились: обычный debounce
    expect(engine.cycles, base + 3);
    unawaited(slow.stop());
    settle(async);
  });

  fake('сеть появилась: цикл и «пинок» SSE; повторное «онлайн» и потеря '
      'сети — нет', (async, elapse) {
    start(async);
    final base = engine.cycles;
    connectivity.set(value: true);
    settle(async);
    expect(engine.cycles, base);
    connectivity.set(value: false);
    settle(async);
    expect(engine.cycles, base);
    expect(sse.nudges, 0);
    connectivity.set(value: true);
    settle(async);
    expect(engine.cycles, base + 1);
    expect(sse.nudges, 1, reason: 'backoff SSE сброшен');
  });

  fake('SSE: changes с новой версией — цикл, со старой — нет; hello тоже', (
    async,
    elapse,
  ) {
    start(async);
    final base = engine.cycles;
    void send(String text) {
      wire.add(utf8.encode(text));
      settle(async);
    }

    send('event: changes\ndata: {"head_version": 0}\n\n');
    expect(engine.cycles, base, reason: 'курсор уже не отстаёт');
    send('event: changes\ndata: {"head_version": 5}\n\n');
    expect(engine.cycles, base + 1);
    send('event: hello\ndata: {"head_version": 9}\n\n');
    expect(engine.cycles, base + 2);
    send('event: changes\ndata: {}\n\n');
    expect(engine.cycles, base + 2);
  });

  fake('SSE revoked: устройство отозвано', (async, elapse) {
    start(async);
    wire.add(utf8.encode('event: revoked\ndata: {}\n\n'));
    settle(async);
    expect(revoked, 1);
  });

  fake('периодический таймер', (async, elapse) {
    start(async);
    elapse(const Duration(seconds: 95));
    expect(engine.cycles, 1 + 3); // 30, 60, 90 с
  });

  fake('syncNow во время цикла присоединяется и ставит один повтор', (
    async,
    elapse,
  ) {
    engine.gate = Completer<void>();
    start(async); // первый цикл стартует и ждёт ворота
    final first = coordinator.syncNow();
    final second = coordinator.syncNow();
    final third = coordinator.syncNow();
    settle(async);
    expect(engine.cycles, 1);
    engine.gate!.complete();
    unawaited(Future.wait([first, second, third]));
    settle(async);
    expect(
      engine.cycles,
      2,
      reason: 'один повтор на все запросы во время цикла',
    );
  });

  fake('L6: возврат в приложение — цикл; уход в фон — без цикла', (
    async,
    elapse,
  ) {
    start(async);
    final base = engine.cycles;
    unawaited(coordinator.onLifecycle(AppLifecycleState.paused));
    settle(async);
    unawaited(coordinator.onLifecycle(AppLifecycleState.paused)); // повтор
    settle(async);
    expect(engine.cycles, base);
    unawaited(coordinator.onLifecycle(AppLifecycleState.resumed));
    settle(async);
    expect(engine.cycles, base + 1);
    expect(sse.nudges, 1);
    unawaited(coordinator.onLifecycle(AppLifecycleState.resumed)); // повтор
    settle(async);
    expect(engine.cycles, base + 1);
  });

  fake('L6: onLifecycle до старта ничего не делает', (async, elapse) {
    unawaited(coordinator.onLifecycle(AppLifecycleState.paused));
    unawaited(coordinator.onLifecycle(AppLifecycleState.resumed));
    settle(async);
    expect(engine.cycles, 0);
  });

  fake('SSE: hello с версией больше курсора запускает цикл', (async, elapse) {
    store.cursorValue = 3;
    start(async);
    final base = engine.cycles;
    wire.add(utf8.encode('event: hello\ndata: {"head_version": 3}\n\n'));
    settle(async);
    expect(engine.cycles, base);
  });

  fake('stop сразу снимает таймеры: ни debounce, ни периодического цикла', (
    async,
    elapse,
  ) {
    start(async);
    final cycles = engine.cycles;
    store.writes.add(null);
    unawaited(coordinator.stop());
    elapse(const Duration(minutes: 5));
    expect(engine.cycles, cycles);
  });

  fake('M3: пульс «на переднем плане» пишется при старте и каждые 30 с, '
      'снимается в фоне', (async, elapse) {
    expect(store.foreground, isFalse);
    start(async);
    expect(store.foreground, isTrue);
    expect(store.beats, 1);
    elapse(const Duration(minutes: 5)); // пульс поддерживается таймером
    expect(store.beats, 1 + 10);
    unawaited(coordinator.onLifecycle(AppLifecycleState.paused));
    settle(async);
    expect(store.foreground, isFalse);
    final beats = store.beats;
    elapse(const Duration(minutes: 5));
    expect(store.beats, beats, reason: 'в фоне пульс не пишется');
    unawaited(coordinator.onLifecycle(AppLifecycleState.resumed));
    settle(async);
    expect(store.foreground, isTrue);
  });

  // Ниже — тесты без таймеров, но с `await` по «чужим» Future (отмена
  // подписки): им нужен настоящий цикл событий (`pumpEventQueue`, без сна).
  void real(String name, Future<void> Function() body) {
    test(name, () async {
      initFixtures();
      try {
        await body();
      } finally {
        if (!(engine.gate?.isCompleted ?? true)) engine.gate!.complete();
        await coordinator.stop();
        await sse.dispose();
      }
    });
  }

  real('stop: подписки сняты, фоновая задача отменена, пульс снят', () async {
    await coordinator.start();
    await pumpEventQueue();
    expect(store.foreground, isTrue);
    await coordinator.stop();
    final cycles = engine.cycles;
    expect(coordinator.isStarted, isFalse);
    expect(background.cancelled, 1);
    expect(store.foreground, isFalse);
    store.writes.add(null);
    connectivity
      ..set(value: false)
      ..set(value: true);
    await pumpEventQueue();
    expect(engine.cycles, cycles);
    expect(sse.nudges, 0);
    await coordinator.stop(); // повторный stop безопасен
    expect(background.cancelled, 1);
    // после нового входа можно стартовать снова
    await coordinator.start();
    await pumpEventQueue();
    expect(engine.cycles, cycles + 1);
  });

  real('L6: stop дожидается идущего цикла', () async {
    engine.gate = Completer<void>();
    await coordinator.start(); // цикл идёт и ждёт ворота
    await pumpEventQueue();
    var stopped = false;
    unawaited(coordinator.stop().then((_) => stopped = true));
    await pumpEventQueue();
    expect(stopped, isFalse, reason: 'цикл ещё идёт');
    engine.gate!.complete();
    await pumpEventQueue();
    expect(stopped, isTrue);
    expect(engine.cycles, 1, reason: 'повтора после stop нет');
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
      await pumpEventQueue();
      expect(coordinator.isStarted, isTrue);
      await env.auth.logout();
      await pumpEventQueue();
      expect(coordinator.isStarted, isFalse);
    });

    test('без автозапуска ничего не стартует', () async {
      env = await AppEnv.create();
      env.container.read(syncLifecycleProvider);
      await env.login();
      await pumpEventQueue();
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

    /// Холодный старт (в том числе изолят WorkManager): свежий контейнер,
    /// настройки сервера лежат в БД, но провайдер настроек не прогрет.
    Future<(AppEnv, String)> coldStart() async {
      final clock = ManualClock();
      final server = FakeSyncServer(
        registry: testRegistry(),
        nowMs: clock.call,
      );
      final backend = FakeBackend(server: server, now: () => clock.now);
      final session = await loginOtherDevice(backend);
      final cold = await AppEnv.create(
        clock: clock,
        server: server,
        backend: backend,
        tokens: MemoryTokenStore(session),
      );
      final store = cold.container.read(syncStoreProvider);
      await store.adoptDevice(session.deviceId);
      final id = uuid7();
      await store.create('notes', id, {'title': 'created offline'});
      return (cold, id);
    }

    test('H1: холодный старт без прогретых настроек — headless-цикл '
        'доходит до сервера', () async {
      final (cold, id) = await coldStart();
      env = cold;
      expect(await runHeadlessSync(env.container), isTrue);
      expect(env.backend.requests, contains('POST /sync/push'));
      expect(env.server.row('notes', id), isNotNull);
      expect(await env.container.read(syncStoreProvider).outbox(), isEmpty);
    });

    test('H1: холодный старт — цикл движка без прогрева настроек', () async {
      final (cold, id) = await coldStart();
      env = cold;
      final outcome = await env.container.read(syncEngineProvider).runCycle();
      expect(outcome, SyncOutcome.success);
      expect(env.server.row('notes', id), isNotNull);
    });

    test('H1: холодный старт — SSE подключается', () async {
      final (cold, _) = await coldStart();
      env = cold;
      final sse = env.container.read(sseClientProvider)..start();
      addTearDown(sse.stop);
      for (var i = 0; i < 20 && env.backend.sseConnections == 0; i++) {
        await pumpEventQueue();
      }
      expect(env.backend.sseConnections, 1);
    });

    test(
      'H1: холодный старт — refresh токена тоже дожидается настроек',
      () async {
        final (cold, id) = await coldStart();
        env = cold;
        env.backend.expireAccessTokens();
        expect(await runHeadlessSync(env.container), isTrue);
        expect(env.backend.refreshCalls, 1);
        expect(env.server.row('notes', id), isNotNull);
      },
    );

    test(
      'H1: сервер не настроен — notConfigured не считается успехом',
      () async {
        env = await AppEnv.create(
          serverConfigured: false,
          tokens: MemoryTokenStore(fakeSession()),
        );
        expect(env.authState, isA<SignedIn>());
        expect(await runHeadlessSync(env.container), isFalse);
      },
    );

    test('H1: не читаются настройки сервера — клиента нет, headless просит '
        'повторить', () async {
      env = await AppEnv.create(
        tokens: MemoryTokenStore(fakeSession()),
        overrides: [
          serverConnectionSettingsProvider.overrideWith(
            (ref) => Future<ServerConnectionSettings>.error(StateError('db')),
          ),
        ],
      );
      expect(await env.container.read(apiClientResolverProvider)(), isNull);
      expect(await runHeadlessSync(env.container), isFalse);
    });

    test(
      'runHeadlessSync: сбой сервера (5xx) — повторить позже (false)',
      () async {
        env = await AppEnv.create(signedIn: true);
        env.backend.failStatusNext('/sync/push', 503);
        final store = env.container.read(syncStoreProvider);
        await store.create('notes', uuid7(), {'title': 'x'});
        expect(await runHeadlessSync(env.container), isFalse);
        expect(
          env.container.read(syncEngineProvider).state.failure?.kind,
          SyncFailureKind.server,
        );
      },
    );

    test('runHeadlessSync: 426, нет сети и лимит — не повод для повтора '
        '(true)', () async {
      env = await AppEnv.create(signedIn: true);
      final store = env.container.read(syncStoreProvider);
      await store.create('notes', uuid7(), {'title': 'x'});
      env.backend.failNext('/sync/push'); // нет сети
      expect(await runHeadlessSync(env.container), isTrue);
      env.backend.minClientSchema = 9; // сервер требует обновления
      expect(await runHeadlessSync(env.container), isTrue);
      expect(env.container.read(syncEngineProvider).state.blockedMinSchema, 9);
    });

    test(
      'M3: интерфейс на переднем плане — headless-запуск пропускается',
      () async {
        env = await AppEnv.create(signedIn: true);
        final store = env.container.read(syncStoreProvider);
        await store.create('notes', uuid7(), {'title': 'x'});
        await store.markForeground();
        env.backend.requests.clear();
        expect(await runHeadlessSync(env.container), isTrue);
        expect(env.backend.requests, isEmpty, reason: 'никаких запросов');
        expect(await store.outbox(), hasLength(1));
        // отметка устарела (приложение убито) — цикл идёт
        env.clock.advance(SyncStore.foregroundTtl + const Duration(seconds: 1));
        expect(await runHeadlessSync(env.container), isTrue);
        expect(await store.outbox(), isEmpty);
      },
    );

    test(
      'runHeadlessSync: хук afterSync вызывается после цикла; его сбой '
      'не портит результат; без входа и на переднем плане — не вызывается',
      () async {
        env = await AppEnv.create();
        var calls = 0;
        Future<void> hook(ProviderContainer _) async => calls++;
        expect(await runHeadlessSync(env.container, afterSync: hook), isTrue);
        expect(calls, 0, reason: 'нет входа');
        await env.login();
        expect(await runHeadlessSync(env.container, afterSync: hook), isTrue);
        expect(calls, 1);
        expect(
          await runHeadlessSync(
            env.container,
            afterSync: (_) async => throw StateError('hook'),
          ),
          isTrue,
        );
        await env.container.read(syncStoreProvider).markForeground();
        expect(await runHeadlessSync(env.container, afterSync: hook), isTrue);
        expect(calls, 1, reason: 'интерфейс на переднем плане');
      },
    );

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
