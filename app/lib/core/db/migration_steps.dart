import 'package:drift/drift.dart';

/// Один шаг миграции схемы: приводит БД от версии `N-1` к `N`.
typedef MigrationStep = Future<void> Function(Migrator m);

/// Последовательно применяет шаги `from+1 … to`.
///
/// * `from == to` — ничего не делает;
/// * `from > to` (откат версии приложения) — [StateError]: данные новой
///   схемы старым кодом не читаем;
/// * нет шага для очередной версии — [StateError] (забыли написать миграцию).
Future<void> runMigrationSteps(
  Migrator m,
  int from,
  int to,
  Map<int, MigrationStep> steps,
) async {
  if (from > to) {
    throw StateError(
      'Схема БД v$from новее приложения (v$to). '
      'Обновите приложение.',
    );
  }
  for (var version = from + 1; version <= to; version++) {
    final step = steps[version];
    if (step == null) {
      throw StateError('Нет шага миграции БД до версии v$version');
    }
    await step(m);
  }
}

/// Добавляет колонку, только если её ещё нет. Нужна шагам, расширяющим
/// таблицу, созданную более ранним шагом той же цепочки: `createTable`
/// всегда строит таблицу по **текущей** схеме (с новой колонкой), и
/// повторный `ALTER TABLE ADD COLUMN` упал бы с «duplicate column».
Future<void> addColumnIfMissing(
  Migrator m,
  TableInfo<Table, Object?> table,
  GeneratedColumn<Object> column,
) async {
  final db = m.database;
  final rows = await db
      .customSelect('PRAGMA table_info("${table.actualTableName}")')
      .get();
  final exists = rows.any((r) => r.read<String>('name') == column.name);
  if (!exists) await m.addColumn(table, column);
}
