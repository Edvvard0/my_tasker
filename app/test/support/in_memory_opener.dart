import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:my_tasker/core/db/database_opener.dart';

/// БД в памяти для тестов (без SQLCipher-ключа и без файлов).
class InMemoryDatabaseOpener implements AppDatabaseOpener {
  int resets = 0;

  @override
  QueryExecutor open() => NativeDatabase.memory();

  @override
  Future<void> resetStorage() async => resets++;
}

/// БД, которую нельзя открыть, пока не выполнен сброс (потеря ключа).
class BrokenUntilResetOpener implements AppDatabaseOpener {
  BrokenUntilResetOpener(this.error);

  final Object error;
  bool _reset = false;
  int resets = 0;
  int opens = 0;

  @override
  QueryExecutor open() {
    opens++;
    if (_reset) return NativeDatabase.memory();
    // Любая ошибка открытия (в том числе не `Exception`) — намеренно.
    // ignore: only_throw_errors
    return LazyDatabase(() async => throw error);
  }

  @override
  Future<void> resetStorage() async {
    resets++;
    _reset = true;
  }
}
