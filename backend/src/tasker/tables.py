"""SQLAlchemy Core definitions of the non-synced tables (queries only; alembic is hand-written)."""

from typing import Any

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, TIMESTAMP, UUID

metadata = sa.MetaData()


def _ts(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, TIMESTAMP(timezone=True), nullable=nullable)


users = sa.Table(
    "users",
    metadata,
    sa.Column("id", UUID(as_uuid=True), primary_key=True),
    sa.Column("password_hash", sa.Text, nullable=False),
    sa.Column("totp_secret_enc", sa.Text, nullable=False),
    sa.Column("totp_last_step", sa.BigInteger, nullable=False, server_default="0"),
    _ts("created_at"),
    _ts("updated_at"),
)

devices = sa.Table(
    "devices",
    metadata,
    sa.Column("id", UUID(as_uuid=True), primary_key=True),
    sa.Column("name", sa.Text, nullable=False),
    sa.Column("platform", sa.Text, nullable=False),
    sa.Column("app_version", sa.Text),
    _ts("created_at"),
    _ts("last_seen_at"),
    sa.Column("last_pulled_version", sa.BigInteger, nullable=False, server_default="0"),
    sa.Column("refresh_token_hash", sa.Text, nullable=False),
    _ts("refresh_expires_at"),
    _ts("revoked_at", nullable=True),
    sa.Column("revoked_reason", sa.Text),
)

login_failures = sa.Table(
    "login_failures",
    metadata,
    sa.Column("scope", sa.Text, primary_key=True),
    sa.Column("key", sa.Text, primary_key=True),
    sa.Column("failures", sa.Integer, nullable=False),
    _ts("last_failure_at"),
    _ts("locked_until", nullable=True),
)

sync_state = sa.Table(
    "sync_state",
    metadata,
    sa.Column("id", sa.SmallInteger, primary_key=True),
    sa.Column("head_version", sa.BigInteger, nullable=False),
    sa.Column("purge_watermark", sa.BigInteger, nullable=False),
)

sync_ops = sa.Table(
    "sync_ops",
    metadata,
    sa.Column("op_id", UUID(as_uuid=True), primary_key=True),
    sa.Column("device_id", UUID(as_uuid=True), nullable=False),
    sa.Column("result", JSONB, nullable=False),
    _ts("created_at"),
)

sync_conflicts = sa.Table(
    "sync_conflicts",
    metadata,
    sa.Column("id", UUID(as_uuid=True), primary_key=True),
    _ts("created_at"),
    sa.Column("table_name", sa.Text, nullable=False),
    sa.Column("row_id", UUID(as_uuid=True), nullable=False),
    sa.Column("field", sa.Text, nullable=False),
    sa.Column("kind", sa.Text, nullable=False),
    sa.Column("losing_value", JSONB(none_as_null=False)),
    sa.Column("winning_value", JSONB(none_as_null=False)),
    sa.Column("losing_device_id", UUID(as_uuid=True)),
    sa.Column("winning_device_id", UUID(as_uuid=True)),
    sa.Column("losing_hlc", sa.Text),
    sa.Column("winning_hlc", sa.Text),
    sa.Column("op_id", UUID(as_uuid=True)),
    _ts("reverted_at", nullable=True),
)
