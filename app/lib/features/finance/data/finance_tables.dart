import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Синхронизируемые таблицы Этапа 5 (spec `stage5_finance.md`, раздел 1).
/// Деньги — целые копейки (`integer` SQLite — 64 бита), моменты — текст
/// `YYYY-MM-DDTHH:MM:SSZ`, даты — `YYYY-MM-DD`. Внешних ключей SQLite нет
/// (как у всех синхронизируемых таблиц): видимость строк считает
/// `SyncStore`.

/// Счета (1.1).
@DataClassName('AccountRow')
class Accounts extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get kind => text()();
  TextColumn get bank => text().nullable()();
  TextColumn get cardLast4 => text().nullable()();
  IntColumn get openingBalance => integer()();
  TextColumn get openingDate => text()();
  BoolColumn get includeInTotal => boolean()();
  IntColumn get creditLimit => integer().nullable()();
  BoolColumn get archived => boolean()();

  @override
  String get tableName => 'accounts';
}

/// Категории (1.2).
@DataClassName('FinCategoryRow')
class Categories extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get kind => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get icon => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get systemKey => text().nullable()();

  @override
  String get tableName => 'categories';
}

/// Операции: расход, доход, перевод (1.3).
@DataClassName('FinTransactionRow')
@TableIndex(name: 'transactions_account_idx', columns: {#accountId})
@TableIndex(name: 'transactions_occurred_idx', columns: {#occurredAt})
class FinTransactions extends Table with SyncColumns {
  TextColumn get kind => text()();
  TextColumn get accountId => text()();
  TextColumn get toAccountId => text().nullable()();
  IntColumn get amount => integer()();
  TextColumn get occurredAt => text()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get merchant => text().nullable()();
  TextColumn get comment => text().nullable()();
  TextColumn get source => text()();
  TextColumn get status => text()();
  TextColumn get externalId => text().nullable()();
  TextColumn get dedupHash => text().nullable()();
  TextColumn get workPaymentId => text().nullable()();
  TextColumn get debtId => text().nullable()();

  @override
  String get tableName => 'transactions';
}

/// Точки сверки баланса (1.4).
@DataClassName('BalanceCheckpointRow')
@TableIndex(name: 'balance_checkpoints_account_idx', columns: {#accountId})
class BalanceCheckpoints extends Table with SyncColumns {
  TextColumn get accountId => text()();
  TextColumn get checkedAt => text()();
  IntColumn get actualBalance => integer()();
  TextColumn get source => text()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'balance_checkpoints';
}

/// Долги (1.5).
@DataClassName('DebtRow')
class Debts extends Table with SyncColumns {
  TextColumn get direction => text()();
  TextColumn get personId => text().nullable()();
  TextColumn get counterparty => text().nullable()();
  IntColumn get amount => integer()();
  TextColumn get debtDate => text()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get comment => text().nullable()();

  @override
  String get tableName => 'debts';
}

/// Погашения долгов (1.6).
@DataClassName('DebtRepaymentRow')
@TableIndex(name: 'debt_repayments_debt_idx', columns: {#debtId})
class DebtRepayments extends Table with SyncColumns {
  TextColumn get debtId => text()();
  IntColumn get amount => integer()();
  TextColumn get repaidOn => text()();
  TextColumn get transactionId => text().nullable()();
  TextColumn get note => text().nullable()();

  @override
  String get tableName => 'debt_repayments';
}

/// Цели с формулой «Есть» (1.7); формула — JSON-текст.
@DataClassName('GoalRow')
class Goals extends Table with SyncColumns {
  TextColumn get name => text()();
  IntColumn get targetAmount => integer()();
  TextColumn get deadlineDate => text().nullable()();
  TextColumn get formula => text()();
  BoolColumn get archived => boolean()();

  @override
  String get tableName => 'goals';
}

// coverage:ignore-end
