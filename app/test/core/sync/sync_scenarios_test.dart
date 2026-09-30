import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';

import '../../support/fake_server/fake_sync_server.dart';
import '../../support/fake_server/server_remote.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';

void main() {
  late FakeSyncServer server;
  late ManualClock clock;

  setUp(() {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
  });
  tearDown(() => server.dispose());

  test('телефон офлайн 3 дня, ПК онлайн, потом встреча', () async {
    final phone = await TestDevice.create(server, clock: clock);
    final pc = await TestDevice.create(server, clock: clock);
    final n1 = uuid7();
    final n3 = uuid7();
    await phone.store.create('notes', n1, {
      'title': 't0',
      'body': 'b0',
      'budget': 1,
    });
    await phone.store.create('notes', n3, {'title': 'three'});
    await phone.sync();
    await pc.sync();

    // Телефон в режиме полёта.
    phone.remote.faults.offline = true;
    clock.advance(const Duration(hours: 1));
    await phone.store.update('notes', n1, {'title': 'phone title'});
    await phone.store.update('notes', n1, {'budget': 5});
    final n2 = uuid7();
    await phone.store.create('notes', n2, {'title': 'phone new'});
    await phone.store.softDelete('notes', n3);
    expect(await phone.sync(), SyncOutcome.offline);
    expect(await phone.store.outbox(), isNotEmpty);

    // ПК работает и синхронизируется.
    clock.advance(const Duration(hours: 23));
    await pc.store.update('notes', n1, {'title': 'pc title'});
    await pc.sync();
    clock.advance(const Duration(hours: 6));
    await pc.store.update('notes', n1, {'body': 'pc body'});
    await pc.sync();
    clock.advance(const Duration(hours: 18));
    await pc.store.update('notes', n3, {'title': 'pc edit of deleted'});
    final n4 = uuid7();
    await pc.store.create('notes', n4, {'title': 'pc new'});
    await pc.sync();

    // Через 3 дня телефон снова в сети.
    clock.advance(const Duration(hours: 24));
    phone.remote.faults.offline = false;
    expect(await phone.sync(), SyncOutcome.success);
    expect(await pc.sync(), SyncOutcome.success);
    expect(await phone.sync(), SyncOutcome.success);

    final serverNotes = server.snapshot('notes');
    expect(serverNotes.keys.toSet(), {n1, n2, n3, n4});
    expect(serverNotes[n1]!['title'], 'pc title', reason: 'правка ПК новее');
    expect(
      serverNotes[n1]!['budget'],
      5,
      reason: 'поле телефона не конфликтовало',
    );
    expect(serverNotes[n1]!['body'], 'pc body');
    expect(
      serverNotes[n3]!['deleted_at'],
      isNull,
      reason: 'правка новее удаления',
    );
    expect(serverNotes[n3]!['title'], 'pc edit of deleted');
    // Ничего не потеряно молча: оба проигравших значения в журнале.
    final kinds = {for (final c in server.conflicts) c.kind: c};
    expect(kinds.keys.toSet(), {'field', 'resurrected'});
    expect(kinds['field']!.losingValue, 'phone title');
    expect(await phone.rows('notes'), serverNotes);
    expect(await pc.rows('notes'), serverNotes);
    expect(await phone.store.outbox(), isEmpty);
    await phone.close();
    await pc.close();
  });

  test(
    'три устройства, потерянные ответы и повторы: одна и та же строка',
    () async {
      final devices = [
        for (var i = 0; i < 3; i++)
          await TestDevice.create(server, clock: clock),
      ];
      final id = uuid7();
      await devices[0].store.create('notes', id, {'title': 'v0'});
      await devices[0].sync();
      for (final d in devices) {
        await d.sync();
      }
      for (var round = 0; round < 5; round++) {
        for (final (i, d) in devices.indexed) {
          clock.advance(const Duration(seconds: 1));
          await d.store.update('notes', id, {'budget': round * 10 + i});
          d.remote.faults.scripted.add(
            round.isEven ? Fault.dropResponse : Fault.dropRequest,
          );
          await d.sync();
        }
      }
      for (var i = 0; i < 3; i++) {
        for (final d in devices) {
          await d.sync();
        }
      }
      final expected = server.snapshot('notes')[id]!;
      for (final d in devices) {
        expect((await d.rows('notes'))[id], expected);
        expect(await d.store.outbox(), isEmpty);
      }
      // 15 правок, ни одна не применена дважды
      expect(server.processedOps, 16);
      for (final d in devices) {
        await d.close();
      }
    },
  );

  test('restore из корзины и каскад родитель-потомок', () async {
    final a = await TestDevice.create(server, clock: clock);
    final b = await TestDevice.create(server, clock: clock);
    final p = uuid7();
    final t1 = uuid7();
    final t2 = uuid7();
    await a.store.create('projects', p, {'name': 'P'});
    await a.store.create('tasks', t1, {'title': 'one', 'project_id': p});
    await a.store.create('tasks', t2, {'title': 'two', 'project_id': p});
    await a.sync();
    await b.sync();
    // Клиент шлёт одну операцию delete для родителя; потомки — каскадом.
    await a.store.softDelete('projects', p);
    expect((await a.store.outbox()).where((o) => o.table == 'tasks'), isEmpty);
    expect(await a.store.visibleRows('tasks'), isEmpty);
    await a.sync();
    await b.sync();
    expect(await b.store.visibleRows('tasks'), isEmpty);
    final trash = await b.store.trashItems();
    expect(trash.map((i) => i.id), [p], reason: 'потомки скрыты, корень один');
    // Восстановление родителя возвращает потомков этого же каскада.
    await b.store.restore('projects', p);
    await b.sync();
    await a.sync();
    expect((await a.store.visibleRows('tasks')).map((r) => r['id']).toSet(), {
      t1,
      t2,
    });
    expect(await a.store.trashItems(), isEmpty);
    await a.close();
    await b.close();
  });

  test('«вернуть моё» для удаления против правки и полей', () async {
    final a = await TestDevice.create(server, clock: clock);
    final b = await TestDevice.create(server, clock: clock);
    final id = uuid7();
    await a.store.create('notes', id, {'title': 'base'});
    await a.sync();
    await b.sync();
    // a удаляет, b (не видя удаления) правит позже: правка побеждает.
    await a.store.softDelete('notes', id);
    clock.advance(const Duration(seconds: 3));
    await b.store.update('notes', id, {'title': 'kept'});
    await a.sync();
    await b.sync();
    await a.sync();
    expect(server.row('notes', id)!['deleted_at'], isNull);
    final conflict = (await a.remote.conflicts()).conflicts.single;
    expect(conflict.kind, ConflictKind.resurrected);
    // a возвращает своё удаление
    final reverted = await a.remote.revert(conflict.id);
    await a.store.applyChange(reverted.change);
    await a.sync();
    await b.sync();
    expect((await b.store.getRow('notes', id))!['deleted_at'], isNotNull);
    await a.close();
    await b.close();
  });
}
