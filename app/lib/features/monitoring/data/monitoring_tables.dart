import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 9 (spec `stage9_monitoring.md`, раздел 2).
/// Внешних ключей SQLite нет (как у всех синхронизируемых таблиц): видимость
/// строк считает `SyncStore` по родителям (сервер -> сервис -> проверка).
/// Измеренное (результаты, инциденты) здесь не хранится: оно приходит из API.

/// Серверы (2.1).
@DataClassName('MonitorServerRow')
class MonitorServers extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get host => text()();
  TextColumn get provider => text().nullable()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'monitor_servers';
}

/// Сервисы (проекты) на сервере — карточки «Пульса» (2.2).
@DataClassName('MonitorServiceRow')
@TableIndex(name: 'monitor_services_server_idx', columns: {#serverId})
class MonitorServices extends Table with SyncColumns {
  TextColumn get serverId => text()();
  TextColumn get name => text()();
  TextColumn get workProjectId => text().nullable()();
  BoolColumn get critical => boolean()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'monitor_services';
}

/// Проверки (2.3).
@DataClassName('MonitorCheckRow')
@TableIndex(name: 'monitor_checks_service_idx', columns: {#serviceId})
class MonitorChecks extends Table with SyncColumns {
  TextColumn get serviceId => text()();
  TextColumn get kind => text()();
  TextColumn get name => text()();
  TextColumn get url => text().nullable()();
  TextColumn get host => text().nullable()();
  IntColumn get port => integer().nullable()();
  TextColumn get dnsRecordType => text().nullable()();
  TextColumn get expectedValue => text().nullable()();
  IntColumn get expectedStatus => integer().nullable()();
  TextColumn get keyword => text().nullable()();
  IntColumn get sslMinDays => integer().nullable()();
  IntColumn get intervalSeconds => integer()();
  IntColumn get timeoutSeconds => integer()();

  @override
  String get tableName => 'monitor_checks';
}

// coverage:ignore-end
