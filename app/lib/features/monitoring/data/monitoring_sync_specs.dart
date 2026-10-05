import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 9 (spec `stage9_monitoring.md`, раздел 2;
/// сервер: `backend/src/tasker/monitoring/tables.py`, `MONITORING_TABLES`).
/// Порядок регистрации — родители вперёд: `monitor_servers`,
/// `monitor_services`, `monitor_checks`. Каскады делает сервер; клиент шлёт
/// одну операцию `delete` родителя, потомков скрывает видимость строк.
///
/// `monitor_services.work_project_id` — мягкая ссылка на проект Работы (без
/// родителя в реестре). Результаты, инциденты и состояние алертов в таблицы
/// клиента не попадают.

/// `monitor_servers` — серверы (2.1).
const SyncTableSpec monitorServersSpec = SyncTableSpec(
  name: 'monitor_servers',
  label: 'Сервер',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('host', SyncColumnType.text),
    SyncColumn('provider', SyncColumnType.text, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  titleOf: _name,
);

/// `monitor_services` — сервисы (проекты) на сервере (2.2). `server_id`
/// неизменяем.
const SyncTableSpec monitorServicesSpec = SyncTableSpec(
  name: 'monitor_services',
  label: 'Сервис',
  columns: [
    SyncColumn('server_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('work_project_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('critical', SyncColumnType.boolean),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('server_id', 'monitor_servers')],
  titleOf: _name,
);

/// `monitor_checks` — проверки (2.3). `service_id` и `kind` неизменяемы.
const SyncTableSpec monitorChecksSpec = SyncTableSpec(
  name: 'monitor_checks',
  label: 'Проверка',
  columns: [
    SyncColumn('service_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('kind', SyncColumnType.text, immutable: true),
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('url', SyncColumnType.text, nullable: true),
    SyncColumn('host', SyncColumnType.text, nullable: true),
    SyncColumn('port', SyncColumnType.integer, nullable: true),
    SyncColumn('dns_record_type', SyncColumnType.text, nullable: true),
    SyncColumn('expected_value', SyncColumnType.text, nullable: true),
    SyncColumn('expected_status', SyncColumnType.integer, nullable: true),
    SyncColumn('keyword', SyncColumnType.text, nullable: true),
    SyncColumn('ssl_min_days', SyncColumnType.integer, nullable: true),
    SyncColumn('interval_seconds', SyncColumnType.integer),
    SyncColumn('timeout_seconds', SyncColumnType.integer),
  ],
  parents: [SyncRelation('service_id', 'monitor_services')],
  titleOf: _name,
);

/// Все таблицы Этапа 9 в порядке регистрации.
const List<SyncTableSpec> monitoringSyncSpecs = [
  monitorServersSpec,
  monitorServicesSpec,
  monitorChecksSpec,
];

String _name(Map<String, Object?> row) => '${row['name']}';
