import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// Схема v7 (Банки): миграция v6 → v7 на файловой БД и локальная таблица
/// сырых уведомлений.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('banks_db_test');
    file = File('${dir.path}/banks.sqlite');
  });
  tearDown(() => dir.delete(recursive: true));

  test('миграция v6 -> v7: таблицы и индексы Банков, прежние данные целы, '
      'новые таблицы пишутся', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();
    // Настоящая БД v6: без таблиц Банков, с данными прежних этапов.
    final raw = sqlite3.open(file.path);
    for (final t in ['merchant_category_rules', 'bank_notifications']) {
      raw.execute('DROP TABLE $t');
    }
    raw
      ..execute("INSERT INTO local_settings VALUES ('server_url', 'https://x')")
      ..execute(
        'INSERT INTO accounts (id, created_at, updated_at, name, kind, '
        'opening_balance, opening_date, include_in_total, archived) '
        "VALUES ('a1', 'c', 'u', 'Счёт', 'cash', 100, '2026-01-01', 1, 0)",
      )
      ..execute('PRAGMA user_version = 6')
      ..close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await LocalSettingsRepository(db).read('server_url'), 'https://x');
    final account = await db
        .customSelect('SELECT name FROM accounts')
        .getSingle();
    expect(account.read<String>('name'), 'Счёт');
    final names = await db
        .customSelect(
          'SELECT name FROM sqlite_master WHERE name IN '
          "('merchant_category_rules', 'bank_notifications', "
          "'bank_notifications_received_idx', 'bank_notifications_state_idx')",
        )
        .get();
    expect(names, hasLength(4));
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), AppDatabase.currentSchemaVersion);
    expect(AppDatabase.currentSchemaVersion, 7);

    // Колонки таблицы правил — по контракту.
    final cols = await db
        .customSelect('PRAGMA table_info(merchant_category_rules)')
        .get();
    expect(
      cols.map((r) => r.read<String>('name')),
      containsAll([
        'id',
        'created_at',
        'updated_at',
        'deleted_at',
        'server_version',
        'origin_device_id',
        'merchant_key',
        'match_type',
        'kind',
        'category_id',
      ]),
    );
    await db.customStatement(
      'INSERT INTO merchant_category_rules (id, created_at, updated_at, '
      'merchant_key, match_type, kind, category_id) VALUES '
      "('r1', 'c', 'u', 'пятерочка', 'exact', 'expense', 'cat')",
    );
    final store = NotificationStore(db, now: () => DateTime.utc(2026, 10, 3));
    final saved = await store.insert(
      RawNotification(
        package: 'p',
        title: 't',
        text: 'x',
        postedAt: DateTime.utc(2026, 10, 3, 8),
      ),
      state: NotificationState.unrecognized,
      reason: 'no_rule',
    );
    expect(saved!.body, 'x');
  });

  test('таблица сырых уведомлений не синхронизируется: нет служебных '
      'колонок синхронизации и нет в реестре', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final cols = await db
        .customSelect('PRAGMA table_info(bank_notifications)')
        .get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll(['body', 'fingerprint', 'received_at']));
    expect(names, isNot(contains('server_version')));
    expect(names, isNot(contains('origin_device_id')));
  });

  test(
    'повторная вставка того же уведомления отклоняется отпечатком',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = NotificationStore(db, now: () => DateTime.utc(2026, 10, 3));
      final n = RawNotification(
        package: 'p',
        title: 't',
        text: 'x',
        postedAt: DateTime.utc(2026, 10, 3, 8),
      );
      expect(
        await store.insert(n, state: NotificationState.unrecognized),
        isNotNull,
      );
      expect(await store.seen(n), isTrue);
      expect(
        await store.insert(n, state: NotificationState.unrecognized),
        isNull,
      );
      expect(await store.count(), 1);
    },
  );
}
