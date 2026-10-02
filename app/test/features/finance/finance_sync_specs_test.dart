import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/finance/data/finance_sync_specs.dart';

/// Описания таблиц Финансов совпадают с реестром сервера
/// (`backend/src/tasker/finance/{schema,tables}.py`, spec Этапа 5, 1 и 2).
void main() {
  final schema = File('../backend/src/tasker/finance/schema.py')
      .readAsStringSync();

  /// Имена колонок блока `<NAME>_COLUMNS` в порядке объявления.
  List<String> serverColumns(String block) {
    final start = schema.indexOf('$block: tuple[ColumnSpec, ...] = (');
    expect(start, greaterThanOrEqualTo(0), reason: block);
    final end =
        start +
        RegExp(r'\r?\n\)\r?\n').firstMatch(schema.substring(start))!.end;
    final body = schema.substring(start, end);
    return [
      for (final m in RegExp(r'\b\w+\(\s*"([a-z_0-9]+)"').allMatches(body))
        m.group(1)!,
    ];
  }

  const blocks = {
    'accounts': 'ACCOUNT_COLUMNS',
    'categories': 'CATEGORY_COLUMNS',
    'transactions': 'TRANSACTION_COLUMNS',
    'balance_checkpoints': 'CHECKPOINT_COLUMNS',
    'debts': 'DEBT_COLUMNS',
    'debt_repayments': 'REPAYMENT_COLUMNS',
    'goals': 'GOAL_COLUMNS',
  };

  test('семь таблиц в порядке сервера, колонки как на сервере', () {
    expect(financeSyncSpecs.map((s) => s.name), blocks.keys.toList());
    for (final spec in financeSyncSpecs) {
      expect(
        spec.columns.map((c) => c.name).toList(),
        serverColumns(blocks[spec.name]!),
        reason: spec.name,
      );
    }
  });

  test('порядок реестра сервера: tables.py', () {
    final tables = File('../backend/src/tasker/finance/tables.py')
        .readAsStringSync();
    final order = RegExp(r'FINANCE_TABLES[^=]*= \(([^)]*)\)')
        .firstMatch(tables)!
        .group(1)!;
    expect(
      [for (final n in order.split(',')) n.trim()].where((n) => n.isNotEmpty),
      blocks.keys,
    );
  });

  test('родители и каскады: spec 2', () {
    Map<String, String> parents(SyncTableSpec s) => {
      for (final p in s.parents) p.column: p.parentTable,
    };
    expect(parents(accountsSpec), isEmpty);
    expect(
      parents(categoriesSpec),
      isEmpty,
      reason: 'parent_id — мягкая ссылка',
    );
    expect(parents(transactionsSpec), {
      'account_id': 'accounts',
      'to_account_id': 'accounts',
    });
    expect(parents(balanceCheckpointsSpec), {'account_id': 'accounts'});
    expect(parents(debtsSpec), isEmpty);
    expect(parents(debtRepaymentsSpec), {'debt_id': 'debts'});
    expect(parents(goalsSpec), isEmpty);
  });

  test('неизменяемые и обязательные колонки', () {
    Set<String> immutable(SyncTableSpec s) => {
      for (final c in s.columns)
        if (c.immutable) c.name,
    };
    expect(immutable(accountsSpec), isEmpty);
    expect(immutable(categoriesSpec), {'system_key'});
    expect(immutable(transactionsSpec), isEmpty);
    expect(immutable(balanceCheckpointsSpec), {'account_id'});
    expect(immutable(debtRepaymentsSpec), {'debt_id'});
    SyncColumn column(SyncTableSpec s, String name) => s.column(name)!;
    expect(
      column(transactionsSpec, 'occurred_at').type,
      SyncColumnType.datetime,
    );
    expect(column(goalsSpec, 'formula').type, SyncColumnType.json);
    expect(column(accountsSpec, 'credit_limit').nullable, isTrue);
    expect(column(accountsSpec, 'opening_balance').nullable, isFalse);
    expect(column(transactionsSpec, 'to_account_id').nullable, isTrue);
    expect(column(transactionsSpec, 'account_id').nullable, isFalse);
  });

  test('все семь зарегистрированы в приложении', () {
    final registry = SyncRegistry(registeredSyncTables);
    for (final name in blocks.keys) {
      expect(registry.contains(name), isTrue, reason: name);
    }
  });

  test('заголовки строк в корзине', () {
    expect(accountsSpec.titleOf({'name': 'Карта'}), 'Карта');
    expect(
      transactionsSpec.titleOf({
        'kind': 'expense',
        'amount': 150000,
        'merchant': ' Магнит ',
      }),
      'Расход 1 500 ₽ · Магнит',
    );
    expect(
      transactionsSpec.titleOf({
        'kind': 'income',
        'amount': 100,
        'merchant': null,
      }),
      'Доход 1 ₽',
    );
    expect(
      transactionsSpec.titleOf({
        'kind': 'transfer',
        'amount': 5,
        'merchant': '',
      }),
      'Перевод 0,05 ₽',
    );
    expect(
      transactionsSpec.titleOf({'kind': 'expense', 'amount': 100000000000000}),
      'Расход 100000000000000 коп.',
    );
    expect(
      transactionsSpec.titleOf({'kind': 'expense', 'amount': 'x'}),
      'Расход ',
    );
    expect(
      balanceCheckpointsSpec.titleOf({
        'checked_at': '2026-10-05T09:00:00Z',
        'actual_balance': 90000,
      }),
      'Сверка 2026-10-05: 900 ₽',
    );
    expect(
      balanceCheckpointsSpec.titleOf({'checked_at': 'x', 'actual_balance': 1}),
      'Сверка x: 0,01 ₽',
    );
    expect(
      debtsSpec.titleOf({
        'direction': 'owed_to_me',
        'counterparty': 'Рома',
        'amount': 750000,
      }),
      'Мне должны: Рома, 7 500 ₽',
    );
    expect(
      debtsSpec.titleOf({
        'direction': 'i_owe',
        'counterparty': null,
        'amount': 100,
      }),
      'Я должен: без имени, 1 ₽',
    );
    expect(
      debtRepaymentsSpec.titleOf({'amount': 60000, 'repaid_on': '2026-10-01'}),
      'Погашение 600 ₽ от 2026-10-01',
    );
    expect(goalsSpec.titleOf({'name': 'Отпуск'}), 'Отпуск');
    expect(categoriesSpec.titleOf({'name': 'Еда'}), 'Еда');
  });
}
