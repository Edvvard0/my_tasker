"""Synchronised tables of Stage 3 plus the (not synchronised) spend ledger.

Field semantics and validation rules: ``docs/specs/stage3_ai_chat.md`` (section 1).
"""

import dataclasses
import uuid
from collections.abc import Callable, Mapping
from typing import Any

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import TIMESTAMP
from sqlalchemy.dialects.postgresql import UUID as PG_UUID

from tasker.ai import ids
from tasker.sync.registry import (
    ColumnSpec,
    SyncTableSpec,
    bool_column,
    datetime_column,
    define_sync_table,
    enum_column,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid7_id_rule,
    uuid_column,
)
from tasker.tables import metadata

Row = Mapping[str, Any]
Validator = Callable[[Row], str | None]

SEED_KEYS = ("general", "calendar_tasks", "work", "finance", "study", "sleep")
TOPICS = (*SEED_KEYS, "custom")
PROMPT_SOURCES = ("seed", "user", "reset", "rollback")
CONVERSATION_MODES = ("cloud", "local")
MESSAGE_ROLES = ("user", "assistant", "tool", "system")
MESSAGE_STATUSES = ("streaming", "done", "error", "cancelled")
PROPOSAL_STATUSES = ("pending", "approved", "rejected", "edited_approved")
PART_TYPES = ("text", "tool_call", "tool_result", "proposal")

MAX_PROMPT_LENGTH = 20_000
MAX_PARTS = 400
MAX_PARTS_BYTES = 1_048_576
PROPOSAL_ARGUMENTS_BYTES = 16_384  # UTF-8 bytes of the compact JSON (``json_size_bytes``)
MAX_TOOLS = 32
MAX_PRESET_SOURCES = 32
ID_SEED_PATTERN = r"^[a-z][a-z_]{0,31}$"
NAME_PATTERN = r"^[a-z][a-z0-9_]{0,63}$"


def _blank(value: object) -> bool:
    return not str(value).strip()


def _non_blank(field: str) -> Validator:
    def check(row: Row) -> str | None:
        return f"{field} must not be blank" if _blank(row[field]) else None

    return check


def _immutable(column: ColumnSpec) -> ColumnSpec:
    return dataclasses.replace(column, immutable=True)


# ------------------------------------------------------------------ profiles


def _profile_valid(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    if _blank(row["system_prompt"]):
        return "system_prompt must not be blank"
    tools = row["enabled_tools"]
    if not isinstance(tools, list) or len(tools) > MAX_TOOLS:
        return f"enabled_tools must be a list of at most {MAX_TOOLS} names"
    for item in tools:
        if not isinstance(item, str) or not 1 <= len(item) <= 64:
            return "enabled_tools must contain tool names of 1..64 characters"
    if row["seed_key"] is not None and row["seed_key"] not in SEED_KEYS:
        return "unknown seed_key"
    return None


def _profile_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    key = values.get("seed_key")
    if key is None:
        return uuid7_id_rule(row_id, values)
    if key in SEED_KEYS and row_id == ids.profile_id(key):
        return None
    return "a seeded profile id must be uuid5(namespace, seed_key)"


ai_agent_profiles: SyncTableSpec = define_sync_table(
    metadata,
    "ai_agent_profiles",
    (
        text_column(
            "seed_key",
            max_length=32,
            pattern=ID_SEED_PATTERN,
            nullable=True,
            required=False,
            immutable=True,
        ),
        text_column("name", min_length=1, max_length=100),
        enum_column("topic", TOPICS),
        text_column("system_prompt", min_length=1, max_length=MAX_PROMPT_LENGTH),
        int_column("prompt_version", ge=1, le=1_000_000),
        text_column("default_model", max_length=200, nullable=True, required=False),
        json_column("enabled_tools", max_bytes=4096, utf8=True),
        uuid_column("default_context_preset_id", nullable=True, required=False),
        int_column("position", ge=0, le=1000),
    ),
    id_rule=_profile_id_rule,
    validators=(_profile_valid,),
)


# ------------------------------------------------------------------ prompt versions


def _version_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    if row_id == ids.prompt_version_id(values["profile_id"], values["version"]):
        return None
    return "id must be uuid5(namespace, profile_id|version)"


ai_prompt_versions: SyncTableSpec = define_sync_table(
    metadata,
    "ai_prompt_versions",
    (
        reference_column("profile_id", "ai_agent_profiles", immutable=True),
        dataclasses.replace(int_column("version", ge=1, le=1_000_000), immutable=True),
        text_column("text", min_length=1, max_length=MAX_PROMPT_LENGTH),
        enum_column("source", PROMPT_SOURCES),
    ),
    id_rule=_version_id_rule,
    validators=(_non_blank("text"),),
)


# ------------------------------------------------------------------ presets, favourites


def _preset_valid(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    sources = row["sources"]
    if not isinstance(sources, list) or len(sources) > MAX_PRESET_SOURCES:
        return f"sources must be a list of at most {MAX_PRESET_SOURCES} objects"
    if not all(isinstance(item, dict) for item in sources):
        return "every source must be an object"
    return None


ai_context_presets: SyncTableSpec = define_sync_table(
    metadata,
    "ai_context_presets",
    (
        text_column("name", min_length=1, max_length=100),
        json_column("sources", max_bytes=16384, utf8=True),
        bool_column("sensitive"),
    ),
    validators=(_preset_valid,),
)


def _favorite_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    if row_id == ids.favorite_id(values["model_id"]):
        return None
    return "id must be uuid5(namespace, model_id)"


ai_model_favorites: SyncTableSpec = define_sync_table(
    metadata,
    "ai_model_favorites",
    (
        text_column("model_id", min_length=1, max_length=200, immutable=True),
        text_column("display_name", min_length=1, max_length=200),
        int_column("position", ge=0, le=1000),
        bool_column("supports_tools"),
    ),
    id_rule=_favorite_id_rule,
    validators=(_non_blank("model_id"),),
)


# ------------------------------------------------------------------ conversations, messages


ai_conversations: SyncTableSpec = define_sync_table(
    metadata,
    "ai_conversations",
    (
        text_column("title", min_length=0, max_length=200),
        enum_column("topic", TOPICS),
        uuid_column("agent_id", nullable=True, required=False),
        text_column("model", max_length=200, nullable=True, required=False),
        uuid_column("context_preset_id", nullable=True, required=False),
        bool_column("pinned"),
        bool_column("archived"),
        enum_column("mode", CONVERSATION_MODES),
    ),
)


def _parts_problem(parts: object) -> str | None:
    if not isinstance(parts, list) or len(parts) > MAX_PARTS:
        return f"parts must be a list of at most {MAX_PARTS} objects"
    for part in parts:
        if not isinstance(part, dict) or part.get("type") not in PART_TYPES:
            return "every part must be an object with a known type"
        if part["type"] == "text" and not isinstance(part.get("text"), str):
            return "a text part needs a string text"
    return None


def _message_valid(row: Row) -> str | None:
    return _parts_problem(row["parts"])


def _non_negative(name: str) -> ColumnSpec:
    return int_column(name, ge=0, le=2**53, nullable=True, required=False)


ai_messages: SyncTableSpec = define_sync_table(
    metadata,
    "ai_messages",
    (
        reference_column("conversation_id", "ai_conversations", immutable=True),
        _immutable(enum_column("role", MESSAGE_ROLES)),
        text_column("text", max_length=400_000),
        json_column("parts", max_bytes=MAX_PARTS_BYTES, utf8=True),
        enum_column("status", MESSAGE_STATUSES),
        text_column("model", max_length=200, nullable=True, required=False),
        uuid_column("agent_id", nullable=True, required=False),
        int_column("prompt_version", ge=1, le=1_000_000, nullable=True, required=False),
        _non_negative("prompt_tokens"),
        _non_negative("completion_tokens"),
        _non_negative("cost_kopecks"),
        _non_negative("latency_ms"),
        text_column("finish_reason", max_length=64, nullable=True, required=False),
        text_column("error_code", max_length=64, nullable=True, required=False),
    ),
    validators=(_message_valid,),
)


# ------------------------------------------------------------------ proposals


def _proposal_valid(row: Row) -> str | None:
    if not isinstance(row["arguments"], dict) or not isinstance(row["original_arguments"], dict):
        return "arguments and original_arguments must be objects"
    if row["status"] == "pending":
        return "pending proposals must not have decided_at" if row["decided_at"] else None
    if row["decided_at"] is None:
        return "a decided proposal needs decided_at"
    return None


ai_tool_proposals: SyncTableSpec = define_sync_table(
    metadata,
    "ai_tool_proposals",
    (
        reference_column("message_id", "ai_messages", immutable=True),
        text_column("tool_call_id", min_length=1, max_length=128, immutable=True),
        text_column("tool", min_length=1, max_length=64, pattern=NAME_PATTERN, immutable=True),
        text_column(
            "entity_type", min_length=1, max_length=64, pattern=NAME_PATTERN, immutable=True
        ),
        uuid_column("entity_id", immutable=True),
        _immutable(
            json_column("original_arguments", max_bytes=PROPOSAL_ARGUMENTS_BYTES, utf8=True)
        ),
        json_column("arguments", max_bytes=PROPOSAL_ARGUMENTS_BYTES, utf8=True),
        enum_column("status", PROPOSAL_STATUSES),
        text_column("reject_reason", max_length=1000, nullable=True, required=False),
        datetime_column("decided_at", nullable=True, required=False),
    ),
    validators=(_proposal_valid,),
)


# Parents first: the registry and the purge order depend on it.
AI_TABLES: tuple[SyncTableSpec, ...] = (
    ai_agent_profiles,
    ai_prompt_versions,
    ai_context_presets,
    ai_model_favorites,
    ai_conversations,
    ai_messages,
    ai_tool_proposals,
)

# Spend ledger: one row per call to the model. Not synchronised, and independent of the messages
# (deleting a chat must not give the money back).
ai_spend = sa.Table(
    "ai_spend",
    metadata,
    sa.Column("id", PG_UUID(as_uuid=True), primary_key=True),
    sa.Column("created_at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("message_id", PG_UUID(as_uuid=True), nullable=False),
    sa.Column("model", sa.Text, nullable=False),
    sa.Column("prompt_tokens", sa.BigInteger, nullable=False),
    sa.Column("completion_tokens", sa.BigInteger, nullable=False),
    sa.Column("cost_kopecks", sa.BigInteger, nullable=False),
    sa.Column("estimated", sa.Boolean, nullable=False),
)
sa.Index("ai_spend_created_at", ai_spend.c.created_at)
