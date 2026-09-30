import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';

void main() {
  late AppDatabase db;
  late LocalSettingsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LocalSettingsRepository(db);
  });
  tearDown(() => db.close());

  group('LocalSettingsRepository', () {
    test('read отсутствующего ключа -> null', () async {
      expect(await repo.read('nope'), isNull);
    });

    test('write + read', () async {
      await repo.write('k', 'v');
      expect(await repo.read('k'), 'v');
    });

    test('write заменяет значение (upsert)', () async {
      await repo.write('k', 'v1');
      await repo.write('k', 'v2');
      expect(await repo.read('k'), 'v2');
      expect(await repo.readAll(), {'k': 'v2'});
    });

    test('delete удаляет, повторный delete безопасен', () async {
      await repo.write('k', 'v');
      await repo.delete('k');
      await repo.delete('k');
      expect(await repo.read('k'), isNull);
    });

    test('writeAll: запись и удаление (null) одной транзакцией', () async {
      await repo.write('a', '1');
      await repo.writeAll({'a': null, 'b': '2', 'c': '3'});
      expect(await repo.readAll(), {'b': '2', 'c': '3'});
    });

    test('writeAll откатывается целиком при ошибке', () async {
      await repo.write('a', '1');
      await expectLater(
        db.transaction(() async {
          await repo.write('a', 'changed');
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(await repo.read('a'), '1');
    });
  });

  group('ServerConnectionRepository', () {
    late ServerConnectionRepository server;
    setUp(() => server = ServerConnectionRepository(repo));

    test('пусто по умолчанию', () async {
      final s = await server.load();
      expect(s.isConfigured, isFalse);
      expect(s.url, isNull);
      expect(s.caPem, isNull);
    });

    test('save + load', () async {
      const saved = ServerConnectionSettings(
        url: 'https://203.0.113.10',
        caPem: 'PEM',
      );
      await server.save(saved);
      final loaded = await server.load();
      expect(loaded, saved);
      expect(loaded.isConfigured, isTrue);
      expect(loaded.hashCode, saved.hashCode);
      expect(await repo.readAll(), {
        SettingsKeys.serverUrl: 'https://203.0.113.10',
        SettingsKeys.serverRootCaPem: 'PEM',
      });
    });

    test('save с null очищает значения', () async {
      await server.save(
        const ServerConnectionSettings(url: 'https://x', caPem: 'PEM'),
      );
      await server.save(const ServerConnectionSettings());
      expect(await server.load(), const ServerConnectionSettings());
      expect(await repo.readAll(), isEmpty);
    });

    test('равенство учитывает оба поля', () {
      const a = ServerConnectionSettings(url: 'u', caPem: 'p');
      expect(a == const ServerConnectionSettings(url: 'u'), isFalse);
      expect(a == const ServerConnectionSettings(caPem: 'p'), isFalse);
    });
  });
}
