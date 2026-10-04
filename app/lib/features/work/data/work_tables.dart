import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 4 (spec `stage4_work.md`, раздел 1).
/// Деньги — целые копейки (`integer` SQLite — 64 бита), моменты — текст
/// `YYYY-MM-DDTHH:MM:SSZ`. Внешних ключей SQLite нет (как у всех
/// синхронизируемых таблиц): видимость строк считает `SyncStore`.

/// Доработки проекта (1.3).
@DataClassName('ChangeRequestRow')
@TableIndex(name: 'change_requests_project_idx', columns: {#projectId})
class ChangeRequests extends Table with SyncColumns {
  TextColumn get projectId => text()();
  TextColumn get title => text()();
  IntColumn get amount => integer()();
  TextColumn get status => text()();
  TextColumn get closedDate => text().nullable()();
  IntColumn get estimateMinutes => integer().nullable()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'change_requests';
}

/// Платежи — факт поступления (1.4).
@DataClassName('PaymentRow')
@TableIndex(name: 'payments_paid_at_idx', columns: {#paidAt})
class Payments extends Table with SyncColumns {
  TextColumn get paidAt => text()();
  IntColumn get amount => integer()();
  TextColumn get payerId => text().nullable()();
  TextColumn get comment => text().nullable()();

  @override
  String get tableName => 'payments';
}

/// Распределение платежа на проект или доработку (1.5).
@DataClassName('PaymentAllocationRow')
@TableIndex(name: 'payment_allocations_payment_idx', columns: {#paymentId})
@TableIndex(name: 'payment_allocations_project_idx', columns: {#projectId})
class PaymentAllocations extends Table with SyncColumns {
  TextColumn get paymentId => text()();
  TextColumn get projectId => text()();
  TextColumn get changeRequestId => text().nullable()();
  IntColumn get amount => integer()();

  @override
  String get tableName => 'payment_allocations';
}

/// Учёт времени; `ended_at` пусто — таймер идёт (1.6).
@DataClassName('TimeEntryRow')
@TableIndex(name: 'time_entries_project_idx', columns: {#projectId})
@TableIndex(name: 'time_entries_started_idx', columns: {#startedAt})
class TimeEntries extends Table with SyncColumns {
  TextColumn get projectId => text()();
  TextColumn get changeRequestId => text().nullable()();
  TextColumn get taskId => text().nullable()();
  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();
  BoolColumn get billable => boolean()();
  TextColumn get note => text().nullable()();
  TextColumn get source => text()();

  @override
  String get tableName => 'time_entries';
}

// coverage:ignore-end
