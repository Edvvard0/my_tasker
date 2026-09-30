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

    test('создаёт схему v1 с таблицей local_settings', () async {
      expect(db.schemaVersion, AppDatabase.currentSchemaVersion);
      expect(db.schemaVersion, 1);
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .get();
      expect(tables.map((r) => r.read<String>('name')), ['local_settings']);
    });

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

    test('в реестре AppDatabase шагов пока нет (схема v1)', () {
      expect(AppDatabase.migrationSteps, isEmpty);
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
      expect(version.read<int>('user_version'), 1);
    });

    test('БД более новой схемы не открывается старым кодом', () async {
      sqlite3.open(file.path)
        ..execute('PRAGMA user_version = 7')
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
        throwsA(isA<StateError>()),
      );
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
