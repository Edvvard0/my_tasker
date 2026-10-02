"""Columns and validators of the Stage 4 tables (spec: ``docs/specs/stage4_work.md``).

Kept free of ``tasker.calendar.tables`` so that the Stage 2 declarations of ``projects`` and
``people`` can import the extra columns from here without a cycle.
"""

from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

from tasker.calendar.timefmt import DATE_PATTERN, parse_date
from tasker.money import MAX_KOPECKS
from tasker.sync.registry import (
    ColumnSpec,
    bool_column,
    datetime_column,
    enum_column,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid_column,
)

Row = Mapping[str, Any]

PROJECT_STATUSES = ("lead", "active", "paused", "completed", "cancelled")
PAY_TYPES = ("fixed", "hourly")
PERSON_ROLES = ("client", "other")
CHANGE_REQUEST_STATUSES = ("in_progress", "closed", "cancelled")
TIME_ENTRY_SOURCES = ("timer", "manual")
ARCHIVABLE_STATUSES = ("completed", "cancelled")

MAX_LINKS = 20
MAX_ENTRY_DAYS = 14
WORK_EPOCH = datetime(2015, 1, 1, tzinfo=UTC)  # Moscow is UTC+3 without DST from here on
MAX_ESTIMATE_MINUTES = 600_000


def _date_column(name: str) -> ColumnSpec:
    return text_column(
        name, min_length=10, max_length=10, pattern=DATE_PATTERN, nullable=True, required=False
    )


def _money(name: str, *, positive: bool = False, required: bool = False) -> ColumnSpec:
    return int_column(
        name,
        ge=1 if positive else 0,
        le=MAX_KOPECKS,
        nullable=not required,
        required=required,
    )


def moment_ok(value: object) -> bool:
    return isinstance(value, datetime) and value >= WORK_EPOCH


# ------------------------------------------------------------------ projects, people (extension)

PROJECT_EXTRA_COLUMNS: tuple[ColumnSpec, ...] = (
    uuid_column("client_id", nullable=True, required=False),
    enum_column("status", PROJECT_STATUSES, nullable=True, required=False),
    enum_column("pay_type", PAY_TYPES, nullable=True, required=False),
    _money("base_amount"),
    _money("hourly_rate"),
    _date_column("start_date"),
    _date_column("deadline_date"),
    _date_column("completed_date"),
    text_column("description", max_length=10000, nullable=True, required=False),
    json_column("links", max_bytes=8192, nullable=True, required=False),
)

PERSON_EXTRA_COLUMNS: tuple[ColumnSpec, ...] = (
    enum_column("role", PERSON_ROLES, nullable=True, required=False),
    text_column("contact", max_length=500, nullable=True, required=False),
)


def links_problem(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) > MAX_LINKS:
        return f"links must be a list of at most {MAX_LINKS} items"
    for item in value:
        if not isinstance(item, dict) or set(item) - {"title", "url"} or "url" not in item:
            return "a link is an object with url and optional title"
        url, title = item["url"], item.get("title", "")
        if not isinstance(url, str) or not 1 <= len(url) <= 500:
            return "a link url must be 1..500 characters"
        if not url.startswith(("http://", "https://")):
            return "a link url must start with http:// or https://"
        if not isinstance(title, str) or len(title) > 100:
            return "a link title must be a string of at most 100 characters"
    return None


def project_problem(row: Row) -> str | None:
    status = row["status"]
    if row["archived"] and status is not None and status not in ARCHIVABLE_STATUSES:
        return "only a completed or cancelled project can be archived"
    if row["pay_type"] == "hourly" and row["hourly_rate"] is None:
        return "an hourly project needs hourly_rate"
    if status == "completed" and row["completed_date"] is None:
        return "a completed project needs completed_date"
    start = row["start_date"]
    for name in ("start_date", "deadline_date", "completed_date"):
        if row[name] is not None and parse_date(row[name]) is None:
            return f"{name} must be a real date"
    if start is not None:
        for name in ("deadline_date", "completed_date"):
            if row[name] is not None and row[name] < start:
                return f"{name} must not be before start_date"
    return links_problem(row["links"])


# ------------------------------------------------------------------ change_requests

CHANGE_REQUEST_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("project_id", "projects", immutable=True),
    text_column("title", min_length=1, max_length=300),
    _money("amount", required=True),
    enum_column("status", CHANGE_REQUEST_STATUSES),
    _date_column("closed_date"),
    int_column("estimate_minutes", ge=0, le=MAX_ESTIMATE_MINUTES, nullable=True, required=False),
    text_column("note", max_length=5000, nullable=True, required=False),
)


def change_request_problem(row: Row) -> str | None:
    if not str(row["title"]).strip():
        return "title must not be blank"
    if row["closed_date"] is not None and parse_date(row["closed_date"]) is None:
        return "closed_date must be a real date"
    if row["status"] == "closed" and row["closed_date"] is None:
        return "a closed change request needs closed_date"
    return None


# ------------------------------------------------------------------ payments, allocations

PAYMENT_COLUMNS: tuple[ColumnSpec, ...] = (
    datetime_column("paid_at"),
    _money("amount", positive=True, required=True),
    uuid_column("payer_id", nullable=True, required=False),
    text_column("comment", max_length=2000, nullable=True, required=False),
)


def payment_problem(row: Row) -> str | None:
    if not moment_ok(row["paid_at"]):
        return "paid_at must not be before 2015-01-01"
    return None


ALLOCATION_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("payment_id", "payments", immutable=True),
    reference_column("project_id", "projects", immutable=True),
    uuid_column("change_request_id", nullable=True, required=False, immutable=True),
    _money("amount", positive=True, required=True),
)


# ------------------------------------------------------------------ time_entries

TIME_ENTRY_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("project_id", "projects"),
    uuid_column("change_request_id", nullable=True, required=False),
    uuid_column("task_id", nullable=True, required=False),
    datetime_column("started_at"),
    datetime_column("ended_at", nullable=True, required=False),
    bool_column("billable"),
    text_column("note", max_length=2000, nullable=True, required=False),
    enum_column("source", TIME_ENTRY_SOURCES),
)


def time_entry_problem(row: Row) -> str | None:
    start, end = row["started_at"], row["ended_at"]
    if not moment_ok(start):
        return "started_at must not be before 2015-01-01"
    if end is None:
        return "a manual entry needs ended_at" if row["source"] == "manual" else None
    if end < start:
        return "ended_at must not be before started_at"
    if (end - start).days >= MAX_ENTRY_DAYS:
        return f"an entry cannot last {MAX_ENTRY_DAYS} days or longer"
    return None
