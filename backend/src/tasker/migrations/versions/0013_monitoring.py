"""Stage 9: Servers, monitoring and Telegram. Adds monitor_servers, monitor_services,
monitor_checks (synchronised) and monitor_results, monitor_rollups, monitor_state,
monitor_incidents, monitor_outbox (server-only)

Revision ID: 0013
Revises: 0012
Create Date: 2026-10-04
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
# Children before parents (drop order).
SYNCED = ("monitor_checks", "monitor_services", "monitor_servers")
SERVER_ONLY = (
    "monitor_outbox",
    "monitor_incidents",
    "monitor_state",
    "monitor_rollups",
    "monitor_results",
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


def upgrade() -> None:
    _sync_table(
        "monitor_servers",
        _text("name", nullable=False),
        _text("host", nullable=False),
        _text("provider"),
        _text("note"),
    )
    _sync_table(
        "monitor_services",
        sa.Column("server_id", UUID, sa.ForeignKey("monitor_servers.id"), nullable=False),
        _text("name", nullable=False),
        sa.Column("work_project_id", UUID),
        sa.Column("critical", sa.Boolean(), nullable=False),
        _text("note"),
        indexed=("server_id",),
    )
    _sync_table(
        "monitor_checks",
        sa.Column("service_id", UUID, sa.ForeignKey("monitor_services.id"), nullable=False),
        _text("kind", nullable=False),
        _text("name", nullable=False),
        _text("url"),
        _text("host"),
        _int("port"),
        _text("dns_record_type"),
        _text("expected_value"),
        _int("expected_status"),
        _text("keyword"),
        _int("ssl_min_days"),
        _int("interval_seconds", nullable=False),
        _int("timeout_seconds", nullable=False),
        indexed=("service_id",),
    )

    op.create_table(
        "monitor_results",
        sa.Column("check_id", UUID, nullable=False),
        sa.Column("at", TS, nullable=False),
        sa.Column("ok", sa.Boolean(), nullable=False),
        _int("duration_ms"),
        _text("error"),
        sa.PrimaryKeyConstraint("check_id", "at"),
    )
    op.create_index("ix_monitor_results_at", "monitor_results", ["at"])
    op.create_table(
        "monitor_rollups",
        sa.Column("check_id", UUID, nullable=False),
        sa.Column("hour_start", TS, nullable=False),
        _int("total", nullable=False),
        _int("ok", nullable=False),
        _int("ms_sum", nullable=False),
        _int("ms_count", nullable=False),
        sa.PrimaryKeyConstraint("check_id", "hour_start"),
    )
    op.create_index("ix_monitor_rollups_hour_start", "monitor_rollups", ["hour_start"])
    op.create_table(
        "monitor_state",
        sa.Column("service_id", UUID, primary_key=True),
        sa.Column("state", postgresql.JSONB(), nullable=False),
        sa.Column("updated_at", TS, nullable=False),
    )
    op.create_table(
        "monitor_incidents",
        sa.Column("id", UUID, primary_key=True),
        sa.Column("service_id", UUID, nullable=False),
        _int("n", nullable=False),
        sa.Column("started_at", TS, nullable=False),
        sa.Column("ended_at", TS),
        _text("reason"),
        sa.Column("check_ids", postgresql.JSONB(), nullable=False),
        sa.UniqueConstraint("service_id", "n", name="uq_monitor_incidents_service_n"),
    )
    op.create_index("ix_monitor_incidents_started_at", "monitor_incidents", ["started_at"])
    op.create_table(
        "monitor_outbox",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), primary_key=True),
        _text("dedup_key", nullable=False),
        _text("kind", nullable=False),
        _text("text", nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("next_attempt_at", TS, nullable=False),
        sa.Column("attempts", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("sent_at", TS),
        _text("last_error"),
        sa.UniqueConstraint("dedup_key", name="uq_monitor_outbox_dedup_key"),
    )
    op.create_index("ix_monitor_outbox_due", "monitor_outbox", ["sent_at", "next_attempt_at"])


def downgrade() -> None:
    for name in (*SERVER_ONLY, *SYNCED):
        op.drop_table(name)
