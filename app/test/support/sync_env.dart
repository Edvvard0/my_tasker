import 'package:drift/native.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

import 'fake_server/fake_sync_server.dart';
import 'fake_server/server_remote.dart';
import 'manual_clock.dart';

/// Заметка: прикладная таблица для тестов движка (несколько полей —
/// слияние по полям).
const SyncTableSpec notesSpec = SyncTableSpec(
  name: 'notes',
  label: 'Заметка',
  columns: [
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('body', SyncColumnType.text, nullable: true),
    SyncColumn('budget', SyncColumnType.integer, nullable: true),
  ],
  titleOf: _title,
);

const SyncTableSpec projectsSpec = SyncTableSpec(
  name: 'projects',
  label: 'Проект',
  columns: [SyncColumn('name', SyncColumnType.text)],
  titleOf: _name,
);

const SyncTableSpec tasksSpec = SyncTableSpec(
  name: 'tasks',
  label: 'Задача',
  columns: [
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('project_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('done', SyncColumnType.boolean, nullable: true),
    SyncColumn('meta', SyncColumnType.json, nullable: true),
  ],
  parents: [SyncRelation('project_id', 'projects')],
  titleOf: _title,
);

String _title(Json row) => '${row['title']}';
String _name(Json row) => '${row['name']}';

/// Реестр тестов: `user_settings` + прикладные таблицы выше.
SyncRegistry testRegistry() =>
    SyncRegistry([userSettingsSpec, notesSpec, projectsSpec, tasksSpec]);

const String _service =
    'id TEXT PRIMARY KEY NOT NULL, created_at TEXT NOT NULL, '
    'updated_at TEXT NOT NULL, deleted_at TEXT, '
    'server_version INTEGER NOT NULL DEFAULT 0, origin_device_id TEXT';

/// Создаёт таблицы реестра, которых нет в схеме `AppDatabase`
/// (всё, кроме `user_settings`), по описаниям колонок.
Future<void> createTestTables(AppDatabase db, SyncRegistry registry) async {
  final real = {for (final t in db.allTables) t.actualTableName: t};
  for (final spec in registry.specs) {
    if (spec.name == 'user_settings') continue;
    // Этап 2: настоящие таблицы (`tasks`, `projects`...) уже есть в схеме.
    // Совпадают по колонкам — используем их; иначе (тестовые `tasks` и
    // `projects` Этапа 1 с другими колонками) заменяем тестовой таблицей.
    final existing = real[spec.name];
    if (existing != null) {
      final columns = {for (final c in existing.$columns) c.name};
      final wanted = {...syncServiceColumns, ...spec.columnNames};
      if (columns.length == wanted.length && columns.containsAll(wanted)) {
        continue;
      }
      await db.customStatement('DROP TABLE ${spec.name}');
    }
    final columns = [
      for (final c in spec.columns)
        '${c.name} ${switch (c.type) {
          SyncColumnType.integer || SyncColumnType.boolean => 'INTEGER',
          _ => 'TEXT',
        }}${c.nullable ? '' : ' NOT NULL'}',
    ];
    await db.customStatement(
      'CREATE TABLE ${spec.name} ($_service, ${columns.join(', ')})',
    );
  }
}

/// Устройство в тесте: своя БД в памяти, HLC, outbox и движок поверх
/// [DirectRemote] с отказами сети.
class TestDevice {
  TestDevice._({
    required this.db,
    required this.store,
    required this.engine,
    required this.remote,
    required this.clock,
    required this.deviceId,
  });

  static Future<TestDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    FaultPlan? faults,
    String? deviceId,
    SyncRegistry? registry,
    int pullPageSize = 1000,
    int pushBatchSize = 500,
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    await createTestTables(db, registry ?? server.registry);
    final id = deviceId ?? uuid7();
    final ownClock = clock ?? ManualClock();
    final store = SyncStore(
      db: db,
      registry: registry ?? server.registry,
      nowMs: ownClock.call,
    );
    await store.adoptDevice(id);
    final remote = DirectRemote(server, id, faults: faults);
    final engine = SyncEngine(
      store: store,
      remote: remote,
      clientSchemaVersion: 1,
      clock: () => ownClock.now,
      pullPageSize: pullPageSize,
      pushBatchSize: pushBatchSize,
    );
    await engine.init();
    return TestDevice._(
      db: db,
      store: store,
      engine: engine,
      remote: remote,
      clock: ownClock,
      deviceId: id,
    );
  }

  final AppDatabase db;
  final SyncStore store;
  final SyncEngine engine;
  final DirectRemote remote;
  final ManualClock clock;
  final String deviceId;

  Future<SyncOutcome> sync() => engine.runCycle();

  /// Все строки таблицы (включая надгробия) по `id`.
  Future<Map<String, Json>> rows(String table) async {
    final spec = store.registry.spec(table);
    final result = await db.customSelect('SELECT * FROM "$table"').get();
    return {
      for (final r in result) r.data['id']! as String: spec.rowFromDb(r.data),
    };
  }

  Future<void> close() async {
    await engine.dispose();
    await store.dispose();
    await db.close();
  }
}
