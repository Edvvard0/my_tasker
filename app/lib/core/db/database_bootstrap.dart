import 'dart:async';

import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/db/database_key_store.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

/// Почему локальную БД не удалось открыть.
enum DatabaseFailureKind {
  /// Файл есть, но ключ отсутствует, не подходит или повреждён: данные
  /// прочитать нельзя, помогает только сброс и загрузка с сервера.
  unreadable,

  /// БД создана более новой версией приложения: сброс не нужен, нужно
  /// обновить приложение.
  schemaTooNew,

  /// Иная ошибка (диск, права): можно повторить.
  other,
}

/// Итог первого обращения к БД при запуске.
class DatabaseBootstrap {
  const DatabaseBootstrap.ok() : failure = null;

  const DatabaseBootstrap.failed(DatabaseFailureKind this.failure);

  final DatabaseFailureKind? failure;

  bool get isOk => failure == null;
}

/// SQLite ответил «это не база данных» (код 26): для SQLCipher так выглядит
/// неверный или отсутствующий ключ. Ошибка приходит из фонового изолята
/// обёрнутой в [DriftRemoteException].
bool _isNotADatabase(Object error) {
  final cause = error is DriftRemoteException ? error.remoteCause : error;
  if (cause is SqliteException) {
    return cause.resultCode == 26 ||
        cause.message.contains('file is not a database');
  }
  return '$cause'.contains('file is not a database');
}

DatabaseFailureKind _classify(Object error) {
  if (error is DatabaseKeyCorruptedException || _isNotADatabase(error)) {
    return DatabaseFailureKind.unreadable;
  }
  if (error is StateError && '$error'.contains('новее приложения')) {
    return DatabaseFailureKind.schemaTooNew;
  }
  return DatabaseFailureKind.other;
}

/// Открывает БД и проверяет её чтением. Ошибка не бросается, а
/// превращается в [DatabaseBootstrap.failed]: приложение показывает экран
/// восстановления вместо падения.
final databaseBootstrapProvider = FutureProvider<DatabaseBootstrap>((
  ref,
) async {
  try {
    await ref
        .watch(appDatabaseProvider)
        .customSelect('SELECT count(*) FROM sqlite_master')
        .get();
    return const DatabaseBootstrap.ok();
  } on Object catch (error) {
    return DatabaseBootstrap.failed(_classify(error));
  }
}, retry: (_, _) => null);

/// Сброс локальных данных (кнопка «Сбросить локальные данные и загрузить с
/// сервера»): удаляет БД и ключ, стирает токены (адрес сервера и
/// закреплённый сертификат лежали в самой БД) и открывает пустую БД.
/// Дальше пользователь заново указывает сервер, входит, и первая
/// синхронизация загружает данные с нуля.
Future<void> resetLocalData(Ref ref) async {
  final opener = ref.read(databaseOpenerProvider);
  // Закрываем старое соединение до удаления файла.
  ref.invalidate(appDatabaseProvider);
  await opener.resetStorage();
  await ref.read(tokenStoreProvider).clear();
  ref
    ..invalidate(authControllerProvider)
    ..invalidate(databaseBootstrapProvider);
}

/// Вызывается с экрана восстановления.
final localDataResetProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => resetLocalData(ref),
);

/// «Повторить» на экране восстановления: открыть БД заново.
final localDataRetryProvider = Provider<void Function()>(
  (ref) => () {
    ref
      ..invalidate(appDatabaseProvider)
      ..invalidate(databaseBootstrapProvider);
  },
);
