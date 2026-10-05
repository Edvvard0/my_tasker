import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import '../../core/database_test.dart' show monitoringTables;

/// Схема v10 (Серверы): миграция v9 -> v10 на файловой БД.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('monitoring_db_test');
    file = File('${dir.path}/monitoring.sqlite');
  });
  tearDown(() => dir.delete(recursive: true));

  const service = [
    'id',
    'created_at',
    'updated_at',
    'deleted_at',
    'server_version',
    'origin_device_id',
  ];
  const columns = {
    'monitor_servers': ['name', 'host', 'provider', 'note'],
    'monitor_services': [
      'server_id',
      'name',
      'work_project_id',
      'critical',
      'note',
    ],
    'monitor_checks': [
      'service_id',
      'kind',
      'name',
      'url',
      'host',
      'port',
      'dns_record_type',
      'expected_value',
      'expected_status',
      'keyword',
      'ssl_min_days',
      'interval_seconds',
      'timeout_seconds',
    ],
  };

  test('миграция v9 -> v10: три таблицы и индексы, прежние данные целы, '
      'новые таблицы пишутся и читаются', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();
    // Настоящая БД v9: без таблиц Серверов, с данными прежних этапов.
    final raw = sqlite3.open(file.path);
    for (final t in monitoringTables) {
      raw.execute('DROP TABLE $t');
    }
    raw
      ..execute("INSERT INTO local_settings VALUES ('server_url', 'https://x')")
      ..execute(
        'INSERT INTO sleep_entries (id, created_at, updated_at, date, bed_at, '
        'wake_at, wake_tz, source) VALUES '
        "('s1', 'c', 'u', '2026-10-05', '2026-10-04T20:30:00Z', "
        "'2026-10-05T04:10:00Z', 'Europe/Moscow', 'manual')",
      )
      ..execute('PRAGMA user_version = 9')
      ..close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await LocalSettingsRepository(db).read('server_url'), 'https://x');
    final sleep = await db
        .customSelect('SELECT date FROM sleep_entries')
        .getSingle();
    expect(sleep.read<String>('date'), '2026-10-05');
    final names = await db
        .customSelect('SELECT name FROM sqlite_master')
        .get()
        .then((rows) => rows.map((r) => r.read<String>('name')).toSet());
    expect(
      names,
      containsAll([
        ...monitoringTables,
        'monitor_services_server_idx',
        'monitor_checks_service_idx',
      ]),
    );
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), AppDatabase.currentSchemaVersion);
    expect(AppDatabase.currentSchemaVersion, 10);

    for (final entry in columns.entries) {
      final cols = await db
          .customSelect('PRAGMA table_info(${entry.key})')
          .get();
      expect(
        cols.map((r) => r.read<String>('name')),
        containsAll([...service, ...entry.value]),
        reason: entry.key,
      );
    }

    await db.customStatement(
      'INSERT INTO monitor_servers (id, created_at, updated_at, name, host) '
      "VALUES ('sv1', 'c', 'u', 'VPS', 'example.com')",
    );
    await db.customStatement(
      'INSERT INTO monitor_services (id, created_at, updated_at, server_id, '
      "name, critical) VALUES ('sc1', 'c', 'u', 'sv1', 'Сайт', 1)",
    );
    await db.customStatement(
      'INSERT INTO monitor_checks (id, created_at, updated_at, service_id, '
      'kind, name, url, interval_seconds, timeout_seconds) VALUES '
      "('ch1', 'c', 'u', 'sc1', 'http', 'Главная', 'https://example.com', 20, 5)",
    );
    final row = await db
        .customSelect('SELECT url, port, keyword FROM monitor_checks')
        .getSingle();
    expect(row.read<String>('url'), 'https://example.com');
    expect(row.read<int?>('port'), isNull);
    expect(row.read<String?>('keyword'), isNull);
  });

  test(
    'БД v10 открывается повторно без потери данных (шаги не повторяются)',
    () async {
      final first = AppDatabase(NativeDatabase(file));
      await first.customStatement(
        'INSERT INTO monitor_servers (id, created_at, updated_at, name, host) '
        "VALUES ('sv1', 'c', 'u', 'VPS', 'example.com')",
      );
      await first.close();
      final again = AppDatabase(NativeDatabase(file));
      addTearDown(again.close);
      final row = await again
          .customSelect('SELECT name FROM monitor_servers')
          .getSingle();
      expect(row.read<String>('name'), 'VPS');
    },
  );
}
