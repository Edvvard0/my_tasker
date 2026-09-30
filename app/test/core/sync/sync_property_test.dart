import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';

import '../../support/fake_server/fake_sync_server.dart';
import '../../support/fake_server/server_remote.dart';
import '../../support/manual_clock.dart';
import '../../support/sync_env.dart';

/// Число случайных прогонов (`SYNC_PROPERTY_SEEDS=400` — «тщательный» режим).
final int _seeds =
    int.tryParse(Platform.environment['SYNC_PROPERTY_SEEDS'] ?? '') ?? 40;

const _titles = ['a', 'b', 'c', 'd'];

class _World {
  _World(this.seed) : rng = Random(seed) {
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
  }

  final int seed;
  final Random rng;
  final ManualClock clock = ManualClock();
  late final FakeSyncServer server;
  final List<TestDevice> devices = [];

  Future<void> setUp() async {
    final count = 2 + rng.nextInt(2);
    for (var i = 0; i < count; i++) {
      // Часы устройств расходятся: от -1 ч до +5 мин (порог сервера — 10 мин).
      final skew = rng.nextInt(3600000 + 300000) - 3600000;
      devices.add(
        await TestDevice.create(
          server,
          clock: _SkewedClock(clock, skew).asManual(),
          faults: FaultPlan(
            random: Random(seed * 31 + i),
            pDropRequest: 0.08,
            pDropResponse: 0.08,
          ),
        ),
      );
    }
    // Все начинают с одних и тех же двух проектов и двух задач.
    final first = devices.first;
    for (final title in ['a', 'b']) {
      final project = uuid7();
      await first.store.create('projects', project, {'name': title});
      await first.store.create('tasks', uuid7(), {
        'title': title,
        'project_id': project,
      });
    }
    await settle();
  }

  Future<void> tearDown() async {
    for (final d in devices) {
      await d.close();
    }
    await server.dispose();
  }

  void _syncClocks() {
    for (final d in devices) {
      (d.clock as _ManualView).refresh();
    }
  }

  Future<void> step() async {
    _syncClocks();
    final d = devices[rng.nextInt(devices.length)];
    final roll = rng.nextInt(20);
    if (roll < 7) {
      await _edit(d);
    } else if (roll < 9) {
      await _toggle(d, delete: true);
    } else if (roll < 11) {
      await _toggle(d, delete: false);
    } else if (roll < 13) {
      await _create(d);
    } else if (roll < 18) {
      await d.sync();
    } else {
      clock.advance(Duration(milliseconds: 1 + rng.nextInt(3000)));
    }
  }

  Future<List<(String, String)>> _keys(
    TestDevice d, {
    required bool alive,
  }) async {
    final keys = <(String, String)>[];
    for (final table in ['notes', 'projects', 'tasks']) {
      final rows = await d.rows(table);
      for (final r in rows.values) {
        if ((r['deleted_at'] == null) == alive) {
          keys.add((table, r['id']! as String));
        }
      }
    }
    keys.sort((a, b) => '${a.$1}${a.$2}'.compareTo('${b.$1}${b.$2}'));
    return keys;
  }

  Future<void> _edit(TestDevice d) async {
    final keys = await _keys(d, alive: true);
    if (keys.isEmpty) return;
    final (table, id) = keys[rng.nextInt(keys.length)];
    final value = _titles[rng.nextInt(_titles.length)];
    final Map<String, Object?> fields;
    switch (table) {
      case 'notes':
        fields = [
          {'title': value},
          {'body': value},
          {'budget': rng.nextInt(4)},
        ][rng.nextInt(3)];
      case 'projects':
        fields = {'name': value};
      default:
        fields = [
          {'title': value},
          {'done': rng.nextBool()},
        ][rng.nextInt(2)];
    }
    await d.store.update(table, id, fields);
  }

  Future<void> _toggle(TestDevice d, {required bool delete}) async {
    final keys = await _keys(d, alive: delete);
    if (keys.isEmpty) return;
    final (table, id) = keys[rng.nextInt(keys.length)];
    if (delete) {
      await d.store.softDelete(table, id);
    } else {
      await d.store.restore(table, id);
    }
  }

  Future<void> _create(TestDevice d) async {
    final kind = rng.nextInt(3);
    if (kind == 0) {
      await d.store.create('notes', uuid7(), {
        'title': _titles[rng.nextInt(4)],
      });
    } else if (kind == 1) {
      await d.store.create('projects', uuid7(), {
        'name': _titles[rng.nextInt(4)],
      });
    } else {
      final parents = (await _keys(
        d,
        alive: true,
      )).where((k) => k.$1 == 'projects').toList();
      if (parents.isEmpty) return;
      await d.store.create('tasks', uuid7(), {
        'title': _titles[rng.nextInt(4)],
        'project_id': parents[rng.nextInt(parents.length)].$2,
      });
    }
  }

  /// Каждое устройство синхронизируется без отказов, пока всё не устаканится.
  Future<void> settle() async {
    _syncClocks();
    for (final d in devices) {
      d.remote.faults.offline = false;
    }
    final saved = [for (final d in devices) d.remote.faults.pDropRequest];
    expect(saved, isNotEmpty);
    for (var round = 0; round < 8; round++) {
      for (final d in devices) {
        final plan = d.remote.faults;
        // Без отказов на время «встречи».
        plan.scripted.clear();
        final r = await _quiet(d);
        expect(r, isNot(SyncOutcome.failed));
      }
      var settled = true;
      for (final d in devices) {
        if ((await d.store.outbox()).isNotEmpty ||
            await d.store.cursor() != server.head) {
          settled = false;
        }
      }
      if (settled) return;
    }
    fail('устройства не сошлись (seed $seed)');
  }

  Future<SyncOutcome> _quiet(TestDevice d) async {
    final plan = d.remote.faults;
    final quiet = FaultPlan();
    // Подменяем отказы на пустой сценарий на время цикла.
    final backupRequests = plan.requests;
    final result = await _withoutFaults(d, quiet);
    expect(plan.requests, backupRequests);
    return result;
  }

  Future<SyncOutcome> _withoutFaults(TestDevice d, FaultPlan quiet) async {
    final quietRemote = DirectRemote(server, d.deviceId, faults: quiet);
    final engine = SyncEngine(
      store: d.store,
      remote: quietRemote,
      clientSchemaVersion: 1,
      clock: () => d.clock.now,
    );
    final outcome = await engine.runCycle();
    await engine.dispose();
    return outcome;
  }

  // ---- проверки ------------------------------------------------------------

  Future<void> check() async {
    for (final table in ['notes', 'projects', 'tasks']) {
      final expected = server.snapshot(table);
      for (final (i, d) in devices.indexed) {
        expect(
          await d.rows(table),
          expected,
          reason: 'seed $seed: устройство $i, $table',
        );
      }
    }
    for (final (i, d) in devices.indexed) {
      final rejected = (await d.store.outbox()).where(
        (o) => o.state == OpState.rejected,
      );
      expect(rejected, isEmpty, reason: 'seed $seed: устройство $i');
    }
    _cascadeInvariant();
    _lastWriterWins();
    _noSilentLoss();
    _conflictsAreBetweenDevices();
    _untouchedRowsAreAlive();
  }

  void _cascadeInvariant() {
    final projects = server.snapshot('projects');
    for (final task in server.snapshot('tasks').values) {
      if (task['deleted_at'] == null) {
        expect(
          projects[task['project_id']]!['deleted_at'],
          isNull,
          reason: 'seed $seed: живая задача под удалённым проектом',
        );
      }
    }
  }

  Iterable<({Json op, Json result})> get _applied sync* {
    for (final e in server.processedBodies.entries) {
      final result = server.resultOf(e.key);
      if (result != null &&
          result['status'] == 'applied' &&
          e.value['type'] == 'upsert') {
        yield (op: e.value, result: result);
      }
    }
  }

  static const _service = {'created_at', 'deleted_at'};

  void _lastWriterWins() {
    final newest = <(String, String, String), (String, Object?)>{};
    for (final (:op, result: _) in _applied) {
      for (final f in (op['fields']! as Map).entries) {
        if (_service.contains(f.key)) continue;
        final key = (
          op['table']! as String,
          op['id']! as String,
          f.key as String,
        );
        final hlc = op['hlc']! as String;
        if (!newest.containsKey(key) || hlc.compareTo(newest[key]!.$1) > 0) {
          newest[key] = (hlc, f.value);
        }
      }
    }
    for (final e in newest.entries) {
      final (table, id, field) = e.key;
      expect(
        server.row(table, id)![field],
        e.value.$2,
        reason: 'seed $seed: $table.$field не хранит самую новую запись',
      );
    }
  }

  String _canon(Object? v) => jsonEncodeSorted(v);

  void _noSilentLoss() {
    final logged = {
      for (final c in server.conflicts)
        (c.table, c.rowId, c.field, _canon(c.losingValue)),
    };
    final applied = _applied.toList();
    for (final (:op, :result) in applied) {
      final table = op['table']! as String;
      final id = op['id']! as String;
      for (final f in (op['fields']! as Map).entries) {
        final name = f.key as String;
        if (_service.contains(name)) continue;
        if (_same(server.row(table, id)![name], f.value)) continue;
        var justified = logged.contains((table, id, name, _canon(f.value)));
        final hlc = op['hlc']! as String;
        final device = hlcDevice(hlc);
        for (final (op: other, result: _) in applied) {
          if (justified) break;
          if (other['table'] != table || other['id'] != id) continue;
          final fields = other['fields']! as Map;
          final otherHlc = other['hlc']! as String;
          if (!fields.containsKey(name) || otherHlc.compareTo(hlc) <= 0) {
            continue;
          }
          // То же значение записано позже: оно не потеряно (судьбу той записи
          // проверяет этот же цикл).
          if (_same(fields[name], f.value)) {
            justified = true;
            continue;
          }
          if (hlcDevice(otherHlc) == device ||
              (other['base_version']! as int) >=
                  ((result['server_version'] as int?) ?? 0)) {
            justified = true;
          }
        }
        expect(
          justified,
          isTrue,
          reason:
              'seed $seed: значение ${f.value} у $table.$name молча затёрто',
        );
      }
    }
  }

  bool _same(Object? a, Object? b) =>
      a.runtimeType == b.runtimeType && _canon(a) == _canon(b);

  void _conflictsAreBetweenDevices() {
    for (final c in server.conflicts) {
      if (c.kind == 'field') {
        expect(c.losingDevice, isNot(c.winningDevice), reason: 'seed $seed');
      }
    }
  }

  void _untouchedRowsAreAlive() {
    final deleted = {
      for (final op in server.processedBodies.values)
        if (op['type'] == 'delete') (op['table'], op['id']),
    };
    for (final table in ['notes', 'projects', 'tasks']) {
      for (final row in server.snapshot(table).values) {
        final parentDeleted =
            table == 'tasks' &&
            deleted.contains(('projects', row['project_id']));
        if (!deleted.contains((table, row['id'])) && !parentDeleted) {
          expect(
            row['deleted_at'],
            isNull,
            reason: 'seed $seed: $table ${row['id']} удалена сама',
          );
        }
      }
    }
  }
}

/// Часы устройства = общее время + сдвиг.
class _SkewedClock {
  _SkewedClock(this.base, this.skew);

  final ManualClock base;
  final int skew;

  ManualClock asManual() => _ManualView(base, skew);
}

class _ManualView extends ManualClock {
  _ManualView(this.base, this.skew) : super(base.ms + skew);

  final ManualClock base;
  final int skew;

  void refresh() => ms = base.ms + skew;
}

void main() {
  test(
    'сходимость и отсутствие молчаливых потерь на случайных сценариях',
    () async {
      var conflicts = 0;
      final kinds = <String>{};
      for (var seed = 1; seed <= _seeds; seed++) {
        final world = _World(seed);
        await world.setUp();
        final steps = 25 + world.rng.nextInt(45);
        for (var i = 0; i < steps; i++) {
          await world.step();
        }
        await world.settle();
        await world.check();
        conflicts += world.server.conflicts.length;
        kinds.addAll(world.server.conflicts.map((c) => c.kind));
        await world.tearDown();
      }
      // Прогоны действительно порождают конфликты разных видов.
      expect(conflicts, greaterThan(0));
      expect(kinds, contains('field'));
    },
  );
}
