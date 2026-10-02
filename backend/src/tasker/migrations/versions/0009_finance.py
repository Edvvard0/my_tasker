"""Stage 5: Finance. Adds accounts, categories, transactions, balance_checkpoints, debts,
debt_repayments and goals

Revision ID: 0009
Revises: 0008
Create Date: 2026-10-02
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
# Children before parents (drop order).
NEW_TABLES = (
    "goals",
    "debt_repayments",
    "debts",
    "balance_checkpoints",
    "transactions",
    "categories",
    "accounts",
)


def _sync_table(name: str, *columns: sa.Column[Any], indexed: Sequence[str] = ()) -> None:
    """A synchronised table: the six service columns, ``field_meta``, then its own columns."""
    op.create_table(
        name,
        sa.Column("id", UUID, primary_key=True),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("updated_at", sa.Text(), nullable=False),
        sa.Column("deleted_at", TS),
        sa.Column("server_version", sa.BigInteger(), nullable=False),
        sa.Column("origin_device_id", UUID, nullable=False),
        sa.Column("field_meta", postgresql.JSONB(), nullable=False, server_default="{}"),
        *columns,
    )
    op.create_index(f"ix_{name}_server_version", name, ["server_version"])
    op.create_index(
        f"{name}_tombstones",
        name,
        ["deleted_at"],
        postgresql_where=sa.text("deleted_at IS NOT NULL"),
    )
    for column in indexed:
        op.create_index(f"ix_{name}_{column}", name, [column])


def _text(name: str, *, nullable: bool = True) -> sa.Column[Any]:
    return sa.Column(name, sa.Text(), nullable=nullable)


def _int(name: str, *, nullable: bool = True) -> sa.Column[Any]:
    return sa.Column(name, sa.BigInteger(), nullable=nullable)


def _ts(name: str, *, nullable: bool = True) -> sa.Column[Any]:
    return sa.Column(name, TS, nullable=nullable)


def _bool(name: str) -> sa.Column[Any]:
    return sa.Column(name, sa.Boolean(), nullable=False)


def _uuid(name: str) -> sa.Column[Any]:
    return sa.Column(name, UUID, nullable=True)


def _ref(name: str, parent: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, UUID, sa.ForeignKey(f"{parent}.id"), nullable=nullable)


def upgrade() -> None:
    _sync_table(
        "accounts",
        _text("name", nullable=False),
        _text("kind", nullable=False),
        _text("bank"),
        _text("card_last4"),
        _int("opening_balance", nullable=False),
        _text("opening_date", nullable=False),
        _bool("include_in_total"),
        _int("credit_limit"),
        _bool("archived"),
    )
    _sync_table(
        "categories",
        _text("name", nullable=False),
        _text("kind", nullable=False),
        _uuid("parent_id"),
        _text("icon"),
        _text("color"),
        _text("system_key"),
    )
    _sync_table(
        "transactions",
        _text("kind", nullable=False),
        _ref("account_id", "accounts"),
        _ref("to_account_id", "accounts", nullable=True),
        _int("amount", nullable=False),
        _ts("occurred_at", nullable=False),
        _uuid("category_id"),
        _text("merchant"),
        _text("comment"),
        _text("source", nullable=False),
        _text("status", nullable=False),
        _text("external_id"),
        _text("dedup_hash"),
        _uuid("work_payment_id"),
        _uuid("debt_id"),
        indexed=("account_id", "to_account_id"),
    )
    _sync_table(
        "balance_checkpoints",
        _ref("account_id", "accounts"),
        _ts("checked_at", nullable=False),
        _int("actual_balance", nullable=False),
        _text("source", nullable=False),
        _text("note"),
        indexed=("account_id",),
    )
    _sync_table(
        "debts",
        _text("direction", nullable=False),
        _uuid("person_id"),
        _text("counterparty"),
        _int("amount", nullable=False),
        _text("debt_date", nullable=False),
        _text("due_date"),
        _text("comment"),
    )
    _sync_table(
        "debt_repayments",
        _ref("debt_id", "debts"),
        _int("amount", nullable=False),
        _text("repaid_on", nullable=False),
        _uuid("transaction_id"),
        _text("note"),
        indexed=("debt_id",),
    )
    _sync_table(
        "goals",
        _text("name", nullable=False),
        _int("target_amount", nullable=False),
        _text("deadline_date"),
        sa.Column("formula", postgresql.JSONB(none_as_null=False), nullable=False),
        _bool("archived"),
    )


def downgrade() -> None:
    for name in NEW_TABLES:
        op.drop_table(name)
