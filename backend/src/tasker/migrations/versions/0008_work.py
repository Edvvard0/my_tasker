"""Stage 4: Work. Extends projects/people, adds change_requests, payments,
payment_allocations and time_entries

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-02
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
NEW_TABLES = ("time_entries", "payment_allocations", "payments", "change_requests")
PROJECT_COLUMNS = (
    "client_id",
    "status",
    "pay_type",
    "base_amount",
    "hourly_rate",
    "start_date",
    "deadline_date",
    "completed_date",
    "description",
    "links",
)
PERSON_COLUMNS = ("role", "contact")


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


def _ref(name: str, parent: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, UUID, sa.ForeignKey(f"{parent}.id"), nullable=nullable)


def upgrade() -> None:
    for column in (
        sa.Column("client_id", UUID, nullable=True),
        _text("status"),
        _text("pay_type"),
        _int("base_amount"),
        _int("hourly_rate"),
        _text("start_date"),
        _text("deadline_date"),
        _text("completed_date"),
        _text("description"),
        sa.Column("links", postgresql.JSONB(none_as_null=False), nullable=True),
    ):
        op.add_column("projects", column)
    op.add_column("people", _text("role"))
    op.add_column("people", _text("contact"))

    _sync_table(
        "change_requests",
        _ref("project_id", "projects"),
        _text("title", nullable=False),
        _int("amount", nullable=False),
        _text("status", nullable=False),
        _text("closed_date"),
        _int("estimate_minutes"),
        _text("note"),
        indexed=("project_id",),
    )
    _sync_table(
        "payments",
        _ts("paid_at", nullable=False),
        _int("amount", nullable=False),
        sa.Column("payer_id", UUID, nullable=True),
        _text("comment"),
    )
    _sync_table(
        "payment_allocations",
        _ref("payment_id", "payments"),
        _ref("project_id", "projects"),
        sa.Column("change_request_id", UUID, nullable=True),
        _int("amount", nullable=False),
        indexed=("payment_id", "project_id"),
    )
    _sync_table(
        "time_entries",
        _ref("project_id", "projects"),
        sa.Column("change_request_id", UUID, nullable=True),
        sa.Column("task_id", UUID, nullable=True),
        _ts("started_at", nullable=False),
        _ts("ended_at"),
        sa.Column("billable", sa.Boolean(), nullable=False),
        _text("note"),
        _text("source", nullable=False),
        indexed=("project_id",),
    )


def downgrade() -> None:
    for name in NEW_TABLES:
        op.drop_table(name)
    for column in PERSON_COLUMNS:
        op.drop_column("people", column)
    for column in PROJECT_COLUMNS:
        op.drop_column("projects", column)
