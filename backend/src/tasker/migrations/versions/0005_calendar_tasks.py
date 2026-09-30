"""Stage 2: calendars, events, overrides, projects, people, tags, tasks and satellites

Revision ID: 0005
Revises: 0004
Create Date: 2026-09-30
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
TABLES = (
    "task_completions",
    "task_tags",
    "subtasks",
    "tasks",
    "tags",
    "people",
    "projects",
    "event_overrides",
    "events",
    "calendars",
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


def _ts(name: str, *, nullable: bool = True) -> sa.Column[Any]:
    return sa.Column(name, TS, nullable=nullable)


def _json(name: str) -> sa.Column[Any]:
    return sa.Column(name, postgresql.JSONB(none_as_null=False), nullable=True)


def _ref(name: str, parent: str) -> sa.Column[Any]:
    return sa.Column(name, UUID, sa.ForeignKey(f"{parent}.id"), nullable=False)


def upgrade() -> None:
    _sync_table(
        "calendars",
        _text("name"),
        _text("color", nullable=True),
        _text("kind"),
        _text("system_key", nullable=True),
        _bool("visible"),
        _int("position"),
    )
    _sync_table(
        "events",
        _ref("calendar_id", "calendars"),
        _text("title"),
        _text("description", nullable=True),
        _text("location", nullable=True),
        _bool("all_day"),
        _ts("start_at"),
        _ts("end_at"),
        _text("tz", nullable=True),
        _text("start_date", nullable=True),
        _text("end_date", nullable=True),
        _text("rrule", nullable=True),
        _json("reminders"),
        _text("source"),
        indexed=("calendar_id",),
    )
    _sync_table(
        "event_overrides",
        _ref("event_id", "events"),
        _text("original_start"),
        _bool("cancelled"),
        _text("title", nullable=True),
        _text("description", nullable=True),
        _text("location", nullable=True),
        _ts("start_at"),
        _ts("end_at"),
        _text("start_date", nullable=True),
        _text("end_date", nullable=True),
        _json("reminders"),
        indexed=("event_id",),
    )
    _sync_table(
        "projects",
        _text("title"),
        _text("color", nullable=True),
        _bool("archived"),
    )
    _sync_table("people", _text("name"), _bool("archived"))
    _sync_table("tags", _text("name"), _text("color", nullable=True))
    _sync_table(
        "tasks",
        _text("title"),
        _text("notes", nullable=True),
        _text("status"),
        _int("priority", nullable=True),
        _text("due_date", nullable=True),
        _ts("due_at"),
        _text("due_tz", nullable=True),
        _int("duration_minutes", nullable=True),
        _text("rrule", nullable=True),
        _text("recurrence_mode", nullable=True),
        _ts("completed_at"),
        _ts("archived_at"),
        sa.Column("project_id", UUID, nullable=True),
        sa.Column("person_id", UUID, nullable=True),
        _json("reminders"),
        _int("sort_order", nullable=True),
        _text("source"),
    )
    _sync_table(
        "subtasks",
        _ref("task_id", "tasks"),
        _text("title"),
        _bool("done"),
        _int("position"),
        indexed=("task_id",),
    )
    _sync_table(
        "task_tags",
        _ref("task_id", "tasks"),
        _ref("tag_id", "tags"),
        indexed=("task_id", "tag_id"),
    )
    _sync_table(
        "task_completions",
        _ref("task_id", "tasks"),
        _text("instance_date"),
        _text("state"),
        _ts("completed_at", nullable=False),
        indexed=("task_id",),
    )


def downgrade() -> None:
    for name in TABLES:
        op.drop_table(name)
