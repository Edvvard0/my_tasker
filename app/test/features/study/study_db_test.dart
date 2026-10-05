import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import '../../core/database_test.dart' show studyTables;

/// Схема v8 (Учёба): миграция v7 → v8 на файловой БД.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('study_db_test');
    file = File('${dir.path}/study.sqlite');
  });
  tearDown(() => dir.delete(recursive: true));

  const indexes = [
    'study_subjects_semester_idx',
    'study_bells_semester_idx',
    'class_slots_semester_idx',
    'class_slots_subject_idx',
    'study_day_rules_semester_idx',
    'class_overrides_slot_idx',
    'study_attendance_slot_idx',
    'study_debts_subject_idx',
    'attachments_subject_idx',
    'attachments_debt_idx',
  ];

  test('миграция v7 -> v8: девять таблиц и индексы, прежние данные целы, '
      'новые таблицы пишутся и читаются', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();
    // Настоящая БД v7: без таблиц Учёбы, с данными прежних этапов.
    final raw = sqlite3.open(file.path);
    for (final t in studyTables) {
      raw.execute('DROP TABLE $t');
    }
    raw
      ..execute("INSERT INTO local_settings VALUES ('server_url', 'https://x')")
      ..execute(
        'INSERT INTO accounts (id, created_at, updated_at, name, kind, '
        'opening_balance, opening_date, include_in_total, archived) '
        "VALUES ('a1', 'c', 'u', 'Счёт', 'cash', 100, '2026-01-01', 1, 0)",
      )
      ..execute('PRAGMA user_version = 7')
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
    expect(names, containsAll([...studyTables, ...indexes]));
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), AppDatabase.currentSchemaVersion);
    expect(AppDatabase.currentSchemaVersion, 8);

    // Колонки таблиц — по контракту (служебные + прикладные).
    const service = [
      'id',
      'created_at',
      'updated_at',
      'deleted_at',
      'server_version',
      'origin_device_id',
    ];
    const columns = {
      'study_semesters': [
        'name',
        'start_date',
        'end_date',
        'week1_start',
        'cycle_length',
        'week_shifts',
        'archived',
      ],
      'study_subjects': [
        'semester_id',
        'name',
        'teacher',
        'building',
        'room',
        'absence_limit',
        'note',
        'archived',
      ],
      'study_bells': [
        'semester_id',
        'on_date',
        'number',
        'start_time',
        'end_time',
      ],
      'class_slots': [
        'semester_id',
        'subject_id',
        'title',
        'weekday',
        'number',
        'start_time',
        'end_time',
        'kind',
        'building',
        'room',
        'cycle_week',
      ],
      'study_day_rules': [
        'semester_id',
        'weekday',
        'on_date',
        'cycle_week',
        'title',
        'hide_regular',
        'items',
      ],
      'class_overrides': [
        'slot_id',
        'date',
        'action',
        'new_date',
        'start_time',
        'end_time',
        'building',
        'room',
        'subject_id',
        'title',
        'lesson_kind',
      ],
      'study_attendance': ['slot_id', 'date', 'status', 'note'],
      'study_debts': [
        'subject_id',
        'kind',
        'title',
        'status',
        'due_date',
        'done_date',
        'note',
        'task_id',
      ],
      'attachments': [
        'subject_id',
        'debt_id',
        'file_name',
        'mime_type',
        'size_bytes',
        'sha256',
        'upload_status',
      ],
    };
    for (final entry in columns.entries) {
      final cols = await db
          .customSelect('PRAGMA table_info(${entry.key})')
          .get();
      expect(cols.map((r) => r.read<String>('name')).toSet(), {
        ...service,
        ...entry.value,
      }, reason: entry.key);
    }

    await db.customStatement(
      'INSERT INTO study_semesters (id, created_at, updated_at, name, '
      'start_date, end_date, week1_start, cycle_length, archived) VALUES '
      "('s1', 'c', 'u', 'Осень', '2026-09-01', '2026-12-31', "
      "'2026-08-31', 2, 0)",
    );
    await db.customStatement(
      'INSERT INTO attachments (id, created_at, updated_at, subject_id, '
      'file_name, mime_type, size_bytes, sha256, upload_status) VALUES '
      "('f1', 'c', 'u', 's1', 'a.pdf', 'application/pdf', 10, "
      "'${'a' * 64}', 'pending')",
    );
    final semester = await db
        .customSelect('SELECT name, cycle_length FROM study_semesters')
        .getSingle();
    expect(semester.read<String>('name'), 'Осень');
    expect(semester.read<int>('cycle_length'), 2);
    final file1 = await db
        .customSelect('SELECT upload_status FROM attachments')
        .getSingle();
    expect(file1.read<String>('upload_status'), 'pending');
  });

  test(
    'таблицы Учёбы синхронизируемые: служебные колонки есть у всех',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      for (final t in studyTables) {
        final cols = await db.customSelect('PRAGMA table_info($t)').get();
        expect(
          cols.map((r) => r.read<String>('name')),
          containsAll(['id', 'updated_at', 'deleted_at', 'server_version']),
          reason: t,
        );
      }
    },
  );
}
