import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

import '../../support/fake_server/fake_sync_server.dart';
import '../../support/fake_server/server_remote.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';

class _Boom implements Exception;

/// Удалённый сервер, который ведёт себя по сценарию теста.
class _ScriptedRemote implements SyncRemote {
  _ScriptedRemote(this.inner);

  final SyncRemote inner;
  Exception? pushError;
  Exception? pullError;
  Future<void>? gate;
  int pullCalls = 0;
  PushResponse Function(PushResponse)? tamper;

  /// Вызывается перед каждым pull (номер вызова с 1, курсор `since`).
  void Function(int call, int since)? beforePull;

  @override
  Future<PushResponse> push(List<Json> ops) async {
    if (pushError != null) throw pushError!;
    final r = await inner.push(ops);
    return tamper?.call(r) ?? r;
  }

  @override
  Future<PullPage> pull({required int since, required int limit}) async {
    pullCalls++;
    beforePull?.call(pullCalls, since);
    await gate;
    if (pullError != null) throw pullError!;
    return await inner.pull(since: since, limit: limit);
  }

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) => inner.conflicts(reverted: reverted, limit: limit, before: before);

  @override
  Future<RevertResult> revert(String conflictId) => inner.revert(conflictId);
}

ApiException _http(int status, String code, [Map<String, Object?>? details]) =>
    ApiException(
      kind: ApiErrorKind.http,
      status: status,
      code: code,
      details: details ?? const {},
    );

void main() {
  late FakeSyncServer server;
  late ManualClock clock;
  late TestDevice a;
  late TestDevice b;

  setUp(() async {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    a = await TestDevice.create(server, clock: clock);
    b = await TestDevice.create(server, clock: clock);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await server.dispose();
  });

  Future<String> newNote(TestDevice d, String title) async {
    final id = uuid7();
    await d.store.create('notes', id, {'title': title});
    return id;
  }

  group('цикл push -> pull', () {
    test('создание на одном устройстве доезжает до другого', () async {
      final id = await newNote(a, 'hello');
      expect(await a.sync(), SyncOutcome.success);
      expect(await b.sync(), SyncOutcome.success);
      final row = (await b.store.getRow('notes', id))!;
      expect(row['title'], 'hello');
      expect(row['server_version'], 1);
      expect(await a.store.outbox(), isEmpty);
      expect(await b.store.cursor(), server.head);
      expect(a.engine.state.lastSuccessAt, isNotNull);
      expect(a.engine.state.failure, isNull);
    });

    test(
      'после applied своя строка возвращается эхом и совпадает с сервером',
      () async {
        final id = await newNote(a, 'x');
        await a.sync();
        expect(await a.rows('notes'), {id: server.row('notes', id)});
      },
    );

    test('push пачками не больше 500 операций', () async {
      for (var i = 0; i < 1203; i++) {
        await newNote(a, 'n$i');
      }
      await a.sync();
      expect(server.pushSizes, [500, 500, 203]);
      expect(server.snapshot('notes'), hasLength(1203));
      expect(await a.store.outbox(), isEmpty);
    });

    test('pull страницами; курсор двигается после каждой', () async {
      final small = await TestDevice.create(
        server,
        clock: clock,
        pullPageSize: 7,
      );
      for (var i = 0; i < 20; i++) {
        await newNote(a, 'n$i');
      }
      await a.sync();
      final pullsBefore = server.pullCalls;
      await small.sync();
      expect(server.pullCalls - pullsBefore, 3);
      expect(await small.rows('notes'), hasLength(20));
      expect(await small.store.cursor(), server.head);
      expect(small.engine.state.pulledRows, 20);
      await small.close();
    });

    test('лимит страницы pull не больше 1000', () {
      expect(
        () => SyncEngine(
          store: a.store,
          remote: a.remote,
          clientSchemaVersion: 1,
          pullPageSize: 1001,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('курсор не двигается, если вторая страница не пришла', () async {
      for (var i = 0; i < 10; i++) {
        await newNote(a, 'n$i');
      }
      await a.sync();
      final remote = _ScriptedRemote(b.remote);
      final engine = SyncEngine(
        store: b.store,
        remote: remote,
        clientSchemaVersion: 1,
        pullPageSize: 4,
        clock: () => clock.now,
      );
      // вторая страница обрывается
      var page = 0;
      final flaky = _PageFailRemote(
        b.remote,
        failOnPage: 2,
        counter: () => ++page,
      );
      final e2 = SyncEngine(
        store: b.store,
        remote: flaky,
        clientSchemaVersion: 1,
        pullPageSize: 4,
        clock: () => clock.now,
      );
      expect(await e2.runCycle(), SyncOutcome.offline);
      expect(await b.store.cursor(), 4);
      expect(await b.rows('notes'), hasLength(4));
      expect(await engine.runCycle(), SyncOutcome.success);
      expect(await b.rows('notes'), hasLength(10));
      await engine.dispose();
      await e2.dispose();
    });

    test(
      'has_more без продвижения курсора — ошибка протокола, не цикл',
      () async {
        final broken = _ScriptedRemote(a.remote);
        final engine = SyncEngine(
          store: a.store,
          remote: _StuckPullRemote(broken),
          clientSchemaVersion: 1,
          clock: () => clock.now,
        );
        expect(await engine.runCycle(), SyncOutcome.failed);
        expect(engine.state.failure!.kind, SyncFailureKind.protocol);
        await engine.dispose();
      },
    );

    test('правки во время цикла запускают ещё один круг', () async {
      final id = await newNote(a, 'first');
      final gate = Completer<void>();
      final remote = _ScriptedRemote(a.remote)..gate = gate.future;
      final engine = SyncEngine(
        store: a.store,
        remote: remote,
        clientSchemaVersion: 1,
        clock: () => clock.now,
      );
      final run = engine.runCycle();
      await pumpEventQueue();
      await a.store.update('notes', id, {'title': 'second'});
      gate.complete();
      expect(await run, SyncOutcome.success);
      expect(server.row('notes', id)!['title'], 'second');
      expect(await a.store.outbox(), isEmpty);
      await engine.dispose();
    });

    test('один цикл за раз: параллельные вызовы присоединяются', () async {
      final gate = Completer<void>();
      final remote = _ScriptedRemote(a.remote)..gate = gate.future;
      final engine = SyncEngine(
        store: a.store,
        remote: remote,
        clientSchemaVersion: 1,
        clock: () => clock.now,
      );
      final r1 = engine.runCycle();
      final r2 = engine.runCycle();
      await pumpEventQueue();
      expect(engine.state.phase, SyncPhase.syncing);
      expect(engine.state.isBusy, isTrue);
      gate.complete();
      expect([await r1, await r2], [SyncOutcome.success, SyncOutcome.success]);
      expect(remote.pullCalls, 1);
      expect(engine.state.phase, SyncPhase.idle);
      await engine.dispose();
    });

    test('локальные надгробия старше 30 суток убираются после цикла', () async {
      final id = await newNote(a, 'x');
      await a.sync();
      await a.store.softDelete('notes', id);
      await a.sync();
      clock.advance(const Duration(days: 31));
      await a.sync();
      expect(await a.rows('notes'), isEmpty);
    });
  });

  group('сбои сети и идемпотентность', () {
    test(
      'обрыв push: операции остаются in_flight, pull не выполняется',
      () async {
        final id = await newNote(a, 'x');
        a.remote.faults.scripted.add(Fault.dropRequest);
        expect(await a.sync(), SyncOutcome.offline);
        final ops = await a.store.outbox();
        expect(ops.single.state, OpState.inFlight);
        expect(server.processedOps, 0);
        expect(a.engine.state.failure!.kind, SyncFailureKind.offline);
        expect(a.engine.state.phase, SyncPhase.idle);
        expect(await a.sync(), SyncOutcome.success);
        expect(server.row('notes', id), isNotNull);
        expect(a.engine.state.failure, isNull);
      },
    );

    test('потерянный ответ push: повтор безопасен (duplicate), '
        'сервер применил один раз', () async {
      final id = await newNote(a, 'x');
      final op = (await a.store.outbox()).single;
      a.remote.faults.scripted.add(Fault.dropResponse);
      expect(await a.sync(), SyncOutcome.offline);
      expect(server.processedOps, 1);
      expect(server.row('notes', id)!['server_version'], 1);
      // повтор тем же op_id
      expect((await a.store.outbox()).single.opId, op.opId);
      expect(await a.sync(), SyncOutcome.success);
      expect(server.processedOps, 1);
      expect(server.head, 1, reason: 'повтор не расходует версию');
      expect(await a.store.outbox(), isEmpty);
      expect(await a.rows('notes'), {id: server.row('notes', id)});
    });

    test('потерянный ответ + новая правка до повтора: обе доходят', () async {
      final id = await newNote(a, 'x');
      a.remote.faults.scripted.add(Fault.dropResponse);
      await a.sync();
      await a.store.update('notes', id, {'title': 'y'});
      final ops = await a.store.outbox();
      expect(ops.map((o) => o.state), [OpState.inFlight, OpState.pending]);
      expect(await a.sync(), SyncOutcome.success);
      expect(server.row('notes', id)!['title'], 'y');
      expect(server.conflicts, isEmpty);
    });

    test(
      'потерянный ответ pull: курсор не двигается, повтор догоняет',
      () async {
        final id = await newNote(a, 'x');
        await a.sync();
        a.remote.faults.scripted
          ..add(Fault.none) // push нечего слать: сразу pull
          ..add(Fault.dropResponse);
        await newNote(b, 'y');
        await b.sync();
        // a: pull теряется
        a.remote.faults.scripted.clear();
        a.remote.faults.scripted.add(Fault.dropResponse);
        final cursor = await a.store.cursor();
        expect(await a.sync(), SyncOutcome.offline);
        expect(await a.store.cursor(), cursor);
        expect(await a.sync(), SyncOutcome.success);
        expect(await a.rows('notes'), hasLength(2));
        expect(id, isNotEmpty);
      },
    );

    test('отклонённая операция не блокирует остальные', () async {
      // Таблица есть у клиента, но не у сервера (клиент новее сервера).
      final registry = SyncRegistry([...testRegistry().specs, _extrasSpec]);
      final c = await TestDevice.create(
        server,
        clock: clock,
        registry: registry,
      );
      final bad = uuid7();
      await c.store.create('extras', bad, {'name': 'x'});
      final good = await newNote(c, 'ok');
      await newNote(c, 'ok2');
      expect(await c.sync(), SyncOutcome.success);
      expect(server.snapshot('notes'), hasLength(2));
      final rest = await c.store.outbox();
      expect(rest.single.state, OpState.rejected);
      expect(rest.single.rejectCode, 'unknown_table');
      expect(rest.single.rowId, bad);
      expect(good, isNotEmpty);
      // повторно автоматически не отправляется
      final before = server.processedOps;
      await c.sync();
      expect(server.processedOps, before);
      expect((await c.store.outboxSummary()).rejected, 1);
      await c.close();
    });

    test('hlc_in_future: операция остаётся в очереди, предупреждение, '
        'потом уходит', () async {
      final skewed = ManualClock(
        clock.ms + const Duration(hours: 1).inMilliseconds,
      );
      final c = await TestDevice.create(server, clock: skewed);
      final id = await newNote(c, 'from the future');
      expect(await c.sync(), SyncOutcome.success);
      expect(c.engine.state.clockSkew, isTrue);
      final ops = await c.store.outbox();
      expect(ops.single.state, OpState.inFlight);
      expect(server.row('notes', id), isNull);
      // в этом цикле повторно не отправлялась (нет бесконечного цикла)
      expect(server.pushCalls, 1);
      // часы исправлены
      skewed.ms = clock.ms;
      // метка операции остаётся «из будущего» (1 ч), пока время не дойдёт
      clock.advance(const Duration(minutes: 55));
      skewed.ms = clock.ms;
      expect(await c.sync(), SyncOutcome.success);
      expect(c.engine.state.clockSkew, isFalse);
      expect(server.row('notes', id), isNotNull);
      expect(await c.store.outbox(), isEmpty);
      await c.close();
    });

    test('сервер не вернул результат для операции: она остаётся, цикл не '
        'зацикливается', () async {
      await newNote(a, 'x');
      final remote = _ScriptedRemote(a.remote)
        ..tamper = (r) =>
            PushResponse(results: const [], headVersion: r.headVersion);
      final engine = SyncEngine(
        store: a.store,
        remote: remote,
        clientSchemaVersion: 1,
        clock: () => clock.now,
      );
      expect(await engine.runCycle(), SyncOutcome.success);
      expect((await a.store.outbox()).single.state, OpState.inFlight);
      await engine.dispose();
    });
  });

  group('ошибки протокола', () {
    late _ScriptedRemote remote;
    late SyncEngine engine;

    setUp(() async {
      remote = _ScriptedRemote(a.remote);
      engine = SyncEngine(
        store: a.store,
        remote: remote,
        clientSchemaVersion: 1,
        clock: () => clock.now,
      );
      await newNote(a, 'x');
    });
    tearDown(() => engine.dispose());

    test(
      '426 client_too_old: блокировка, работа офлайн, повтор не ходит в сеть',
      () async {
        remote.pushError = _http(426, 'client_too_old', {
          'min_client_schema_version': 2,
          'api_schema_version': 2,
        });
        expect(await engine.runCycle(), SyncOutcome.blockedOldClient);
        expect(engine.state.blockedMinSchema, 2);
        expect(engine.state.failure!.kind, SyncFailureKind.clientTooOld);
        expect(await a.store.blockedMinSchema(), 2);
        remote.pushError = null;
        final calls = server.pushCalls;
        expect(await engine.runCycle(), SyncOutcome.blockedOldClient);
        expect(server.pushCalls, calls);
        // локальная работа продолжается
        await newNote(a, 'offline still works');
        expect(await a.store.outbox(), hasLength(2));
        // приложение обновили: схема клиента достаточна
        final updated = SyncEngine(
          store: a.store,
          remote: a.remote,
          clientSchemaVersion: 2,
          clock: () => clock.now,
        );
        await updated.init();
        expect(updated.state.isBlocked, isFalse);
        expect(await updated.runCycle(), SyncOutcome.success);
        expect(await a.store.blockedMinSchema(), isNull);
        await updated.dispose();
      },
    );

    test(
      'блокировка снимается, когда версия клиента догнала требование',
      () async {
        remote.pushError = _http(426, 'client_too_old');
        await engine.runCycle();
        expect(engine.state.blockedMinSchema, 2);
        final newer = SyncEngine(
          store: a.store,
          remote: a.remote,
          clientSchemaVersion: 5,
          clock: () => clock.now,
        );
        // тот же процесс, версия «обновилась» без перезапуска
        expect(await newer.runCycle(), SyncOutcome.success);
        await newer.dispose();
      },
    );

    test('429: пауза по Retry-After, за это время запросов нет', () async {
      remote.pushError = const ApiException(
        kind: ApiErrorKind.http,
        status: 429,
        code: 'too_many_attempts',
        retryAfter: Duration(seconds: 30),
      );
      expect(await engine.runCycle(), SyncOutcome.rateLimited);
      expect(engine.state.pausedUntil, isNotNull);
      remote.pushError = null;
      final calls = server.pushCalls;
      expect(await engine.runCycle(), SyncOutcome.rateLimited);
      expect(server.pushCalls, calls);
      clock.advance(const Duration(seconds: 31));
      expect(await engine.runCycle(), SyncOutcome.success);
      expect(engine.state.pausedUntil, isNull);
    });

    test('429 без Retry-After: пауза по умолчанию', () async {
      remote.pushError = _http(429, 'too_many_attempts');
      await engine.runCycle();
      expect(
        engine.state.pausedUntil!.difference(clock.now),
        engine.defaultPause,
      );
    });

    test('401: нужен вход', () async {
      remote.pushError = _http(401, 'device_revoked');
      expect(await engine.runCycle(), SyncOutcome.authRequired);
      expect(engine.state.failure!.kind, SyncFailureKind.authRequired);
    });

    test('сервер не настроен', () async {
      remote.pushError = const ApiException.notConfigured();
      expect(await engine.runCycle(), SyncOutcome.notConfigured);
      expect(engine.state.failure!.kind, SyncFailureKind.notConfigured);
    });

    test('500: сбой сервера, операции остаются', () async {
      remote.pushError = _http(503, 'unavailable');
      expect(await engine.runCycle(), SyncOutcome.failed);
      expect(engine.state.failure!.kind, SyncFailureKind.server);
      expect(await a.store.outbox(), hasLength(1));
    });

    test('прочие 4xx и неизвестные ошибки', () async {
      remote.pushError = _http(422, 'validation_error');
      expect(await engine.runCycle(), SyncOutcome.failed);
      expect(engine.state.failure!.kind, SyncFailureKind.protocol);
      remote.pushError = _Boom();
      expect(await engine.runCycle(), SyncOutcome.failed);
      expect(engine.state.failure!.kind, SyncFailureKind.unknown);
      expect(engine.state.phase, SyncPhase.idle);
    });

    test('сбой сертификата считается отсутствием сети', () async {
      remote.pushError = const ApiException(kind: ApiErrorKind.certMismatch);
      expect(await engine.runCycle(), SyncOutcome.offline);
    });

    test('изменения состояния публикуются в поток', () async {
      final phases = <SyncPhase>[];
      final sub = engine.changes.listen((s) => phases.add(s.phase));
      await engine.runCycle();
      await pumpEventQueue();
      await sub.cancel();
      expect(phases, contains(SyncPhase.syncing));
      expect(phases.last, SyncPhase.idle);
    });
  });

  group('полная пересинхронизация (spec 5.3)', () {
    test(
      '410 resync_required: строки без надгробий исчезают, outbox цел',
      () async {
        final keep = await newNote(a, 'keep');
        final deleted = await newNote(a, 'deleted');
        await a.sync();
        await b.sync();
        expect(await b.rows('notes'), hasLength(2));
        // b офлайн; a удаляет строку, проходит 31 день, сервер очищает
        await a.store.softDelete('notes', deleted);
        await a.sync();
        clock.advance(const Duration(days: 31));
        await a.sync(); // a закрепил курсор за версией удаления
        expect(server.purge(activeDevices: {a.deviceId}), 1);
        expect(server.purgeWatermark, greaterThan(0));
        // b вернулся с неотправленной правкой
        await b.store.update('notes', keep, {'title': 'edited offline'});
        expect(await b.sync(), SyncOutcome.success);
        final rows = await b.rows('notes');
        expect(rows.keys, [keep]);
        expect(rows[keep]!['title'], 'edited offline');
        expect(server.row('notes', keep)!['title'], 'edited offline');
        expect(await b.store.cursor(), server.head);
      },
    );

    test('кнопка: outbox сохраняется, строки перезаписываются серверными', () async {
      final id = await newNote(a, 'x');
      await a.sync();
      await b.sync();
      await b.store.update('notes', id, {'title': 'pending edit'});
      // локальная порча «на месте»
      await b.db.customUpdate("UPDATE notes SET body = 'garbage'");
      // push выполнится внутри fullResync, поэтому оффлайн-правка не потеряется
      expect(await b.engine.fullResync(), SyncOutcome.success);
      expect(server.row('notes', id)!['title'], 'pending edit');
      final row = (await b.store.getRow('notes', id))!;
      expect(row['body'], isNull, reason: 'серверное состояние вернулось');
      expect(row['title'], 'pending edit');
    });

    test(
      'полная пересинхронизация без сети: outbox и строки не тронуты',
      () async {
        final id = await newNote(a, 'x');
        await a.sync();
        await a.store.update('notes', id, {'title': 'pending'});
        a.remote.faults.offline = true;
        expect(await a.engine.fullResync(), SyncOutcome.offline);
        expect((await a.store.getRow('notes', id))!['title'], 'pending');
        expect(await a.store.outbox(), hasLength(1));
      },
    );

    test(
      'после отбрасывания rejected операции цикл делает пересинхронизацию',
      () async {
        final registry = SyncRegistry([...testRegistry().specs, _extrasSpec]);
        final c = await TestDevice.create(
          server,
          clock: clock,
          registry: registry,
        );
        await c.store.create('extras', uuid7(), {'name': 'x'});
        await c.sync();
        final rejected = (await c.store.outbox()).single;
        await c.store.discardRejected(rejected.opId);
        expect(await c.store.needsResync(), isTrue);
        expect(await c.sync(), SyncOutcome.success);
        expect(await c.store.needsResync(), isFalse);
        expect(await c.rows('extras'), isEmpty);
        await c.close();
      },
    );
  });

  group('конфликты и корзина через сервер', () {
    test(
      'правка одного поля с двух устройств: LWW, журнал, «вернуть моё»',
      () async {
        final id = await newNote(a, 'base');
        await a.sync();
        await b.sync();
        await a.store.update('notes', id, {'title': 'from a'});
        clock.advance(const Duration(seconds: 2));
        await b.store.update('notes', id, {'title': 'from b'});
        await a.sync();
        await b.sync();
        await a.sync();
        expect(server.row('notes', id)!['title'], 'from b');
        expect(server.conflicts, hasLength(1));
        final page = await a.remote.conflicts();
        final conflict = page.conflicts.single;
        expect(conflict.kind, ConflictKind.field);
        expect(conflict.losingValue, 'from a');
        expect(conflict.canRevert, isTrue);
        final result = await a.remote.revert(conflict.id);
        await a.store.applyChange(result.change);
        expect((await a.store.getRow('notes', id))!['title'], 'from a');
        await a.sync();
        await b.sync();
        expect(server.row('notes', id)!['title'], 'from a');
        expect((await b.store.getRow('notes', id))!['title'], 'from a');
        expect(result.conflict.isReverted, isTrue);
      },
    );

    test('удаление против правки и восстановление из корзины', () async {
      final id = await newNote(a, 'x');
      await a.sync();
      await b.sync();
      await a.store.softDelete('notes', id);
      await a.sync();
      await b.sync();
      expect((await b.store.trashItems()).single.id, id);
      await b.store.restore('notes', id);
      await b.sync();
      await a.sync();
      expect((await a.store.getRow('notes', id))!['deleted_at'], isNull);
      expect(await a.store.trashItems(), isEmpty);
    });
  });

  group('эпоха сервера (восстановление из резервной копии)', () {
    test('первая эпоха запоминается без пересинхронизации', () async {
      await newNote(a, 'x');
      await a.sync();
      expect(await a.store.serverEpoch(), 'epoch-1');
      final pulls = server.pullCalls;
      await a.sync();
      expect(server.pullCalls - pulls, 1);
    });

    test('сервер без эпохи: ничего не меняется', () async {
      server.epoch = null;
      await newNote(a, 'x');
      expect(await a.sync(), SyncOutcome.success);
      expect(await a.store.serverEpoch(), isNull);
    });

    test(
      'другая эпоха при pull: полная пересинхронизация, outbox цел',
      () async {
        final keep = await newNote(a, 'keep');
        await a.sync();
        final backup = server.backup();
        final later = await newNote(a, 'created after the backup');
        await a.sync();
        await b.sync();
        expect(await b.rows('notes'), hasLength(2));
        // сервер откатили к копии
        server.restore(backup, newEpoch: 'epoch-2');
        await b.store.update('notes', keep, {'title': 'offline edit'});
        expect(await b.sync(), SyncOutcome.success);
        final rows = await b.rows('notes');
        expect(rows.keys, [
          keep,
        ], reason: 'строки, которых нет в копии, исчезли');
        expect(rows[keep]!['title'], 'offline edit');
        expect(server.row('notes', keep)!['title'], 'offline edit');
        expect(await b.store.serverEpoch(), 'epoch-2');
        expect(await b.store.cursor(), server.head);
        expect(later, isNotEmpty);
      },
    );

    test(
      'другая эпоха при push: очередь уходит, затем пересинхронизация',
      () async {
        final keep = await newNote(a, 'keep');
        await a.sync();
        final backup = server.backup();
        await newNote(a, 'lost with the server');
        await a.sync();
        server.restore(backup, newEpoch: 'epoch-2');
        await a.store.update('notes', keep, {'title': 'edit'});
        expect(await a.sync(), SyncOutcome.success);
        expect((await a.rows('notes')).keys, [keep]);
        expect(await a.store.outbox(), isEmpty);
        expect(await a.store.needsResync(), isFalse);
        expect(await a.store.serverEpoch(), 'epoch-2');
        expect(await a.rows('notes'), server.snapshot('notes'));
      },
    );
  });

  group('M1: эпоха меняется во время полной пересинхронизации', () {
    Future<Object> seed() async {
      for (var i = 0; i < 3; i++) {
        await newNote(a, 'old$i');
      }
      await a.sync();
      final backup = server.backup();
      for (var i = 0; i < 3; i++) {
        await newNote(a, 'new$i');
      }
      await a.sync();
      return backup;
    }

    test(
      'страницы разных эпох не смешиваются: загрузка начинается заново',
      () async {
        final backup = await seed();
        final remote = _ScriptedRemote(b.remote);
        final engine = SyncEngine(
          store: b.store,
          remote: remote,
          clientSchemaVersion: 1,
          pullPageSize: 2,
          clock: () => clock.now,
        );
        await b.store.setNeedsResync(value: true);
        var restored = false;
        remote.beforePull = (call, since) {
          if (since > 0 && !restored) {
            restored = true; // сервер восстановили, пока мы качали
            server.restore(backup, newEpoch: 'epoch-2');
          }
        };
        expect(await engine.runCycle(), SyncOutcome.success);
        expect(restored, isTrue);
        expect(await b.rows('notes'), server.snapshot('notes'));
        expect(await b.rows('notes'), hasLength(3), reason: 'только из копии');
        expect(await b.store.serverEpoch(), 'epoch-2');
        expect(await b.store.cursor(), server.head);
        expect(await b.store.needsResync(), isFalse);
        await engine.dispose();
      },
    );

    test('эпоха меняется на каждой попытке: ограниченное число повторов, '
        'флаг пересинхронизации остаётся', () async {
      await seed();
      final remote = _ScriptedRemote(b.remote);
      final engine = SyncEngine(
        store: b.store,
        remote: remote,
        clientSchemaVersion: 1,
        pullPageSize: 2,
        maxResyncAttempts: 3,
        clock: () => clock.now,
      );
      await b.store.setNeedsResync(value: true);
      var n = 0;
      remote.beforePull = (call, since) {
        if (since > 0) server.epoch = 'flap-${n++}';
      };
      expect(await engine.runCycle(), SyncOutcome.failed);
      expect(remote.pullCalls, 3 * 2, reason: '3 попытки по 2 страницы');
      expect(await b.store.needsResync(), isTrue);
      expect(await b.rows('notes'), isEmpty, reason: 'ничего не применено');
      await engine.dispose();
    });
  });

  group('410 resync_required: cursor_ahead и purged', () {
    test('сервер знает причину: cursor_ahead при since > head', () async {
      await newNote(a, 'x');
      await a.sync();
      Object? error;
      try {
        server.pull(a.deviceId, server.head + 1, 10);
      } on ApiException catch (e) {
        error = e;
        expect(e.status, 410);
        expect(e.code, 'resync_required');
        expect(e.details['reason'], 'cursor_ahead');
        expect(e.details['head_version'], server.head);
      }
      expect(error, isNotNull);
      // since == head — обычный ответ без строк
      expect(server.pull(a.deviceId, server.head, 10)['changes'], isEmpty);
    });

    test('purged: причина в details', () async {
      final id = await newNote(a, 'gone');
      await a.sync();
      await a.store.softDelete('notes', id);
      await a.sync();
      clock.advance(const Duration(days: 31));
      await a.sync();
      expect(server.purge(activeDevices: {a.deviceId}), 1);
      try {
        server.pull(b.deviceId, 1, 10);
        fail('ожидался 410');
      } on ApiException catch (e) {
        expect(e.details['reason'], 'purged');
      }
    });

    test('курсор клиента опережает сервер (восстановление из старого дампа '
        'без смены эпохи): полная пересинхронизация', () async {
      final keep = await newNote(a, 'keep');
      await a.sync();
      final backup = server.backup();
      await newNote(a, 'lost');
      await a.sync();
      await b.sync();
      expect(await b.store.cursor(), greaterThan(1));
      server.restore(backup, newEpoch: 'epoch-1'); // эпоха та же
      expect(await b.store.cursor(), greaterThan(server.head));
      expect(await b.sync(), SyncOutcome.success);
      expect((await b.rows('notes')).keys, [keep]);
      expect(await b.store.cursor(), server.head);
    });
  });

  group('M2: полная пересинхронизация и неотправленные создания', () {
    test('строка, созданная локально и не принятая сервером (hlc_in_future), '
        'переживает пересинхронизацию', () async {
      final skewed = ManualClock(
        clock.ms + const Duration(hours: 1).inMilliseconds,
      );
      final c = await TestDevice.create(server, clock: skewed);
      final id = await newNote(c, 'held');
      server.epoch = 'epoch-2'; // повод для полной пересинхронизации
      expect(await c.sync(), SyncOutcome.success);
      expect(c.engine.state.clockSkew, isTrue);
      final rows = await c.rows('notes');
      expect(rows.keys, [id], reason: 'строка возвращена после замены');
      expect(rows[id]!['title'], 'held');
      expect(await c.store.outbox(), hasLength(1));
      expect(await c.store.serverEpoch(), 'epoch-2');
      await c.close();
    });
  });

  group('op_failed', () {
    test('операция отклоняется с op_failed, остальные применяются; '
        'повтор после исправления доходит', () async {
      final bad = await newNote(a, 'bad');
      final good = await newNote(a, 'good');
      server.failOpRowIds.add(bad);
      expect(await a.sync(), SyncOutcome.success);
      expect(server.row('notes', good), isNotNull);
      expect(server.row('notes', bad), isNull);
      final rejected = (await a.store.outbox()).single;
      expect(rejected.rejectCode, 'op_failed');
      expect(rejected.state, OpState.rejected);
      server.failOpRowIds.clear();
      await a.store.retryRejected(rejected.opId);
      expect(await a.sync(), SyncOutcome.success);
      expect(server.row('notes', bad), isNotNull);
      expect(await a.store.outbox(), isEmpty);
    });
  });

  test('HLC устройства после pull строго больше всего увиденного', () async {
    await newNote(a, 'x');
    clock.advance(const Duration(hours: 2));
    await a.sync();
    final slow = ManualClock(
      clock.ms - const Duration(hours: 1).inMilliseconds,
    );
    final c = await TestDevice.create(server, clock: slow);
    await c.sync();
    final seen = (await c.rows('notes')).values
        .map((r) => r['updated_at']! as String)
        .reduce((x, y) => x.compareTo(y) > 0 ? x : y);
    final id = await newNote(c, 'later');
    final row = await c.store.getRow('notes', id);
    expect(compareHlc(row!['updated_at']! as String, seen), 1);
    await c.close();
  });
}

const SyncTableSpec _extrasSpec = SyncTableSpec(
  name: 'extras',
  label: 'Extra',
  columns: [SyncColumn('name', SyncColumnType.text)],
  titleOf: _n,
);

String _n(Json row) => '${row['name']}';

/// Обрывает выбранную по счёту страницу pull.
class _PageFailRemote implements SyncRemote {
  _PageFailRemote(
    this.inner, {
    required this.failOnPage,
    required this.counter,
  });

  final SyncRemote inner;
  final int failOnPage;
  final int Function() counter;

  @override
  Future<PushResponse> push(List<Json> ops) => inner.push(ops);

  @override
  Future<PullPage> pull({required int since, required int limit}) async {
    if (counter() == failOnPage) throw const ApiException.network('cut');
    return await inner.pull(since: since, limit: limit);
  }

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) => inner.conflicts();

  @override
  Future<RevertResult> revert(String conflictId) => inner.revert(conflictId);
}

/// Сервер, который всё время говорит «есть ещё» с тем же курсором.
class _StuckPullRemote implements SyncRemote {
  _StuckPullRemote(this.inner);

  final SyncRemote inner;

  @override
  Future<PushResponse> push(List<Json> ops) => inner.push(ops);

  @override
  Future<PullPage> pull({required int since, required int limit}) async =>
      PullPage(
        changes: const [],
        nextSince: since,
        hasMore: true,
        headVersion: 1,
      );

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) => inner.conflicts();

  @override
  Future<RevertResult> revert(String conflictId) => inner.revert(conflictId);
}
