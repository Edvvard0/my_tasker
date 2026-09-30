import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/migration_steps.dart';

part 'app_database.g.dart';

/// Локальные настройки устройства (ключ-значение): адрес сервера,
/// отпечаток сертификата и т. п. Не синхронизируется с сервером.
// DSL-описание таблицы исполняется только генератором кода (drift_dev).
// coverage:ignore-start
class LocalSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
// coverage:ignore-end

/// Локальная БД приложения (Drift). Схема v1 — только `local_settings`.
///
/// Правила миграций: любое изменение схемы = `schemaVersion + 1` и новый шаг
/// в [migrationSteps]; шаги применяются последовательно. Откат версии
/// приложения (схема БД новее кода) Drift тоже передаёт в `onUpgrade`
/// (`from > to`) — [runMigrationSteps] отвечает на него ошибкой.
@DriftDatabase(tables: [LocalSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Текущая версия схемы (то же значение, что и [schemaVersion]).
  static const int currentSchemaVersion = 1;

  @override
  int get schemaVersion => currentSchemaVersion;

  /// Шаги миграции по целевой версии. Шага для v1 нет: её создаёт `onCreate`.
  static final Map<int, MigrationStep> migrationSteps = {};

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) => runMigrationSteps(m, from, to, migrationSteps),
    beforeOpen: (details) => customStatement('PRAGMA foreign_keys = ON'),
  );
}
