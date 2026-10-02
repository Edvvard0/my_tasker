import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:my_tasker/core/db/database_key_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Способ открыть БД. Продакшен — [EncryptedDatabaseOpener] (SQLCipher),
/// тесты подставляют in-memory через `databaseOpenerProvider`.
abstract interface class AppDatabaseOpener {
  QueryExecutor open();

  /// Удаляет локальное хранилище (файл БД) и ключ шифрования: следующий
  /// `open()` создаст пустую БД с новым ключом. Нужен для восстановления,
  /// когда БД существует, но ключ потерян или не подходит.
  Future<void> resetStorage();
}

/// Путь к файлу БД по умолчанию (каталог данных приложения).
Future<File> defaultDatabaseFile() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'my_tasker.sqlite'));
}

/// Открывает БД, зашифрованную SQLCipher целиком.
///
/// Ключ — 256 бит из [DatabaseKeyStore]; передаётся как «сырой» hex-ключ
/// (`PRAGMA key = "x'…'"`), без KDF по паролю.
class EncryptedDatabaseOpener implements AppDatabaseOpener {
  EncryptedDatabaseOpener({
    required this.keyStore,
    this.locateFile = defaultDatabaseFile,
  });

  final DatabaseKeyStore keyStore;
  final Future<File> Function() locateFile;

  @override
  QueryExecutor open() => LazyDatabase(() async {
    final key = await keyStore.getOrCreateKey();
    final file = await locateFile();
    await file.parent.create(recursive: true);
    return NativeDatabase.createInBackground(file, setup: _cipherSetup(key));
  });

  @override
  Future<void> resetStorage() async {
    final file = await locateFile();
    // Рядом с основным файлом SQLite держит журналы.
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final part = File('${file.path}$suffix');
      if (part.existsSync()) await part.delete();
    }
    await keyStore.resetKey();
  }
}

/// Возвращает `setup`-колбэк, который включает шифрование ключом [hexKey].
///
/// Отдельная функция (а не замыкание в классе), чтобы колбэк можно было
/// передать в фоновый изолят.
void Function(Database) _cipherSetup(String hexKey) => (db) {
  // Ожидание блокировки нужно уже при проверке ключа: второй изолят может
  // держать БД в этот момент.
  applyBusyTimeout(db);
  applyCipherKey(db, hexKey);
  enableWal(db);
};

/// Писатель ждёт снятия блокировки до 5 с вместо мгновенного
/// `SQLITE_BUSY` (два изолята — интерфейс и WorkManager — открывают один
/// файл БД).
void applyBusyTimeout(Database db) => db.execute('PRAGMA busy_timeout = 5000;');

/// `WAL`: читатели не блокируются писателем. Вызывается после установки
/// ключа; `journal_mode` можно менять только вне транзакции.
void enableWal(Database db) => db.execute('PRAGMA journal_mode = WAL;');

/// Включает шифрование и проверяет, что ключ подошёл.
///
/// Бросает [StateError], если вместо SQLCipher подключён обычный SQLite:
/// молча писать данные в открытом виде недопустимо. Неверный ключ приводит к
/// [SqliteException] («file is not a database»).
void applyCipherKey(Database db, String hexKey) {
  // Ключ подставляется в PRAGMA как текст: допускаем только 64 hex-символа.
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hexKey)) {
    throw ArgumentError.value('***', 'hexKey', 'ожидается 64 hex-символа');
  }
  final version = db.select('PRAGMA cipher_version;');
  final value = version.isEmpty ? null : version.first.values.first;
  if (value == null || value.toString().isEmpty) {
    throw StateError(
      'SQLCipher не подключён: проверьте hooks.user_defines.sqlite3.source '
      'в pubspec.yaml',
    );
  }
  db
    ..execute('''PRAGMA key = "x'$hexKey'";''')
    // Чтение схемы падает, если ключ неверный.
    ..select('SELECT count(*) FROM sqlite_master;');
}
