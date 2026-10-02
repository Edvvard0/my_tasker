import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/database_key_store.dart';
import 'package:my_tasker/core/db/database_opener.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:my_tasker/core/db/migration_steps.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import '../support/in_memory_opener.dart';

/// Доступ к защищённому `createMigrator` для проверки шагов миграции.
class _MigratorDb extends AppDatabase {
  _MigratorDb(super.e);

  Migrator migrator() => createMigrator();
}

class _FixedKeyStore implements DatabaseKeyStore {
  _FixedKeyStore(this.key);

  final String key;

  @override
  Future<String> getOrCreateKey() async => key;

  @override
  Future<String> resetKey() async => key;
}

/// Подделка `Database` без SQLCipher: `PRAGMA cipher_version` пуст.
class _PlainSqliteDb extends Fake implements Database {
  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      ResultSet(const [], null, const []);
}

void main() {
  const keyA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const keyB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  group('AppDatabase (in-memory)', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test(
      'создаёт схему v5: настройки, синхронизация, календарь, ИИ-чат и финансы',
      () async {
        expect(db.schemaVersion, AppDatabase.currentSchemaVersion);
        expect(db.schemaVersion, 5);
        final tables = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%' ORDER BY name",
            )
            .get();
        expect(tables.map((r) => r.read<String>('name')), [
          'accounts',
          'ai_agent_profiles',
          'ai_context_presets',
          'ai_conversations',
          'ai_messages',
          'ai_model_favorites',
          'ai_prompt_versions',
          'ai_tool_proposals',
          'balance_checkpoints',
          'calendars',
          'categories',
          'debt_repayments',
          'debts',
          'event_overrides',
          'events',
          'goals',
          'local_settings',
          'people',
          'projects',
          'subtasks',
          'sync_meta',
          'sync_outbox',
          'tags',
          'task_completions',
          'task_tags',
          'tasks',
          'transactions',
          'user_settings',
        ]);
      },
    );

    test('внешние ключи включены', () async {
      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 1);
    });
  });

  group('runMigrationSteps', () {
    late _MigratorDb db;

    setUp(() => db = _MigratorDb(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('from == to: ничего не делает', () async {
      await runMigrationSteps(db.migrator(), 1, 1, const {});
    });

    test('применяет шаги по порядку', () async {
      final calls = <int>[];
      await runMigrationSteps(db.migrator(), 1, 3, {
        2: (m) async => calls.add(2),
        3: (m) async => calls.add(3),
      });
      expect(calls, [2, 3]);
    });

    test('нет шага для версии -> StateError', () async {
      await expectLater(
        runMigrationSteps(db.migrator(), 1, 2, const {}),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('v2')),
        ),
      );
    });

    test('откат версии (from > to) -> StateError', () async {
      await expectLater(
        runMigrationSteps(db.migrator(), 3, 1, const {}),
        throwsA(isA<StateError>()),
      );
    });

    test('в реестре AppDatabase есть шаги до v2…v5 (v5 — Финансы)', () {
      expect(AppDatabase.migrationSteps.keys, [2, 3, 4, 5]);
    });
  });

  group('AppDatabase: файл и версия схемы', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('db_test');
      file = File('${dir.path}/plain.sqlite');
    });
    tearDown(() => dir.delete(recursive: true));

    test('данные переживают переоткрытие', () async {
      var db = AppDatabase(NativeDatabase(file));
      await LocalSettingsRepository(db).write('k', 'v');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await LocalSettingsRepository(db).read('k'), 'v');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(
        version.read<int>('user_version'),
        AppDatabase.currentSchemaVersion,
      );
    });

    test('миграция v1 -> v2 сохраняет данные и добавляет таблицы', () async {
      sqlite3.open(file.path)
        ..execute(
          'CREATE TABLE local_settings (key TEXT NOT NULL PRIMARY KEY, '
          'value TEXT NOT NULL)',
        )
        ..execute(
          "INSERT INTO local_settings VALUES ('server_url', 'https://x')",
        )
        ..execute('PRAGMA user_version = 1')
        ..close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await LocalSettingsRepository(db).read('server_url'), 'https://x');
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('sync_outbox', 'sync_meta', 'user_settings')",
          )
          .get();
      expect(tables, hasLength(3));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(
        version.read<int>('user_version'),
        AppDatabase.currentSchemaVersion,
      );
    });

    test('миграция v2 -> v3 добавляет таблицы календаря и индексы', () async {
      // Настоящая БД v2: создаём схему через шаги до v2 и понижаем версию.
      final first = AppDatabase(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      await first.close();
      sqlite3.open(file.path)
        ..execute('DROP TABLE tasks')
        ..execute('DROP TABLE events')
        ..execute('DROP TABLE calendars')
        ..execute('DROP TABLE event_overrides')
        ..execute('DROP TABLE projects')
        ..execute('DROP TABLE people')
        ..execute('DROP TABLE tags')
        ..execute('DROP TABLE subtasks')
        ..execute('DROP TABLE task_tags')
        ..execute('DROP TABLE task_completions')
        ..execute('DROP TABLE ai_agent_profiles')
        ..execute('DROP TABLE ai_prompt_versions')
        ..execute('DROP TABLE ai_context_presets')
        ..execute('DROP TABLE ai_model_favorites')
        ..execute('DROP TABLE ai_conversations')
        ..execute('DROP TABLE ai_messages')
        ..execute('DROP TABLE ai_tool_proposals')
        ..execute('DROP TABLE accounts')
        ..execute('DROP TABLE categories')
        ..execute('DROP TABLE transactions')
        ..execute('DROP TABLE balance_checkpoints')
        ..execute('DROP TABLE debts')
        ..execute('DROP TABLE debt_repayments')
        ..execute('DROP TABLE goals')
        ..execute('PRAGMA user_version = 2')
        ..close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final names = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name LIKE 'tasks%' "
            "OR name LIKE 'events%'",
          )
          .get();
      expect(
        names.map((r) => r.read<String>('name')),
        containsAll(['tasks', 'tasks_due_date_idx', 'events']),
      );
    });

    test('миграция v3 -> v4 добавляет таблицы ИИ-чата и индексы', () async {
      final first = AppDatabase(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      await first.close();
      final raw = sqlite3.open(file.path);
      for (final t in [
        'ai_agent_profiles',
        'ai_prompt_versions',
        'ai_context_presets',
        'ai_model_favorites',
        'ai_conversations',
        'ai_messages',
        'ai_tool_proposals',
        'accounts',
        'categories',
        'transactions',
        'balance_checkpoints',
        'debts',
        'debt_repayments',
        'goals',
      ]) {
        raw.execute('DROP TABLE $t');
      }
      raw
        ..execute('PRAGMA user_version = 3')
        ..close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final names = await db
          .customSelect("SELECT name FROM sqlite_master WHERE name LIKE 'ai_%'")
          .get();
      expect(
        names.map((r) => r.read<String>('name')),
        containsAll([
          'ai_messages',
          'ai_messages_conversation_idx',
          'ai_tool_proposals_message_idx',
          'ai_prompt_versions_profile_idx',
        ]),
      );
    });

    test('миграция v4 -> v5 добавляет таблицы Финансов и индексы', () async {
      final first = AppDatabase(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      await first.close();
      final raw = sqlite3.open(file.path);
      for (final t in [
        'accounts',
        'categories',
        'transactions',
        'balance_checkpoints',
        'debts',
        'debt_repayments',
        'goals',
      ]) {
        raw.execute('DROP TABLE $t');
      }
      raw
        ..execute(
          "INSERT INTO local_settings VALUES ('server_url', 'https://keep')",
        )
        ..execute('PRAGMA user_version = 4')
        ..close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(
        await LocalSettingsRepository(db).read('server_url'),
        'https://keep',
      );
      final names = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'index') "
            "AND name IN ('accounts', 'categories', 'transactions', "
            "'balance_checkpoints', 'debts', 'debt_repayments', 'goals', "
            "'transactions_account_idx', 'transactions_to_account_idx', "
            "'transactions_occurred_idx', 'balance_checkpoints_account_idx', "
            "'debt_repayments_debt_idx')",
          )
          .get();
      expect(names, hasLength(12));
      // таблицы рабочие: можно вставить и прочитать строку со всеми колонками
      await db.customStatement(
        'INSERT INTO accounts (id, created_at, updated_at, name, kind, '
        'opening_balance, opening_date, include_in_total, archived) '
        "VALUES ('a', 'x', 'y', 'Карта', 'cash', -5, '2026-01-01', 1, 0)",
      );
      final row = await db.customSelect('SELECT * FROM accounts').getSingle();
      expect(row.read<int>('opening_balance'), -5);
      expect(row.data['credit_limit'] == null, isTrue);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 5);
    });

    test('БД более новой схемы не открывается старым кодом', () async {
      sqlite3.open(file.path)
        ..execute('PRAGMA user_version = 9')
        ..close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SecureDatabaseKeyStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test(
      'первый запуск: 32 случайных байта, сохраняются в хранилище',
      () async {
        final store = SecureDatabaseKeyStore();
        final key = await store.getOrCreateKey();
        expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));

        const storage = FlutterSecureStorage();
        expect(await storage.read(key: SecureDatabaseKeyStore.storageKey), key);
      },
    );

    test('повторный вызов возвращает тот же ключ', () async {
      final a = await SecureDatabaseKeyStore().getOrCreateKey();
      final b = await SecureDatabaseKeyStore().getOrCreateKey();
      expect(b, a);
    });

    test('ключи разных установок различаются', () async {
      final a = SecureDatabaseKeyStore.generateKey(Random.secure());
      final b = SecureDatabaseKeyStore.generateKey(Random.secure());
      expect(a, isNot(b));
    });

    test('generateKey детерминирован для заданного Random', () {
      expect(
        SecureDatabaseKeyStore.generateKey(Random(1)),
        SecureDatabaseKeyStore.generateKey(Random(1)),
      );
    });

    test('повреждённый ключ не заменяется молча', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureDatabaseKeyStore.storageKey: 'not-a-key',
      });
      await expectLater(
        SecureDatabaseKeyStore().getOrCreateKey(),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );
      await expectLater(
        SecureDatabaseKeyStore().getOrCreateKey(),
        throwsA(isA<StateError>()),
      );
    });

    test('resetKey заменяет ключ (в том числе повреждённый) новым', () async {
      final store = SecureDatabaseKeyStore();
      final first = await store.getOrCreateKey();
      final second = await store.resetKey();
      expect(second, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second, isNot(first));
      expect(await store.getOrCreateKey(), second);
      FlutterSecureStorage.setMockInitialValues({
        SecureDatabaseKeyStore.storageKey: 'broken',
      });
      final fixed = await SecureDatabaseKeyStore().resetKey();
      expect(await SecureDatabaseKeyStore().getOrCreateKey(), fixed);
    });

    test('свой Random используется при генерации', () async {
      final store = SecureDatabaseKeyStore(random: Random(42));
      expect(
        await store.getOrCreateKey(),
        SecureDatabaseKeyStore.generateKey(Random(42)),
      );
    });
  });

  group('EncryptedDatabaseOpener (настоящий SQLCipher)', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cipher_test');
      file = File('${dir.path}/nested/dir/enc.sqlite');
    });
    tearDown(() => dir.delete(recursive: true));

    EncryptedDatabaseOpener opener(String key) => EncryptedDatabaseOpener(
      keyStore: _FixedKeyStore(key),
      locateFile: () async => file,
    );

    test('подключён именно SQLCipher', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final version = db.select('PRAGMA cipher_version').first.values.first;
      expect(version, isA<String>().having((v) => v, 'v', isNotEmpty));
    });

    test('создаёт каталог, пишет и читает данные тем же ключом', () async {
      var db = AppDatabase(opener(keyA).open());
      await LocalSettingsRepository(db).write('server_url', 'https://x');
      await db.close();

      db = AppDatabase(opener(keyA).open());
      addTearDown(db.close);
      expect(await LocalSettingsRepository(db).read('server_url'), 'https://x');
    });

    test('файл зашифрован: нет заголовка SQLite и открытого текста', () async {
      final db = AppDatabase(opener(keyA).open());
      await LocalSettingsRepository(db).write('secret_key', 'TOP-SECRET-VALUE');
      await db.close();

      final bytes = file.readAsBytesSync();
      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'));
      final asText = String.fromCharCodes(bytes);
      expect(asText.contains('TOP-SECRET-VALUE'), isFalse);
      expect(asText.contains('local_settings'), isFalse);
    });

    test('M3: WAL и busy_timeout включены; второе соединение читает, пока '
        'первое пишет', () async {
      final db = AppDatabase(opener(keyA).open());
      final second = AppDatabase(opener(keyA).open());
      addTearDown(second.close);
      addTearDown(db.close);
      Future<Object?> pragma(AppDatabase d, String name) async =>
          (await d.customSelect('PRAGMA $name').getSingle()).data.values.first;
      expect(await pragma(db, 'journal_mode'), 'wal');
      expect(await pragma(db, 'busy_timeout'), 5000);
      expect(await pragma(second, 'journal_mode'), 'wal');
      expect(await pragma(second, 'busy_timeout'), 5000);
      await LocalSettingsRepository(db).write('k', 'v1');
      String? seen;
      await db.transaction(() async {
        await LocalSettingsRepository(db).write('k', 'v2'); // не зафиксировано
        // читатель в другом соединении не блокируется и видит старое значение
        seen = await LocalSettingsRepository(second).read('k');
      });
      expect(seen, 'v1');
      expect(await LocalSettingsRepository(second).read('k'), 'v2');
    });

    test('чужой ключ не открывает БД', () async {
      final db = AppDatabase(opener(keyA).open());
      await LocalSettingsRepository(db).write('k', 'v');
      await db.close();

      final wrong = AppDatabase(opener(keyB).open());
      addTearDown(() async {
        try {
          await wrong.close();
        } on Object {
          // БД так и не открылась — закрывать нечего.
        }
      });
      await expectLater(
        LocalSettingsRepository(wrong).read('k'),
        throwsA(anything),
      );
    });

    test('БД без ключа не читается обычным sqlite', () async {
      final db = AppDatabase(opener(keyA).open());
      await LocalSettingsRepository(db).write('k', 'v');
      await db.close();

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(
        () => raw.select('SELECT * FROM local_settings'),
        throwsA(isA<SqliteException>()),
      );
    });

    test('ключ не в формате 64 hex отвергается до подстановки в PRAGMA', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      for (final bad in [
        '',
        'zz',
        keyA.substring(1),
        '$keyA"; DROP',
        keyA.toUpperCase(),
      ]) {
        expect(() => applyCipherKey(db, bad), throwsArgumentError, reason: bad);
      }
    });

    test('без SQLCipher вместо шифрования — ошибка, а не открытая БД', () {
      expect(
        () => applyCipherKey(_PlainSqliteDb(), keyA),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('SQLCipher'),
          ),
        ),
      );
    });
  });

  group('провайдеры БД', () {
    test(
      'appDatabaseProvider открывает БД через opener и закрывает её',
      () async {
        final container = ProviderContainer(
          overrides: [
            databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
          ],
        );
        final repo = container.read(localSettingsRepositoryProvider);
        await repo.write('a', '1');
        expect(await repo.read('a'), '1');
        container.dispose();
      },
    );

    test('по умолчанию opener — зашифрованный', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(databaseOpenerProvider),
        isA<EncryptedDatabaseOpener>(),
      );
      expect(
        container.read(databaseKeyStoreProvider),
        isA<SecureDatabaseKeyStore>(),
      );
    });
  });
}
