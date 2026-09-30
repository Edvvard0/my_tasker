import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/database_key_store.dart';
import 'package:my_tasker/core/db/database_opener.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';

/// Хранилище ключа БД. Тесты переопределяют его.
final databaseKeyStoreProvider = Provider<DatabaseKeyStore>(
  (ref) => SecureDatabaseKeyStore(),
);

/// Способ открытия БД. Продакшен — SQLCipher, тесты — in-memory.
final databaseOpenerProvider = Provider<AppDatabaseOpener>(
  (ref) =>
      EncryptedDatabaseOpener(keyStore: ref.watch(databaseKeyStoreProvider)),
);

/// Единственный экземпляр БД на время жизни приложения.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(ref.watch(databaseOpenerProvider).open());
  ref.onDispose(db.close);
  return db;
});

final localSettingsRepositoryProvider = Provider<LocalSettingsRepository>(
  (ref) => LocalSettingsRepository(ref.watch(appDatabaseProvider)),
);
