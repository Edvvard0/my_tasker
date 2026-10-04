import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 4 (spec `stage4_work.md`, раздел 1).
/// `projects` и `people` расширены на месте
/// (`features/tasks/data/task_sync_specs.dart`). Порядок регистрации —
/// родители вперёд (`backend/src/tasker/work/tables.py`, `WORK_TABLES`).
///
/// Деньги — целые копейки (`integer`). Каскады делает сервер; клиент шлёт
/// одну операцию `delete` родителя, потомков скрывает видимость строк.

/// `change_requests` — доработки (1.3).
const SyncTableSpec changeRequestsSpec = SyncTableSpec(
  name: 'change_requests',
  label: 'Доработка',
  columns: [
    SyncColumn('project_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('amount', SyncColumnType.integer),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('closed_date', SyncColumnType.text, nullable: true),
    SyncColumn('estimate_minutes', SyncColumnType.integer, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('project_id', 'projects')],
  titleOf: _title,
);

/// `payments` — платежи, факт поступления (1.4).
const SyncTableSpec paymentsSpec = SyncTableSpec(
  name: 'payments',
  label: 'Платёж',
  columns: [
    SyncColumn('paid_at', SyncColumnType.datetime),
    SyncColumn('amount', SyncColumnType.integer),
    // Мягкая ссылка на плательщика (`people.id`).
    SyncColumn('payer_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('comment', SyncColumnType.text, nullable: true),
  ],
  titleOf: _paymentTitle,
);

/// `payment_allocations` — распределение платежа (1.5). Менять можно
/// только `amount`: «перенести» = удалить и создать новое.
const SyncTableSpec paymentAllocationsSpec = SyncTableSpec(
  name: 'payment_allocations',
  label: 'Распределение платежа',
  columns: [
    SyncColumn('payment_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('project_id', SyncColumnType.uuid, immutable: true),
    // Мягкая ссылка на доработку; `null` — оплата базовой суммы.
    SyncColumn(
      'change_request_id',
      SyncColumnType.uuid,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('amount', SyncColumnType.integer),
  ],
  parents: [
    SyncRelation('payment_id', 'payments'),
    SyncRelation('project_id', 'projects'),
  ],
  titleOf: _allocationTitle,
);

/// `time_entries` — записи времени; `ended_at` пусто — таймер идёт (1.6).
const SyncTableSpec timeEntriesSpec = SyncTableSpec(
  name: 'time_entries',
  label: 'Запись времени',
  columns: [
    SyncColumn('project_id', SyncColumnType.uuid),
    SyncColumn('change_request_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('task_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('started_at', SyncColumnType.datetime),
    SyncColumn('ended_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('billable', SyncColumnType.boolean),
    SyncColumn('note', SyncColumnType.text, nullable: true),
    SyncColumn('source', SyncColumnType.text),
  ],
  parents: [SyncRelation('project_id', 'projects')],
  titleOf: _entryTitle,
);

/// Все таблицы Этапа 4 в порядке регистрации.
const List<SyncTableSpec> workSyncSpecs = [
  changeRequestsSpec,
  paymentsSpec,
  paymentAllocationsSpec,
  timeEntriesSpec,
];

String _title(Map<String, Object?> row) => '${row['title']}';

String _paymentTitle(Map<String, Object?> row) {
  final comment = row['comment'];
  final day = '${row['paid_at']}'.split('T').first;
  return comment is String && comment.isNotEmpty
      ? 'Платёж $day · $comment'
      : 'Платёж $day';
}

String _allocationTitle(Map<String, Object?> row) => 'Распределение платежа';

String _entryTitle(Map<String, Object?> row) {
  final day = '${row['started_at']}'.split('T').first;
  return 'Время $day';
}
