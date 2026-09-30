"""auth: users, devices, login_failures

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-30
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _ts(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("totp_secret_enc", sa.Text(), nullable=False),
        sa.Column("totp_last_step", sa.BigInteger(), nullable=False, server_default="0"),
        _ts("created_at"),
        _ts("updated_at"),
    )
    # Exactly one owner: every row has the same constant, so a second row cannot be inserted.
    op.create_index("users_single_owner", "users", [sa.text("(true)")], unique=True)

    op.create_table(
        "devices",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("app_version", sa.Text()),
        _ts("created_at"),
        _ts("last_seen_at"),
        sa.Column("last_pulled_version", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("refresh_token_hash", sa.Text(), nullable=False),
        _ts("refresh_expires_at"),
        _ts("revoked_at", nullable=True),
        sa.Column("revoked_reason", sa.Text()),
    )

    op.create_table(
        "login_failures",
        sa.Column("scope", sa.Text(), primary_key=True),
        sa.Column("key", sa.Text(), primary_key=True),
        sa.Column("failures", sa.Integer(), nullable=False),
        _ts("last_failure_at"),
        _ts("locked_until", nullable=True),
    )


def downgrade() -> None:
    op.drop_table("login_failures")
    op.drop_table("devices")
    op.drop_index("users_single_owner", table_name="users")
    op.drop_table("users")
