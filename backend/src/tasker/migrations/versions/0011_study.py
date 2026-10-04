"""Stage 7: Study. Adds study_semesters, study_subjects, study_bells, class_slots,
study_day_rules, class_overrides, study_attendance, study_debts and attachments

Revision ID: 0011
Revises: 0010
Create Date: 2026-10-04
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)
# Children before parents (drop order).
NEW_TABLES = (
    "attachments",
    "study_debts",
    "study_attendance",
    "class_overrides",
    "study_day_rules",
    "class_slots",
    "study_bells",
    "study_subjects",
    "study_semesters",
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


def _bool(name: str) -> sa.Column[Any]:
    return sa.Column(name, sa.Boolean(), nullable=False)


def _uuid(name: str) -> sa.Column[Any]:
    return sa.Column(name, UUID, nullable=True)


def _ref(name: str, parent: str, *, nullable: bool = False) -> sa.Column[Any]:
    return sa.Column(name, UUID, sa.ForeignKey(f"{parent}.id"), nullable=nullable)


def upgrade() -> None:
    _sync_table(
        "study_semesters",
        _text("name", nullable=False),
        _text("start_date", nullable=False),
        _text("end_date", nullable=False),
        _text("week1_start", nullable=False),
        _int("cycle_length", nullable=False),
        sa.Column("week_shifts", postgresql.JSONB(none_as_null=False), nullable=True),
        _bool("archived"),
    )
    _sync_table(
        "study_subjects",
        _ref("semester_id", "study_semesters"),
        _text("name", nullable=False),
        _text("teacher"),
        _text("building"),
        _text("room"),
        _int("absence_limit"),
        _text("note"),
        _bool("archived"),
        indexed=("semester_id",),
    )
    _sync_table(
        "study_bells",
        _ref("semester_id", "study_semesters"),
        _text("on_date"),
        _int("number", nullable=False),
        _text("start_time", nullable=False),
        _text("end_time", nullable=False),
        indexed=("semester_id",),
    )
    _sync_table(
        "class_slots",
        _ref("semester_id", "study_semesters"),
        _ref("subject_id", "study_subjects", nullable=True),
        _text("title"),
        _int("weekday", nullable=False),
        _int("number"),
        _text("start_time"),
        _text("end_time"),
        _text("kind", nullable=False),
        _text("building"),
        _text("room"),
        _int("cycle_week"),
        indexed=("semester_id", "subject_id"),
    )
    _sync_table(
        "study_day_rules",
        _ref("semester_id", "study_semesters"),
        _int("weekday"),
        _text("on_date"),
        _int("cycle_week"),
        _text("title", nullable=False),
        _bool("hide_regular"),
        sa.Column("items", postgresql.JSONB(none_as_null=False), nullable=False),
        indexed=("semester_id",),
    )
    _sync_table(
        "class_overrides",
        _ref("slot_id", "class_slots"),
        _text("date", nullable=False),
        _text("action", nullable=False),
        _text("new_date"),
        _text("start_time"),
        _text("end_time"),
        _text("building"),
        _text("room"),
        _uuid("subject_id"),
        _text("title"),
        _text("lesson_kind"),
        indexed=("slot_id",),
    )
    _sync_table(
        "study_attendance",
        _ref("slot_id", "class_slots"),
        _text("date", nullable=False),
        _text("status", nullable=False),
        _text("note"),
        indexed=("slot_id",),
    )
    _sync_table(
        "study_debts",
        _ref("subject_id", "study_subjects"),
        _text("kind", nullable=False),
        _text("title", nullable=False),
        _text("status", nullable=False),
        _text("due_date"),
        _text("done_date"),
        _text("note"),
        _uuid("task_id"),
        indexed=("subject_id",),
    )
    _sync_table(
        "attachments",
        _ref("subject_id", "study_subjects", nullable=True),
        _ref("debt_id", "study_debts", nullable=True),
        _text("file_name", nullable=False),
        _text("mime_type", nullable=False),
        _int("size_bytes", nullable=False),
        _text("sha256", nullable=False),
        _text("upload_status", nullable=False),
        indexed=("subject_id", "debt_id"),
    )


def downgrade() -> None:
    for name in NEW_TABLES:
        op.drop_table(name)
