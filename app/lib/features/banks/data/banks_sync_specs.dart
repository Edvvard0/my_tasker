import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемая таблица Этапа 6 (spec `stage6_banks.md`, раздел 7;
/// сервер: `backend/src/tasker/banks/tables.py`, `BANKS_TABLES`).
///
/// Родителей нет. `merchant_key`, `match_type` и `kind` неизменяемы;
/// `category_id` — мягкая ссылка на `categories`, меняется свободно.
const SyncTableSpec merchantCategoryRulesSpec = SyncTableSpec(
  name: 'merchant_category_rules',
  label: 'Правило категории',
  columns: [
    SyncColumn('merchant_key', SyncColumnType.text, immutable: true),
    SyncColumn('match_type', SyncColumnType.text, immutable: true),
    SyncColumn('kind', SyncColumnType.text, immutable: true),
    SyncColumn('category_id', SyncColumnType.uuid),
  ],
  titleOf: _ruleTitle,
);

/// Все таблицы Этапа 6 в порядке регистрации.
const List<SyncTableSpec> banksSyncSpecs = [merchantCategoryRulesSpec];

String _ruleTitle(Map<String, Object?> row) =>
    'Категория для «${row['merchant_key']}»';
