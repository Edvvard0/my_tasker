"""Synchronised tables of Stage 5 (spec stage5_finance.md, section 2).

Cascades: account -> transactions (both ``account_id`` and ``to_account_id``), balance
checkpoints; debt -> repayments. Categories, goals and every link to people, Work payments,
transactions and debts are soft (plain uuid columns).
"""

from tasker.finance.schema import (
    ACCOUNT_COLUMNS,
    CATEGORY_COLUMNS,
    CHECKPOINT_COLUMNS,
    DEBT_COLUMNS,
    GOAL_COLUMNS,
    REPAYMENT_COLUMNS,
    TRANSACTION_COLUMNS,
    account_problem,
    category_id_rule,
    category_problem,
    checkpoint_problem,
    debt_problem,
    goal_problem,
    repayment_problem,
    transaction_problem,
)
from tasker.sync.registry import SyncTableSpec, define_sync_table
from tasker.tables import metadata

accounts: SyncTableSpec = define_sync_table(
    metadata, "accounts", ACCOUNT_COLUMNS, validators=(account_problem,)
)
categories: SyncTableSpec = define_sync_table(
    metadata,
    "categories",
    CATEGORY_COLUMNS,
    id_rule=category_id_rule,
    validators=(category_problem,),
)
transactions: SyncTableSpec = define_sync_table(
    metadata, "transactions", TRANSACTION_COLUMNS, validators=(transaction_problem,)
)
balance_checkpoints: SyncTableSpec = define_sync_table(
    metadata, "balance_checkpoints", CHECKPOINT_COLUMNS, validators=(checkpoint_problem,)
)
debts: SyncTableSpec = define_sync_table(
    metadata, "debts", DEBT_COLUMNS, validators=(debt_problem,)
)
debt_repayments: SyncTableSpec = define_sync_table(
    metadata, "debt_repayments", REPAYMENT_COLUMNS, validators=(repayment_problem,)
)
goals: SyncTableSpec = define_sync_table(
    metadata, "goals", GOAL_COLUMNS, validators=(goal_problem,)
)

# Parents first.
FINANCE_TABLES: tuple[SyncTableSpec, ...] = (
    accounts,
    categories,
    transactions,
    balance_checkpoints,
    debts,
    debt_repayments,
    goals,
)
