"""Stage 8: Sleep and daily rituals. Adds sleep_entries, daily_plans and evening_checkins

Revision ID: 0012
Revises: 0011
Create Date: 2026-10-04
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
NEW_TABLES = ("evening_checkins", "daily_plans", "sleep_entries")


def _sync_table(name: str, *columns: sa.Column[Any]) -> None:
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


def _json(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, postgresql.JSONB(none_as_null=False), nullable=nullable)


def upgrade() -> None:
    _sync_table(
        "sleep_entries",
        sa.Column("date", sa.Text(), nullable=False),
        sa.Column("bed_at", TS, nullable=False),
        sa.Column("wake_at", TS, nullable=False),
        sa.Column("bed_tz", sa.Text()),
        sa.Column("wake_tz", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("quality", sa.BigInteger()),
        sa.Column("note", sa.Text()),
    )
    _sync_table(
        "daily_plans",
        sa.Column("date", sa.Text(), nullable=False),
        _json("task_ids"),
        sa.Column("main_task_id", UUID),
        sa.Column("note", sa.Text()),
    )
    _sync_table(
        "evening_checkins",
        sa.Column("date", sa.Text(), nullable=False),
        sa.Column("rating", sa.BigInteger()),
        _json("done_task_ids"),
        _json("carry_over"),
        sa.Column("note", sa.Text()),
    )


def downgrade() -> None:
    for name in NEW_TABLES:
        op.drop_table(name)
