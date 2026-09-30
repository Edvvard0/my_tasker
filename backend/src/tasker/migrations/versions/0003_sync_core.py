"""sync core: head counter, processed-op journal, conflict log

Revision ID: 0003
Revises: 0002
Create Date: 2026-09-30
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "sync_state",
        sa.Column("id", sa.SmallInteger(), primary_key=True),
        sa.Column("head_version", sa.BigInteger(), nullable=False),
        sa.Column("purge_watermark", sa.BigInteger(), nullable=False),
        sa.CheckConstraint("id = 1", name="sync_state_singleton"),
    )
    op.execute("INSERT INTO sync_state (id, head_version, purge_watermark) VALUES (1, 0, 0)")

    op.create_table(
        "sync_ops",
        sa.Column("op_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("device_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("sync_ops_created_at", "sync_ops", ["created_at"])

    op.create_table(
        "sync_conflicts",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("table_name", sa.Text(), nullable=False),
        sa.Column("row_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("field", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("losing_value", postgresql.JSONB()),
        sa.Column("winning_value", postgresql.JSONB()),
        sa.Column("losing_device_id", postgresql.UUID(as_uuid=True)),
        sa.Column("winning_device_id", postgresql.UUID(as_uuid=True)),
        sa.Column("losing_hlc", sa.Text()),
        sa.Column("winning_hlc", sa.Text()),
        sa.Column("op_id", postgresql.UUID(as_uuid=True)),
        sa.Column("reverted_at", sa.DateTime(timezone=True)),
    )
    op.create_index("sync_conflicts_created_at", "sync_conflicts", ["created_at"])


def downgrade() -> None:
    op.drop_table("sync_conflicts")
    op.drop_table("sync_ops")
    op.drop_table("sync_state")
