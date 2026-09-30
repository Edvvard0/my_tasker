import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:my_tasker/core/db/database_opener.dart';

/// БД в памяти для тестов (без SQLCipher-ключа и без файлов).
class InMemoryDatabaseOpener implements AppDatabaseOpener {
  @override
  QueryExecutor open() => NativeDatabase.memory();
}
