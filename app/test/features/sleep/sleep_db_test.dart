import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import '../../core/database_test.dart' show monitoringTables, sleepTables;

/// Схема v9 (Сон и ритуалы): миграция v8 -> v9 на файловой БД.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sleep_db_test');
    file = File('${dir.path}/sleep.sqlite');
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
    'sleep_entries': [
      'date',
      'bed_at',
      'wake_at',
      'bed_tz',
      'wake_tz',
      'source',
      'quality',
      'note',
    ],
    'daily_plans': ['date', 'task_ids', 'main_task_id', 'note'],
    'evening_checkins': [
      'date',
      'rating',
      'done_task_ids',
      'carry_over',
      'note',
    ],
  };

  test('миграция v8 -> v9: три таблицы и индексы, прежние данные целы, '
      'новые таблицы пишутся и читаются', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();
    // Настоящая БД v8: без таблиц Сна, с данными прежних этапов.
    final raw = sqlite3.open(file.path);
    for (final t in [...sleepTables, ...monitoringTables]) {
      raw.execute('DROP TABLE $t');
    }
    raw
      ..execute("INSERT INTO local_settings VALUES ('server_url', 'https://x')")
      ..execute(
        'INSERT INTO accounts (id, created_at, updated_at, name, kind, '
        'opening_balance, opening_date, include_in_total, archived) '
        "VALUES ('a1', 'c', 'u', 'Счёт', 'cash', 100, '2026-01-01', 1, 0)",
      )
      ..execute('PRAGMA user_version = 8')
      ..close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await LocalSettingsRepository(db).read('server_url'), 'https://x');
    final account = await db
        .customSelect('SELECT name FROM accounts')
        .getSingle();
    expect(account.read<String>('name'), 'Счёт');
    final names = await db
        .customSelect('SELECT name FROM sqlite_master')
        .get()
        .then((rows) => rows.map((r) => r.read<String>('name')).toSet());
    expect(
      names,
      containsAll([
        ...sleepTables,
        'sleep_entries_date_idx',
        'daily_plans_date_idx',
        'evening_checkins_date_idx',
      ]),
    );
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), AppDatabase.currentSchemaVersion);
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(9));

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
      'INSERT INTO sleep_entries (id, created_at, updated_at, date, bed_at, '
      'wake_at, wake_tz, source) VALUES '
      "('s1', 'c', 'u', '2026-10-05', '2026-10-04T20:30:00Z', "
      "'2026-10-05T04:10:00Z', 'Europe/Moscow', 'manual')",
    );
    final row = await db
        .customSelect('SELECT date, quality FROM sleep_entries')
        .getSingle();
    expect(row.read<String>('date'), '2026-10-05');
    expect(row.read<int?>('quality'), isNull);
  });
}
