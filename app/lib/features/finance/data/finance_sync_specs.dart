import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы Этапа 5 «Финансы» (spec
/// `docs/specs/stage5_finance.md`, разделы 1 и 2; сервер —
/// `backend/src/tasker/finance/tables.py`, `FINANCE_TABLES`).
///
/// Порядок регистрации — родители вперёд. Каскады делает сервер: удаление
/// счёта уносит операции по `account_id` **и** `to_account_id` и точки
/// сверки, удаление долга — его погашения. Мягкие ссылки без родителя:
/// `categories.parent_id`, `transactions.category_id`, `work_payment_id`,
/// `debt_id`, `debts.person_id`, `debt_repayments.transaction_id`.

/// `accounts` — счета (spec 1.1).
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

/// `categories` — категории (spec 1.2); `system_key` неизменяем.
const SyncTableSpec categoriesSpec = SyncTableSpec(
  name: 'categories',
  label: 'Категория',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('kind', SyncColumnType.text),
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

/// `transactions` — операции (spec 1.3); у перевода два счёта-родителя.
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

/// `balance_checkpoints` — точки сверки (spec 1.4); `account_id` неизменяем.
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

/// `debts` — долги (spec 1.5).
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

/// `debt_repayments` — погашения (spec 1.6); `debt_id` неизменяем.
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

/// `goals` — цели (spec 1.7); `formula` — JSON-список слагаемых.
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

/// Все таблицы этапа в порядке реестра сервера.
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

// Заголовки строк видны в корзине и в журнале конфликтов — вне замка
// «Финансов» и режима «скрыть суммы», поэтому суммы в них не попадают
// никогда (тест `hide_amounts_test` следит, чтобы здесь не появилось
// форматирование денег).

String _transactionTitle(Map<String, Object?> row) {
  final kind = switch (row['kind']) {
    'income' => 'Доход',
    'transfer' => 'Перевод',
    _ => 'Расход',
  };
  final merchant = row['merchant'];
  return merchant is String && merchant.trim().isNotEmpty
      ? '$kind · ${merchant.trim()}'
      : kind;
}

/// «Сверка 06.10.2026»: день — московский, как везде в Финансах.
String _checkpointTitle(Map<String, Object?> row) {
  final at = row['checked_at'];
  if (at is! String) return 'Сверка';
  try {
    final day = moscowDate(at); // YYYY-MM-DD
    return 'Сверка ${day.substring(8)}.${day.substring(5, 7)}.'
        '${day.substring(0, 4)}';
  } on FormatException {
    return 'Сверка';
  }
}

String _debtTitle(Map<String, Object?> row) {
  final who = row['counterparty'];
  final name = who is String && who.trim().isNotEmpty ? who : 'без имени';
  final what = row['direction'] == 'i_owe' ? 'Я должен' : 'Мне должны';
  return '$what: $name';
}

String _repaymentTitle(Map<String, Object?> row) =>
    'Погашение от ${row['repaid_on']}';
