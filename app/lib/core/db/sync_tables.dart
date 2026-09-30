import 'package:drift/drift.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Очередь неотправленных операций (outbox, spec 3.2 и 5.1).
///
/// Порядок отправки — по `seq` (порядок создания). Подтверждённая сервером
/// операция удаляется.
@DataClassName('OutboxEntry')
class SyncOutbox extends Table {
  IntColumn get seq => integer().autoIncrement()();

  /// UUIDv7 операции; сервер по нему обеспечивает идемпотентность.
  TextColumn get opId => text().unique()();

  /// Имя синхронизируемой таблицы (поле `table` протокола).
  TextColumn get targetTable => text()();

  TextColumn get rowId => text()();

  /// `upsert` | `delete`.
  TextColumn get opType => text()();

  /// JSON с изменёнными колонками (только для `upsert`).
  TextColumn get fields => text().nullable()();

  IntColumn get baseVersion => integer()();

  TextColumn get hlc => text()();

  /// `pending` | `in_flight` | `rejected`.
  TextColumn get state => text().withDefault(const Constant('pending'))();

  TextColumn get rejectCode => text().nullable()();

  TextColumn get rejectMessage => text().nullable()();

  /// Когда операция создана (мс Unix) — для экрана «Синхронизация».
  IntColumn get createdAtMs => integer().withDefault(const Constant(0))();

  @override
  String get tableName => 'sync_outbox';
}

/// Служебное состояние синхронизации (ключ-значение): `device_id`, HLC,
/// курсор pull, времена последних обменов. Токены сюда не пишутся.
@DataClassName('SyncMetaEntry')
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};

  @override
  String get tableName => 'sync_meta';
}

/// Синхронизируемая таблица `user_settings` (spec 4.1): настройки
/// «ключ -> значение», общие для устройств. Служебные поля — по spec 3.1.
@DataClassName('UserSettingRow')
class UserSettings extends Table {
  TextColumn get id => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  TextColumn get originDeviceId => text().nullable()();
  TextColumn get key => text()();

  /// JSON-значение (сериализованное).
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  String get tableName => 'user_settings';
}
// coverage:ignore-end
