"""Stage 3: AI chat tables (agents, prompt versions, presets, favourites, chats, messages,
tool proposals) and the spend ledger

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-01
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
TABLES = (
    "ai_tool_proposals",
    "ai_messages",
    "ai_conversations",
    "ai_model_favorites",
    "ai_context_presets",
    "ai_prompt_versions",
    "ai_agent_profiles",
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


def _text(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, sa.Text(), nullable=nullable)


def _bool(name: str) -> sa.Column[Any]:
    return sa.Column(name, sa.Boolean(), nullable=False)


def _int(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, sa.BigInteger(), nullable=nullable)


def _json(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, postgresql.JSONB(none_as_null=False), nullable=nullable)


def _uuid(name: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, UUID, nullable=nullable)


def _ref(name: str, parent: str) -> sa.Column[Any]:
    return sa.Column(name, UUID, sa.ForeignKey(f"{parent}.id"), nullable=False)


def upgrade() -> None:
    _sync_table(
        "ai_agent_profiles",
        _text("seed_key", nullable=True),
        _text("name"),
        _text("topic"),
        _text("system_prompt"),
        _int("prompt_version"),
        _text("default_model", nullable=True),
        _json("enabled_tools"),
        _uuid("default_context_preset_id", nullable=True),
        _int("position"),
    )
    _sync_table(
        "ai_prompt_versions",
        _ref("profile_id", "ai_agent_profiles"),
        _int("version"),
        _text("text"),
        _text("source"),
        indexed=("profile_id",),
    )
    _sync_table("ai_context_presets", _text("name"), _json("sources"), _bool("sensitive"))
    _sync_table(
        "ai_model_favorites",
        _text("model_id"),
        _text("display_name"),
        _int("position"),
        _bool("supports_tools"),
    )
    _sync_table(
        "ai_conversations",
        _text("title"),
        _text("topic"),
        _uuid("agent_id", nullable=True),
        _text("model", nullable=True),
        _uuid("context_preset_id", nullable=True),
        _bool("pinned"),
        _bool("archived"),
        _text("mode"),
    )
    _sync_table(
        "ai_messages",
        _ref("conversation_id", "ai_conversations"),
        _text("role"),
        _text("text"),
        _json("parts"),
        _text("status"),
        _text("model", nullable=True),
        _uuid("agent_id", nullable=True),
        _int("prompt_version", nullable=True),
        _int("prompt_tokens", nullable=True),
        _int("completion_tokens", nullable=True),
        _int("cost_kopecks", nullable=True),
        _int("latency_ms", nullable=True),
        _text("finish_reason", nullable=True),
        _text("error_code", nullable=True),
        indexed=("conversation_id",),
    )
    _sync_table(
        "ai_tool_proposals",
        _ref("message_id", "ai_messages"),
        _text("tool_call_id"),
        _text("tool"),
        _text("entity_type"),
        _uuid("entity_id"),
        _json("original_arguments"),
        _json("arguments"),
        _text("status"),
        _text("reject_reason", nullable=True),
        sa.Column("decided_at", TS, nullable=True),
        indexed=("message_id",),
    )
    op.create_table(
        "ai_spend",
        sa.Column("id", UUID, primary_key=True),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("message_id", UUID, nullable=False),
        sa.Column("model", sa.Text(), nullable=False),
        sa.Column("prompt_tokens", sa.BigInteger(), nullable=False),
        sa.Column("completion_tokens", sa.BigInteger(), nullable=False),
        sa.Column("cost_kopecks", sa.BigInteger(), nullable=False),
        sa.Column("estimated", sa.Boolean(), nullable=False),
    )
    op.create_index("ai_spend_created_at", "ai_spend", ["created_at"])


def downgrade() -> None:
    op.drop_table("ai_spend")
    for name in TABLES:
        op.drop_table(name)
