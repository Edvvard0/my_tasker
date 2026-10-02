import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/server_epoch.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';

void main() {
  late FakeSyncServer server;
  late ManualClock clock;
  late TestDevice d;
  late SyncStore store;

  setUp(() async {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    d = await TestDevice.create(server, clock: clock);
    store = d.store;
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  Future<List<OutboxOp>> outbox() => store.outbox();

  group('локальные правки (spec 5.1)', () {
    test('create: строка, HLC и операция outbox в одной транзакции', () async {
      final id = uuid7();
      final row = await store.create('notes', id, {'title': 'a'});
      expect(row['server_version'], 0);
      expect(row['deleted_at'], isNull);
      expect(row['origin_device_id'], d.deviceId);
      expect(row['updated_at'], startsWith('001790000000000-00000-'));
      final ops = await outbox();
      expect(ops, hasLength(1));
      expect(ops.single.type, 'upsert');
      expect(ops.single.baseVersion, 0);
      expect(ops.single.fields, {
        'title': 'a',
        'created_at': row['created_at'],
      });
      expect(ops.single.hlc, row['updated_at']);
      expect(ops.single.state, OpState.pending);
      expect(isUuid7(ops.single.opId), isTrue);
      expect(await store.getRow('notes', id), isNotNull);
    });

    test(
      'сбой посреди транзакции откатывает и строку, и HLC, и outbox',
      () async {
        final before = await store.hlcState();
        await expectLater(
          store.transaction(() async {
            await store.create('notes', uuid7(), {'title': 'a'});
            throw StateError('boom');
          }),
          throwsStateError,
        );
        expect(await outbox(), isEmpty);
        expect(await d.rows('notes'), isEmpty);
        expect(await store.hlcState(), before);
      },
    );

    test('HLC сохраняется в БД и продолжается после «перезапуска»', () async {
      await store.create('notes', uuid7(), {'title': 'a'});
      await store.create('notes', uuid7(), {'title': 'b'});
      expect(await store.hlcState(), HlcState(clock.ms, 1));
      final restarted = SyncStore(
        db: d.db,
        registry: store.registry,
        nowMs: clock.call,
      );
      await restarted.create('notes', uuid7(), {'title': 'c'});
      expect(await restarted.hlcState(), HlcState(clock.ms, 2));
      clock.advance(const Duration(seconds: 1));
      await restarted.create('notes', uuid7(), {'title': 'd'});
      expect(await restarted.hlcState(), HlcState(clock.ms, 0));
    });

    test('часы пошли назад: метки всё равно возрастают', () async {
      final a = await store.create('notes', uuid7(), {'title': 'a'});
      clock.advance(const Duration(seconds: -10));
      final b = await store.create('notes', uuid7(), {'title': 'b'});
      expect(
        compareHlc(b['updated_at']! as String, a['updated_at']! as String),
        1,
      );
    });

    test('create поверх существующей строки — ошибка', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      await expectLater(
        store.create('notes', id, {'title': 'b'}),
        throwsStateError,
      );
    });

    test(
      'валидация полей: неизвестные, тип, обязательные, неизменяемые',
      () async {
        final id = uuid7();
        await expectLater(
          store.create('notes', id, {'title': 'a', 'nope': 1}),
          throwsArgumentError,
        );
        await expectLater(
          store.create('notes', id, {'title': 5}),
          throwsArgumentError,
        );
        await expectLater(
          store.create('notes', id, {'body': 'x'}),
          throwsArgumentError,
        );
        await expectLater(
          store.create('nope', id, {'title': 'a'}),
          throwsArgumentError,
        );
        expect(await outbox(), isEmpty);
        final key = uuid7();
        await store.create('user_settings', userSettingsId('ui.theme'), {
          'key': 'ui.theme',
          'value': 'dark',
        });
        await expectLater(
          store.update('user_settings', userSettingsId('ui.theme'), {
            'key': 'other',
          }),
          throwsArgumentError,
        );
        expect(key, isNotEmpty);
      },
    );

    test('update/softDelete/restore несуществующей строки — ошибка', () async {
      await expectLater(
        store.update('notes', uuid7(), {'title': 'x'}),
        throwsStateError,
      );
      await expectLater(store.softDelete('notes', uuid7()), throwsStateError);
      await expectLater(store.restore('notes', uuid7()), throwsStateError);
    });

    test('update с пустым набором полей ничего не делает', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      await store.update('notes', id, {});
      expect((await outbox()).single.fields, containsPair('title', 'a'));
    });

    test('полный цикл значений: json, bool, nullable', () async {
      final id = uuid7();
      await store.create('tasks', id, {
        'title': 't',
        'done': true,
        'meta': {
          'a': [1, 2],
        },
      });
      final row = (await store.getRow('tasks', id))!;
      expect(row['done'], isTrue);
      expect(row['meta'], {
        'a': [1, 2],
      });
      expect(row['project_id'], isNull);
      await store.update('tasks', id, {'meta': null, 'done': false});
      final next = (await store.getRow('tasks', id))!;
      expect(next['meta'], isNull);
      expect(next['done'], isFalse);
    });

    test(
      'softDelete: deleted_at из HLC, операция delete; повтор — no-op',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await store.softDelete('notes', id);
        final row = (await store.getRow('notes', id))!;
        expect(row['deleted_at'], msIso(clock.ms));
        await store.softDelete('notes', id);
        // создание + удаление не схлопываются: обе операции уходят на сервер
        expect((await outbox()).map((o) => o.type), ['upsert', 'delete']);
      },
    );

    test(
      'restore: deleted_at = null, операция upsert {deleted_at: null}',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await d.sync();
        await store.softDelete('notes', id);
        await store.restore('notes', id);
        await store.restore('notes', id); // уже жива — ничего
        final row = (await store.getRow('notes', id))!;
        expect(row['deleted_at'], isNull);
        final ops = await outbox();
        expect(ops.map((o) => o.type), ['delete', 'upsert']);
        expect(ops.last.fields, {'deleted_at': null});
        expect(ops.last.baseVersion, 1);
      },
    );

    test(
      'схлопывание идёт в БД: правки одной строки — одна операция',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await store.update('notes', id, {'body': 'b'});
        await store.update('notes', id, {'title': 'c'});
        final ops = await outbox();
        expect(ops, hasLength(1));
        expect(ops.single.baseVersion, 0);
        expect(ops.single.fields, containsPair('title', 'c'));
        expect(ops.single.fields, containsPair('body', 'b'));
        expect(ops.single.fields, contains('created_at'));
      },
    );

    test('правка существующей + удаление = одна операция delete', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      await d.sync();
      await store.update('notes', id, {'title': 'b'});
      await store.softDelete('notes', id);
      final ops = await outbox();
      expect(ops, hasLength(1));
      expect(ops.single.type, 'delete');
      expect(ops.single.fields, isNull);
      expect(ops.single.baseVersion, 1);
    });

    test(
      'in_flight операция не схлопывается: новая правка — отдельная',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await store.takeBatch();
        await store.update('notes', id, {'title': 'b'});
        final ops = await outbox();
        expect(ops.map((o) => o.state), [OpState.inFlight, OpState.pending]);
        expect(ops.first.fields!['title'], 'a');
      },
    );

    test('localWrites сообщает о записи', () async {
      var events = 0;
      final sub = store.localWrites.listen((_) => events++);
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      await store.update('notes', id, {'title': 'b'});
      await store.softDelete('notes', id);
      await store.restore('notes', id);
      await Future<void>.delayed(Duration.zero);
      expect(events, 4);
      await sub.cancel();
    });
  });

  group('outbox: отправка', () {
    test('takeBatch: порядок создания, лимит, in_flight, exclude', () async {
      final ids = [for (var i = 0; i < 5; i++) uuid7()];
      for (final id in ids) {
        await store.create('notes', id, {'title': id});
      }
      final first = await store.takeBatch(max: 2);
      expect(first.map((o) => o.rowId), ids.take(2));
      expect(first.every((o) => o.state == OpState.inFlight), isTrue);
      final again = await store.takeBatch(max: 3);
      expect(again.map((o) => o.rowId), ids.take(3)); // in_flight повторяются
      final rest = await store.takeBatch(exclude: {first.first.opId});
      expect(rest.map((o) => o.rowId), ids.skip(1));
      expect(
        await store.takeBatch(
          exclude: {for (final o in await outbox()) o.opId},
        ),
        isEmpty,
      );
    });

    test('toWire: форма операции spec 3.2', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      await d.sync();
      await store.softDelete('notes', id);
      await store.restore('notes', id);
      final wire = [for (final o in await outbox()) o.toWire()];
      expect(
        wire[0].keys,
        containsAll(['op_id', 'table', 'id', 'type', 'base_version', 'hlc']),
      );
      expect(wire[0], isNot(contains('fields')));
      expect(wire[1]['fields'], {'deleted_at': null});
      expect(wire[0]['table'], 'notes');
    });

    PushOpResult ok(String id) => PushOpResult(opId: id, applied: true);

    test('applyPushResults: applied удаляется, rejected помечается, '
        'hlc_in_future и потерянный результат остаются', () async {
      final ids = [for (var i = 0; i < 4; i++) uuid7()];
      for (final id in ids) {
        await store.create('notes', id, {'title': id});
      }
      final batch = await store.takeBatch();
      final held = await store.applyPushResults(batch, [
        ok(batch[0].opId),
        PushOpResult(
          opId: batch[1].opId,
          applied: false,
          code: 'invalid_field',
          message: 'title',
        ),
        PushOpResult(
          opId: batch[2].opId,
          applied: false,
          code: 'hlc_in_future',
        ),
        // результата для batch[3] нет
      ]);
      expect(held, {batch[2].opId, batch[3].opId});
      final left = await outbox();
      expect(left.map((o) => o.rowId), [ids[1], ids[2], ids[3]]);
      expect(left[0].state, OpState.rejected);
      expect(left[0].rejectCode, 'invalid_field');
      expect(left[0].rejectMessage, 'title');
      expect(left[1].state, OpState.inFlight);
      expect(left[2].state, OpState.inFlight);
      expect(await store.hasUnsent(), isTrue);
      expect(await store.hasUnsent(exclude: held), isFalse);
      final summary = await store.outboxSummary();
      expect(
        (summary.pending, summary.inFlight, summary.rejected, summary.unsent),
        (0, 2, 1, 2),
      );
    });

    test('rejected не участвует в takeBatch и не блокирует очередь', () async {
      final a = uuid7();
      final b = uuid7();
      await store.create('notes', a, {'title': 'a'});
      await store.create('notes', b, {'title': 'b'});
      final batch = await store.takeBatch();
      await store.applyPushResults(batch, [
        PushOpResult(
          opId: batch[0].opId,
          applied: false,
          code: 'unknown_table',
        ),
        ok(batch[1].opId),
      ]);
      expect(await store.takeBatch(), isEmpty);
    });

    test(
      'retryRejected: новая операция со свежим HLC и base_version строки',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(opId: batch.single.opId, applied: false, code: 'x'),
        ]);
        clock.advance(const Duration(seconds: 5));
        await store.retryRejected(batch.single.opId);
        final ops = await outbox();
        expect(ops, hasLength(1));
        expect(ops.single.opId, isNot(batch.single.opId));
        expect(ops.single.state, OpState.pending);
        expect(ops.single.fields, containsPair('title', 'a'));
        expect(compareHlc(ops.single.hlc, batch.single.hlc), 1);
        // неизвестная и не rejected операции игнорируются
        await store.retryRejected('nope');
        await store.retryRejected(ops.single.opId);
        expect(await outbox(), hasLength(1));
      },
    );

    test(
      'retryRejected для delete строки, которой уже нет — просто снимает',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await d.sync();
        await store.softDelete('notes', id);
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(opId: batch.single.opId, applied: false, code: 'x'),
        ]);
        await d.db.customUpdate('DELETE FROM notes');
        await store.retryRejected(batch.single.opId);
        expect(await outbox(), isEmpty);
      },
    );

    test(
      'discardRejected снимает операцию и просит пересинхронизацию',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(opId: batch.single.opId, applied: false, code: 'x'),
        ]);
        expect(await store.needsResync(), isFalse);
        await store.discardRejected(batch.single.opId);
        expect(await outbox(), isEmpty);
        expect(await store.needsResync(), isTrue);
        await store.setNeedsResync(value: false);
        await store.discardRejected('nope');
        expect(await store.needsResync(), isFalse);
      },
    );

    test('watchOutboxSummary и watchRejected реагируют на изменения', () async {
      final summaries = <OutboxSummary>[];
      final sub = store.watchOutboxSummary().listen(summaries.add);
      final rejected = <List<OutboxOp>>[];
      final sub2 = store.watchRejected().listen(rejected.add);
      await pumpEventQueue();
      await store.create('notes', uuid7(), {'title': 'a'});
      await pumpEventQueue();
      final batch = await store.takeBatch();
      await store.applyPushResults(batch, [
        PushOpResult(opId: batch.single.opId, applied: false, code: 'x'),
      ]);
      await pumpEventQueue();
      expect(summaries.last, const OutboxSummary(rejected: 1));
      expect(rejected.last.single.rejectCode, 'x');
      await sub.cancel();
      await sub2.cancel();
    });
  });

  group('применение данных сервера (spec 5.2, 5.3)', () {
    SyncChange change(Json row, {String table = 'notes'}) => SyncChange(
      table: table,
      id: row['id']! as String,
      serverVersion: row['server_version']! as int,
      row: row,
    );

    Json serverRow(String id, {int version = 7, Json? extra}) => {
      'id': id,
      'created_at': '2026-10-01T00:00:00.000Z',
      'updated_at': formatHlc(
        clock.ms - 5000,
        0,
        '0195f2a0-0000-7000-8000-00000000000b',
      ),
      'deleted_at': null,
      'server_version': version,
      'origin_device_id': '0195f2a0-0000-7000-8000-00000000000b',
      'title': 'srv',
      'body': 'srv body',
      'budget': 3,
      ...?extra,
    };

    test(
      'applyPage: строки, receive HLC и курсор в одной транзакции',
      () async {
        final id = uuid7();
        final applied = await store.applyPage([change(serverRow(id))], 7);
        expect(applied, 1);
        expect(await store.cursor(), 7);
        expect((await store.getRow('notes', id))!['title'], 'srv');
        final hlc = await store.hlcState();
        expect(hlc.l, clock.ms); // now > remote: c сбросился, l = now
        // курсор двигается и без строк
        await store.applyPage([], 12);
        expect(await store.cursor(), 12);
      },
    );

    test(
      'сбой БД при применении откатывает страницу и не двигает курсор',
      () async {
        final id = uuid7();
        // `title` NOT NULL: база отвергнет значение.
        final bad = serverRow(id, extra: {'title': null});
        await expectLater(
          store.applyPage([change(serverRow(uuid7())), change(bad)], 9),
          throwsA(isA<Object>()),
        );
        expect(await store.cursor(), 0);
        expect(await d.rows('notes'), isEmpty);
      },
    );

    test(
      'L7: неразборчивый updated_at пропускает строку, страница целая',
      () async {
        final good = uuid7();
        final bad = uuid7();
        final noStamp = uuid7();
        final applied = await store.applyPage([
          change(serverRow(good)),
          change(serverRow(bad, version: 8, extra: {'updated_at': 'garbage'})),
          change(serverRow(noStamp, version: 9, extra: {'updated_at': 7})),
        ], 9);
        expect(applied, 1);
        expect((await d.rows('notes')).keys, [good]);
        expect(await store.cursor(), 9, reason: 'курсор двигается');
        expect(await store.skippedRowCount(), 2);
        expect(await store.lastSkippedRow(), 'notes/$noStamp');
      },
    );

    test('rebase: неотправленное поле поверх серверной строки', () async {
      final id = uuid7();
      await store.applyPage([change(serverRow(id))], 7);
      await store.update('notes', id, {'title': 'mine'});
      await store.applyPage([
        change(
          serverRow(id, version: 8, extra: {'body': 'newer', 'title': 'srv2'}),
        ),
      ], 8);
      final row = (await store.getRow('notes', id))!;
      expect(row['title'], 'mine'); // моя правка поверх
      expect(row['body'], 'newer'); // чужое поле принято
      expect(row['server_version'], 8);
      final op = (await outbox()).single;
      expect(op.baseVersion, 7, reason: 'base_version не меняется при rebase');
    });

    test('rebase: отправленная (in_flight) правка тоже накладывается, '
        'rejected — нет', () async {
      final id = uuid7();
      await store.applyPage([change(serverRow(id))], 7);
      await store.update('notes', id, {'title': 'mine'});
      final batch = await store.takeBatch();
      await store.applyPage([change(serverRow(id, version: 8))], 8);
      expect((await store.getRow('notes', id))!['title'], 'mine');
      await store.applyPushResults(batch, [
        PushOpResult(opId: batch.single.opId, applied: false, code: 'x'),
      ]);
      await store.applyPage([change(serverRow(id, version: 9))], 9);
      expect((await store.getRow('notes', id))!['title'], 'srv');
    });

    test('rebase: неотправленное удаление и восстановление', () async {
      final id = uuid7();
      await store.applyPage([change(serverRow(id))], 7);
      await store.softDelete('notes', id);
      await store.applyPage([change(serverRow(id, version: 8))], 8);
      expect((await store.getRow('notes', id))!['deleted_at'], isNotNull);
    });

    test('неизвестная таблица пропускается, курсор двигается', () async {
      final id = uuid7();
      final applied = await store.applyPage([
        change(serverRow(id), table: 'future_table'),
      ], 5);
      expect(applied, 0);
      expect(await store.cursor(), 5);
    });

    test(
      'колонка, которой нет в ответе сервера, сохраняет локальное значение',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a', 'budget': 42});
        final row = serverRow(id)..remove('budget');
        await store.applyPage([change(row)], 3);
        expect((await store.getRow('notes', id))!['budget'], 42);
      },
    );

    test(
      'новая строка без части колонок вставляется с нейтральными значениями',
      () async {
        final id = uuid7();
        final row = serverRow(id)
          ..remove('title')
          ..remove('created_at');
        await store.applyPage([change(row)], 3);
        final saved = (await store.getRow('notes', id))!;
        expect(saved['title'], '');
      },
    );

    test('applyChange применяет строку без сдвига курсора', () async {
      final id = uuid7();
      await store.applyChange(change(serverRow(id, version: 40)));
      expect(await store.cursor(), 0);
      expect((await store.getRow('notes', id))!['server_version'], 40);
    });

    test(
      'replaceAll: серверные строки, чужие исчезают, outbox сохранён',
      () async {
        final keep = uuid7();
        final gone = uuid7();
        await store.applyPage([
          change(serverRow(keep)),
          change(serverRow(gone, version: 8)),
        ], 8);
        await store.update('notes', keep, {'title': 'mine'});
        await store.setNeedsResync(value: true);
        await store.replaceAll([change(serverRow(keep, version: 20))], 25);
        final rows = await d.rows('notes');
        expect(rows.keys, [keep]);
        expect(rows[keep]!['title'], 'mine');
        expect(rows[keep]!['server_version'], 20);
        expect(await store.cursor(), 25);
        expect(await store.needsResync(), isFalse);
        expect(await outbox(), hasLength(1));
      },
    );

    test('M2: replaceAll возвращает строки, существующие только через '
        'неотправленные создания', () async {
      final onServer = uuid7();
      final localOnly = uuid7();
      final editedGone = uuid7();
      await store.applyPage([
        change(serverRow(onServer)),
        change(serverRow(editedGone, version: 8)),
      ], 8);
      await store.create('notes', localOnly, {'title': 'mine', 'body': 'b'});
      await store.update('notes', localOnly, {'body': 'b2'});
      await store.update('notes', editedGone, {'title': 'edit of vanished'});
      await store.replaceAll([change(serverRow(onServer, version: 20))], 25);
      final rows = await d.rows('notes');
      expect(rows.keys.toSet(), {onServer, localOnly});
      expect(rows[localOnly]!['title'], 'mine');
      expect(rows[localOnly]!['body'], 'b2');
      expect(rows[localOnly]!['server_version'], 0);
      expect(rows[localOnly]!['deleted_at'], isNull);
      expect(rows[localOnly]!['origin_device_id'], d.deviceId);
      // правка строки, которой на сервере нет, не воскрешает её
      expect(rows.containsKey(editedGone), isFalse);
      expect(await outbox(), hasLength(2));
    });

    test('M2: создание + удаление локально созданной строки — надгробие '
        'возвращается', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'x'});
      await store.softDelete('notes', id);
      await store.replaceAll([], 5);
      final row = (await d.rows('notes'))[id]!;
      expect(row['deleted_at'], isNotNull);
      expect((await store.trashItems()).map((i) => i.id), [id]);
    });

    test('purgeOldTombstones: старше 30 суток и без операций', () async {
      final oldId = uuid7();
      final busy = uuid7();
      final fresh = uuid7();
      final old = msIso(clock.ms - const Duration(days: 31).inMilliseconds);
      final recent = msIso(clock.ms - const Duration(days: 5).inMilliseconds);
      await store.applyPage([
        change(serverRow(oldId, extra: {'deleted_at': old})),
        change(serverRow(busy, version: 8, extra: {'deleted_at': old})),
        change(serverRow(fresh, version: 9, extra: {'deleted_at': recent})),
      ], 9);
      await store.restore('notes', busy);
      await store.softDelete('notes', busy);
      expect(await store.purgeOldTombstones(), 1);
      expect((await d.rows('notes')).keys.toSet(), {busy, fresh});
    });
  });

  group('L8: retryRejected и более новые правки', () {
    Future<(String, OutboxOp)> rejectedFirst() async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a', 'body': 'b'});
      final batch = await store.takeBatch();
      await store.applyPushResults(batch, [
        PushOpResult(
          opId: batch.single.opId,
          applied: false,
          code: 'op_failed',
        ),
      ]);
      return (id, (await outbox()).single);
    }

    test('новая правка того же поля не затирается повтором', () async {
      final (id, rejected) = await rejectedFirst();
      await store.update('notes', id, {'title': 'newer'});
      await store.retryRejected(rejected.opId);
      final ops = await outbox();
      final live = ops.where((o) => o.state != OpState.rejected).toList();
      // повтор влил только не пересекающееся поле `body` (+ created_at)
      final merged = <String, Object?>{for (final o in live) ...?o.fields};
      expect(merged['title'], 'newer');
      expect(merged['body'], 'b');
      expect((await store.getRow('notes', id))!['title'], 'newer');
      expect(ops.where((o) => o.opId == rejected.opId), isEmpty);
    });

    test('повтор сливается с более новой неотправленной правкой, а не '
        'создаёт вторую', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'a'});
      final batch = await store.takeBatch();
      await store.applyPushResults(batch, [
        PushOpResult(
          opId: batch.single.opId,
          applied: false,
          code: 'op_failed',
        ),
      ]);
      final rejected = (await outbox()).single;
      await store.update('notes', id, {'title': 'newer'});
      await store.retryRejected(rejected.opId);
      final after = await outbox();
      expect(after, hasLength(1), reason: 'отклонённая снята, повтор слит');
      expect(after.single.fields!['title'], 'newer');
      expect(after.single.fields, contains('created_at'));
    });

    test('после более новой операции delete повтор правки не воскрешает '
        'значения', () async {
      final (id, rejected) = await rejectedFirst();
      await store.softDelete('notes', id);
      await store.retryRejected(rejected.opId);
      final ops = await outbox();
      expect(ops.where((o) => o.opId == rejected.opId), isEmpty);
      expect(ops.where((o) => o.type == OpType.delete), hasLength(1));
      expect(
        ops.where(
          (o) => o.type == OpType.upsert && o.state != OpState.rejected,
        ),
        isEmpty,
      );
    });

    test(
      'отклонённый delete не повторяется, если после него была правка',
      () async {
        final id = uuid7();
        await store.create('notes', id, {'title': 'a'});
        await d.sync(); // создание подтверждено, строка на сервере
        await store.softDelete('notes', id);
        final batch = await store.takeBatch();
        await store.applyPushResults(batch, [
          PushOpResult(
            opId: batch.single.opId,
            applied: false,
            code: 'op_failed',
          ),
        ]);
        final rejected = (await outbox()).single;
        await store.restore('notes', id);
        await store.retryRejected(rejected.opId);
        final ops = await outbox();
        expect(ops.where((o) => o.type == OpType.delete), isEmpty);
        expect(ops.single.fields, {'deleted_at': null});
      },
    );
  });

  group('два изолята: отметка «на переднем плане»', () {
    test('свежая отметка есть, устаревшая и снятая — нет', () async {
      expect(await store.isForegroundActive(), isFalse);
      await store.markForeground();
      expect(await store.isForegroundActive(), isTrue);
      clock.advance(SyncStore.foregroundTtl - const Duration(seconds: 1));
      expect(await store.isForegroundActive(), isTrue);
      clock.advance(const Duration(seconds: 2));
      expect(await store.isForegroundActive(), isFalse);
      await store.markForeground();
      await store.clearForeground();
      expect(await store.isForegroundActive(), isFalse);
    });

    test('L11: индекс sync_outbox(target_table, row_id) создан', () async {
      final rows = await d.db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'sync_outbox'",
          )
          .get();
      expect(
        rows.map((r) => r.data['name']),
        contains('sync_outbox_target_row_idx'),
      );
    });
  });

  group('устройство и метаданные', () {
    test(
      'deviceId: временный до входа, adoptDevice переписывает метки',
      () async {
        final fresh = TestDevice.create(server, clock: clock);
        final dev = await fresh;
        final id = uuid7();
        await dev.store.create('notes', id, {'title': 'a'});
        final before = (await dev.store.outbox()).single.hlc;
        expect(hlcDevice(before), dev.deviceId);
        final newDevice = uuid7();
        await dev.store.adoptDevice(newDevice);
        expect(await dev.store.deviceId(), newDevice);
        final after = (await dev.store.outbox()).single.hlc;
        expect(hlcDevice(after), newDevice);
        expect(after.substring(0, 21), before.substring(0, 21));
        final row = (await dev.store.getRow('notes', id))!;
        expect(hlcDevice(row['updated_at']! as String), newDevice);
        expect(row['origin_device_id'], newDevice);
        // повторный вход с тем же устройством ничего не ломает
        await dev.store.adoptDevice(newDevice);
        await dev.close();
      },
    );

    test('deviceId создаётся лениво и стабилен', () async {
      final fresh = SyncStore(db: d.db, registry: store.registry);
      await d.db.customUpdate("DELETE FROM sync_meta WHERE key = 'device_id'");
      final first = await fresh.deviceId();
      expect(isUuid7(first), isTrue);
      expect(await fresh.deviceId(), first);
    });

    test(
      'reconcileKnownTables: новая таблица требует пересинхронизации',
      () async {
        await store.reconcileKnownTables();
        expect(await store.needsResync(), isFalse);
        await store.writeMeta(SyncMetaKeys.cursor, '10');
        await store.writeMeta(SyncMetaKeys.knownTables, 'user_settings');
        await store.reconcileKnownTables();
        expect(await store.needsResync(), isTrue);
        await store.setNeedsResync(value: false);
        await store.reconcileKnownTables();
        expect(await store.needsResync(), isFalse);
      },
    );

    test('первый запуск не требует пересинхронизации', () async {
      await d.db.customUpdate(
        "DELETE FROM sync_meta WHERE key = 'known_tables'",
      );
      await store.reconcileKnownTables();
      expect(await store.needsResync(), isFalse);
    });

    test('blockedMinSchema и метки времени сохраняются', () async {
      expect(await store.blockedMinSchema(), isNull);
      await store.setBlockedMinSchema(3);
      expect(await store.blockedMinSchema(), 3);
      await store.setBlockedMinSchema(null);
      expect(await store.blockedMinSchema(), isNull);
      expect(await store.lastPushAt(), isNull);
      await store.markPush();
      await store.markPull();
      await store.markSuccess();
      expect((await store.lastPushAt())!.millisecondsSinceEpoch, clock.ms);
      expect((await store.lastPullAt())!.millisecondsSinceEpoch, clock.ms);
      expect((await store.lastSuccessAt())!.millisecondsSinceEpoch, clock.ms);
    });
  });

  group('видимость и корзина (spec 3.5, 3.8)', () {
    Future<(String, String)> projectWithTask() async {
      final p = uuid7();
      final t = uuid7();
      await store.create('projects', p, {'name': 'P'});
      await store.create('tasks', t, {'title': 'T', 'project_id': p});
      return (p, t);
    }

    test('visibleRows: удалённый родитель скрывает потомков', () async {
      final (p, t) = await projectWithTask();
      expect((await store.visibleRows('tasks')).map((r) => r['id']), [t]);
      await store.softDelete('projects', p);
      expect(await store.visibleRows('tasks'), isEmpty);
      expect(await store.visibleRows('projects'), isEmpty);
      await store.restore('projects', p);
      expect(await store.visibleRows('tasks'), hasLength(1));
    });

    test('visibleRows: условие, сортировка и задача без родителя', () async {
      final free = uuid7();
      await store.create('tasks', free, {'title': 'free'});
      await store.create('tasks', uuid7(), {'title': 'other'});
      final rows = await store.visibleRows(
        'tasks',
        where: 't.title = ?',
        args: ['free'],
        orderBy: 't.title',
      );
      expect(rows.map((r) => r['id']), [free]);
    });

    test('watchVisibleRows обновляется при правках', () async {
      final seen = <int>[];
      final sub = store
          .watchVisibleRows('user_settings')
          .listen((r) => seen.add(r.length));
      await pumpEventQueue();
      final id = userSettingsId('a');
      await store.create('user_settings', id, {'key': 'a', 'value': 1});
      await pumpEventQueue();
      await store.softDelete('user_settings', id);
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.first, 0);
      expect(seen, contains(1));
      expect(seen.last, 0);
    });

    test('watchRow отдаёт строку', () async {
      final id = userSettingsId('a');
      final seen = <Json?>[];
      final sub = store.watchRow('user_settings', id).listen(seen.add);
      await pumpEventQueue();
      await store.create('user_settings', id, {'key': 'a', 'value': 1});
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.first, isNull);
      expect(seen.last!['value'], 1);
    });

    test('корзина показывает только корневые удалённые строки', () async {
      final (p, t) = await projectWithTask();
      await store.softDelete('projects', p);
      // потомок удалён каскадом (как приходит с сервера)
      await store.softDelete('tasks', t);
      final items = await store.trashItems();
      expect(items.map((i) => (i.table, i.id)), [('projects', p)]);
      expect(items.single.label, 'Проект');
      expect(items.single.title, 'P');
      expect(items.single.daysLeft, 30);
    });

    test(
      'удалённая задача живого проекта — в корзине; дни до удаления',
      () async {
        final (_, t) = await projectWithTask();
        await store.softDelete('tasks', t);
        await d.sync(); // срок считается от приёма удаления сервером
        clock.advance(const Duration(days: 10, hours: 3));
        var items = await store.trashItems();
        expect(items.single.id, t);
        // осталось 19 суток 21 час: округляется вверх (L2)
        expect(items.single.daysLeft, 20);
        clock.advance(const Duration(days: 20));
        items = await store.trashItems();
        expect(
          items,
          isEmpty,
          reason: 'старше 30 дней в корзине не показывается',
        );
      },
    );

    test(
      'L2: дни до удаления округляются вверх, последние часы — 1 день',
      () async {
        final (_, t) = await projectWithTask();
        await store.softDelete('tasks', t);
        await d.sync();
        clock.advance(const Duration(days: 29, hours: 23));
        expect((await store.trashItems()).single.daysLeft, 1);
        clock.advance(const Duration(minutes: 59));
        expect((await store.trashItems()).single.daysLeft, 1);
        clock.advance(const Duration(minutes: 2));
        expect(await store.trashItems(), isEmpty);
      },
    );

    test('L3: строка с неотправленным удалением остаётся в корзине и не '
        'очищается, пока удаление не дошло до сервера', () async {
      final id = uuid7();
      await store.create('notes', id, {'title': 'n'});
      await store.softDelete('notes', id);
      // устройство 35 суток без сети: локальный deleted_at «протух»
      clock.advance(const Duration(days: 35));
      final items = await store.trashItems();
      expect(items.map((i) => i.id), [id]);
      expect(items.single.daysLeft, 30, reason: 'срок — от приёма сервером');
      expect(await store.purgeOldTombstones(), 0);
      expect((await d.rows('notes')).keys, [id]);
      // после синхронизации сервер ставит deleted_at = приём (сегодня)
      expect(await d.sync(), isNotNull);
      expect((await store.trashItems()).map((i) => i.id), [id]);
    });

    test('корзина не делает запрос на каждую строку: много строк и '
        'удалённые родители', () async {
      final p = uuid7();
      await store.create('projects', p, {'name': 'P'});
      for (var i = 0; i < 40; i++) {
        await store.create('tasks', uuid7(), {'title': 't$i', 'project_id': p});
      }
      await store.softDelete('projects', p);
      for (final row in (await d.rows('tasks')).values) {
        await store.softDelete('tasks', row['id']! as String);
      }
      final items = await store.trashItems();
      expect(items.map((i) => i.table), ['projects'], reason: 'потомки скрыты');
    });

    test('watchTrash отдаёт актуальный список', () async {
      final id = uuid7();
      await store.create('user_settings', userSettingsId('a'), {
        'key': 'a',
        'value': 1,
      });
      final lists = <List<TrashItem>>[];
      final sub = store.watchTrash().listen(lists.add);
      await pumpEventQueue();
      await store.softDelete('user_settings', userSettingsId('a'));
      await pumpEventQueue();
      await sub.cancel();
      expect(lists.first, isEmpty);
      expect(lists.last.single.title, 'a');
      expect(id, isNotEmpty);
    });
  });

  group('эпоха сервера', () {
    test('observeEpoch: запомнить, ничего, полная пересинхронизация', () async {
      expect(await store.observeEpoch(null), EpochAction.none);
      expect(await store.observeEpoch('e1'), EpochAction.store);
      expect(await store.serverEpoch(), 'e1');
      expect(await store.observeEpoch('e1'), EpochAction.none);
      expect(await store.needsResync(), isFalse);
      expect(await store.observeEpoch('e2'), EpochAction.fullResync);
      expect(await store.needsResync(), isTrue);
      expect(await store.serverEpoch(), 'e1', reason: 'новая — после resync');
    });
  });

  group('реестр', () {
    test('SyncRegistry проверяет дубли и родителей', () {
      expect(() => SyncRegistry([notesSpec, notesSpec]), throwsArgumentError);
      expect(() => SyncRegistry([tasksSpec]), throwsArgumentError);
      final r = SyncRegistry([projectsSpec, tasksSpec]);
      expect(r.names, ['projects', 'tasks']);
      expect(r.contains('tasks'), isTrue);
      expect(r.maybeSpec('x'), isNull);
      expect(() => r.spec('x'), throwsArgumentError);
      expect(r.spec('tasks').column('title')!.type, SyncColumnType.text);
      expect(r.spec('tasks').column('zzz'), isNull);
      expect(r.spec('tasks').columnNames, {
        'title',
        'project_id',
        'done',
        'meta',
      });
    });

    test('SyncColumn: преобразования значений', () {
      const json = SyncColumn('m', SyncColumnType.json);
      expect(json.toDb(null), 'null');
      expect(json.fromDb('null'), isNull);
      expect(json.toDb({'a': 1}), '{"a":1}');
      const nullableJson = SyncColumn('m', SyncColumnType.json, nullable: true);
      expect(nullableJson.toDb(null), isNull);
      const flag = SyncColumn('f', SyncColumnType.boolean);
      expect(flag.toDb(true), 1);
      expect(flag.fromDb(1), isTrue);
      expect(flag.fromDb(0), isFalse);
      expect(flag.fromDb(null), isNull);
      expect(const SyncColumn('i', SyncColumnType.integer).fromDb(5), 5);
    });

    test('rowFromDb отдаёт только известные колонки', () {
      final row = notesSpec.rowFromDb({'id': 'x', 'title': 'a', 'junk': 1});
      expect(row, {'id': 'x', 'title': 'a'});
    });
  });

  test(
    'запрос к несуществующей таблице Drift не падает (тестовые таблицы)',
    () async {
      await d.db.customStatement('CREATE TABLE raw_t (id TEXT PRIMARY KEY)');
      final rows = await d.db.customSelect('SELECT 1 AS x').get();
      expect(rows, hasLength(1));
    },
  );
}
