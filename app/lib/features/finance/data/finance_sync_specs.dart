import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 5 (spec `stage5_finance.md`, раздел 1).
/// Порядок регистрации — родители вперёд
/// (`backend/src/tasker/finance/tables.py`, `FINANCE_TABLES`).
///
/// Деньги — целые копейки. Каскады делает сервер: удаление счёта уносит
/// его операции (и `account_id`, и `to_account_id`) и точки сверки,
/// удаление долга — погашения; клиент шлёт одну операцию `delete`
/// родителя, потомков скрывает видимость строк. Ссылки на категории,
/// платежи Работы, долги и людей — мягкие (родителями не объявляются).

/// `accounts` — счета (1.1).
const SyncTableSpec accountsSpec = SyncTableSpec(
  name: 'accounts',
  label: 'Счёт',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('kind', SyncColumnType.text),
    SyncColumn('bank', SyncColumnType.text, nullable: true),
    SyncColumn('card_last4', SyncColumnType.text, nullable: true),
    SyncColumn('opening_balance', SyncColumnType.integer),
    SyncColumn('opening_date', SyncColumnType.text),
    SyncColumn('include_in_total', SyncColumnType.boolean),
    SyncColumn('credit_limit', SyncColumnType.integer, nullable: true),
    SyncColumn('archived', SyncColumnType.boolean),
  ],
  titleOf: _name,
);

/// `categories` — категории (1.2). `system_key` неизменяем.
const SyncTableSpec categoriesSpec = SyncTableSpec(
  name: 'categories',
  label: 'Категория',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('kind', SyncColumnType.text),
    // Мягкая ссылка на родителя (3.3): родитель не определяет видимость.
    SyncColumn('parent_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('icon', SyncColumnType.text, nullable: true),
    SyncColumn('color', SyncColumnType.text, nullable: true),
    SyncColumn(
      'system_key',
      SyncColumnType.text,
      nullable: true,
      immutable: true,
    ),
  ],
  titleOf: _name,
);

/// `transactions` — операции (1.3). Перевод привязан к обоим счетам.
const SyncTableSpec transactionsSpec = SyncTableSpec(
  name: 'transactions',
  label: 'Операция',
  columns: [
    SyncColumn('kind', SyncColumnType.text),
    SyncColumn('account_id', SyncColumnType.uuid),
    SyncColumn('to_account_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('amount', SyncColumnType.integer),
    SyncColumn('occurred_at', SyncColumnType.datetime),
    SyncColumn('category_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('merchant', SyncColumnType.text, nullable: true),
    SyncColumn('comment', SyncColumnType.text, nullable: true),
    SyncColumn('source', SyncColumnType.text),
    SyncColumn('status', SyncColumnType.text),
    SyncColumn('external_id', SyncColumnType.text, nullable: true),
    SyncColumn('dedup_hash', SyncColumnType.text, nullable: true),
    SyncColumn('work_payment_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('debt_id', SyncColumnType.uuid, nullable: true),
  ],
  parents: [
    SyncRelation('account_id', 'accounts'),
    SyncRelation('to_account_id', 'accounts'),
  ],
  titleOf: _transactionTitle,
);

/// `balance_checkpoints` — точки сверки; `account_id` неизменяем (1.4).
const SyncTableSpec balanceCheckpointsSpec = SyncTableSpec(
  name: 'balance_checkpoints',
  label: 'Сверка баланса',
  columns: [
    SyncColumn('account_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('checked_at', SyncColumnType.datetime),
    SyncColumn('actual_balance', SyncColumnType.integer),
    SyncColumn('source', SyncColumnType.text),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('account_id', 'accounts')],
  titleOf: _checkpointTitle,
);

/// `debts` — долги (1.5). Статус не хранится: он вычисляется.
const SyncTableSpec debtsSpec = SyncTableSpec(
  name: 'debts',
  label: 'Долг',
  columns: [
    SyncColumn('direction', SyncColumnType.text),
    SyncColumn('person_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('counterparty', SyncColumnType.text, nullable: true),
    SyncColumn('amount', SyncColumnType.integer),
    SyncColumn('debt_date', SyncColumnType.text),
    SyncColumn('due_date', SyncColumnType.text, nullable: true),
    SyncColumn('comment', SyncColumnType.text, nullable: true),
  ],
  titleOf: _debtTitle,
);

/// `debt_repayments` — погашения; `debt_id` неизменяем (1.6).
const SyncTableSpec debtRepaymentsSpec = SyncTableSpec(
  name: 'debt_repayments',
  label: 'Погашение долга',
  columns: [
    SyncColumn('debt_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('amount', SyncColumnType.integer),
    SyncColumn('repaid_on', SyncColumnType.text),
    SyncColumn('transaction_id', SyncColumnType.uuid, nullable: true),
    SyncColumn('note', SyncColumnType.text, nullable: true),
  ],
  parents: [SyncRelation('debt_id', 'debts')],
  titleOf: _repaymentTitle,
);

/// `goals` — цели; `formula` — JSON-список слагаемых (1.7).
const SyncTableSpec goalsSpec = SyncTableSpec(
  name: 'goals',
  label: 'Цель',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('target_amount', SyncColumnType.integer),
    SyncColumn('deadline_date', SyncColumnType.text, nullable: true),
    SyncColumn('formula', SyncColumnType.json),
    SyncColumn('archived', SyncColumnType.boolean),
  ],
  titleOf: _name,
);

/// Все таблицы Этапа 5 в порядке регистрации.
const List<SyncTableSpec> financeSyncSpecs = [
  accountsSpec,
  categoriesSpec,
  transactionsSpec,
  balanceCheckpointsSpec,
  debtsSpec,
  debtRepaymentsSpec,
  goalsSpec,
];

String _name(Map<String, Object?> row) => '${row['name']}';

String _transactionTitle(Map<String, Object?> row) {
  final day = '${row['occurred_at']}'.split('T').first;
  final merchant = row['merchant'];
  final what = switch (row['kind']) {
    'income' => 'Доход',
    'transfer' => 'Перевод',
    _ => 'Расход',
  };
  return merchant is String && merchant.isNotEmpty
      ? '$what $day · $merchant'
      : '$what $day';
}

String _checkpointTitle(Map<String, Object?> row) {
  final day = '${row['checked_at']}'.split('T').first;
  return 'Сверка $day';
}

String _debtTitle(Map<String, Object?> row) {
  final who = row['counterparty'];
  final what = row['direction'] == 'i_owe' ? 'Я должен' : 'Мне должны';
  return who is String && who.isNotEmpty ? '$what · $who' : what;
}

String _repaymentTitle(Map<String, Object?> row) =>
    'Погашение ${row['repaid_on']}';
