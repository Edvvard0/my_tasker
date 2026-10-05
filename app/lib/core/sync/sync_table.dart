import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/value_validation.dart';

/// Типы прикладных колонок (spec 4, «Типы значений в JSON»).
enum SyncColumnType {
  text,
  integer,
  boolean,
  uuid,
  datetime,

  /// Любое JSON-значение; в БД хранится сериализованным текстом.
  json,
}

/// Прикладная колонка синхронизируемой таблицы.
@immutable
class SyncColumn {
  const SyncColumn(
    this.name,
    this.type, {
    this.nullable = false,
    this.immutable = false,
  });

  final String name;
  final SyncColumnType type;

  /// `null` допустим только у колонок, объявленных nullable.
  final bool nullable;

  /// Значение задаётся при создании и дальше не меняется.
  final bool immutable;

  /// JSON-значение -> значение для SQLite.
  Object? toDb(Object? value) {
    if (value == null) {
      return type == SyncColumnType.json && !nullable ? 'null' : null;
    }
    return switch (type) {
      SyncColumnType.boolean => (value as bool) ? 1 : 0,
      SyncColumnType.json => jsonEncode(value),
      _ => value,
    };
  }

  /// Значение из SQLite -> JSON-значение.
  Object? fromDb(Object? value) {
    if (value == null) return null;
    return switch (type) {
      SyncColumnType.boolean => value == 1 || value == true,
      SyncColumnType.json => jsonDecode(value as String),
      _ => value,
    };
  }

  /// Подходит ли значение по типу колонки.
  bool accepts(Object? value) {
    if (value == null) return nullable || type == SyncColumnType.json;
    return switch (type) {
      SyncColumnType.text ||
      SyncColumnType.uuid => value is String && isStorableText(value),
      SyncColumnType.datetime =>
        value is String && normalizeDatetime(value) != null,
      SyncColumnType.integer => value is int,
      SyncColumnType.boolean => value is bool,
      SyncColumnType.json => isStorableJson(value),
    };
  }
}

/// Связь «колонка дочерней таблицы -> родительская таблица» (spec 3.5).
@immutable
class SyncRelation {
  const SyncRelation(this.column, this.parentTable);

  final String column;
  final String parentTable;
}

/// Служебные колонки каждой синхронизируемой таблицы (spec 3.1).
const List<String> syncServiceColumns = [
  'id',
  'created_at',
  'updated_at',
  'deleted_at',
  'server_version',
  'origin_device_id',
];

/// Описание синхронизируемой таблицы. Модуль объявляет его один раз и
/// регистрирует в [SyncRegistry]; движок синхронизации, корзина и
/// видимость строк работают по этому описанию.
///
/// Физическая таблица (Drift) должна иметь служебные колонки из
/// [syncServiceColumns] и прикладные из [columns]. Внешние ключи SQLite
/// между синхронизируемыми таблицами не объявляются: строки приходят в
/// порядке `server_version`, родитель может прийти позже потомка.
@immutable
class SyncTableSpec {
  const SyncTableSpec({
    required this.name,
    required this.label,
    required this.columns,
    required this.titleOf,
    this.parents = const [],
    this.inTrash = true,
  });

  /// Имя таблицы в БД и в протоколе.
  final String name;

  /// Название объекта для интерфейса («Настройка»).
  final String label;

  final List<SyncColumn> columns;
  final List<SyncRelation> parents;

  /// Заголовок строки в корзине.
  final String Function(Json row) titleOf;

  /// Показывать удалённые строки в общей корзине. `false` — служебные
  /// записи (снятая отметка, звонок, сброшенное изменение): они удаляются
  /// мягко ради синхронизации, но пользователю в корзине не нужны;
  /// восстанавливаются повторной записью по естественному ключу.
  final bool inTrash;

  SyncColumn? column(String columnName) {
    for (final c in columns) {
      if (c.name == columnName) return c;
    }
    return null;
  }

  Set<String> get columnNames => {for (final c in columns) c.name};

  /// Строка SQLite -> JSON-строка (значения по типам колонок).
  Json rowFromDb(Map<String, Object?> data) {
    final row = <String, Object?>{};
    for (final name in syncServiceColumns) {
      if (data.containsKey(name)) row[name] = data[name];
    }
    for (final c in columns) {
      if (data.containsKey(c.name)) row[c.name] = c.fromDb(data[c.name]);
    }
    return row;
  }

  /// Проверяет поля правки. При [creating] обязательны все не-nullable
  /// колонки; неизвестные ключи и неверные типы — [ArgumentError].
  void validateFields(Json fields, {required bool creating}) {
    for (final entry in fields.entries) {
      final c = column(entry.key);
      if (c == null) {
        throw ArgumentError.value(entry.key, 'fields', 'нет колонки в $name');
      }
      if (!creating && c.immutable) {
        throw ArgumentError.value(entry.key, 'fields', 'колонка неизменяема');
      }
      if (!c.accepts(entry.value)) {
        throw ArgumentError.value(
          entry.value,
          'fields.${entry.key}',
          'неверный тип для $name.${entry.key}',
        );
      }
    }
    if (creating) {
      for (final c in columns) {
        if (!c.nullable && !fields.containsKey(c.name)) {
          throw ArgumentError.value(c.name, 'fields', 'обязательная колонка');
        }
      }
    }
  }
}

/// Реестр синхронизируемых таблиц приложения.
class SyncRegistry {
  SyncRegistry(Iterable<SyncTableSpec> specs)
    : _byName = {for (final s in specs) s.name: s} {
    final list = specs.toList();
    if (_byName.length != list.length) {
      throw ArgumentError('Повторяющееся имя синхронизируемой таблицы');
    }
    for (final spec in list) {
      for (final r in spec.parents) {
        if (!_byName.containsKey(r.parentTable)) {
          throw ArgumentError(
            '${spec.name}.${r.column}: нет родительской таблицы '
            '${r.parentTable}',
          );
        }
      }
    }
  }

  final Map<String, SyncTableSpec> _byName;

  List<SyncTableSpec> get specs => _byName.values.toList();
  List<String> get names => _byName.keys.toList()..sort();

  bool contains(String table) => _byName.containsKey(table);

  /// Описание таблицы; [ArgumentError], если таблица не зарегистрирована.
  SyncTableSpec spec(String table) {
    final spec = _byName[table];
    if (spec == null) {
      throw ArgumentError.value(table, 'table', 'таблица не зарегистрирована');
    }
    return spec;
  }

  SyncTableSpec? maybeSpec(String table) => _byName[table];
}
