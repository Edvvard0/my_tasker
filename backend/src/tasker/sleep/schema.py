"""Columns and validators of the Stage 8 tables (spec: ``docs/specs/stage8_sleep_rituals.md``)."""

import re
import uuid
from collections.abc import Mapping
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from tasker.calendar.ids import namespace
from tasker.calendar.tables import valid_timezone
from tasker.calendar.timefmt import DATE_PATTERN, parse_date
from tasker.sync.registry import (
    ColumnSpec,
    datetime_column,
    enum_column,
    int_column,
    json_column,
    text_column,
    uuid_column,
)

Row = Mapping[str, Any]

SLEEP_SOURCES = ("manual", "morning_notification")
CARRY_TARGETS = ("tomorrow", "date")

MAX_SLEEP_SECONDS = 24 * 3600
MAX_PLAN_TASKS = 10
MAX_CHECKIN_TASKS = 50
_CARRY_KEYS = {"task_id", "to", "date"}


def day_id(table: str, date: str) -> uuid.UUID:
    """One row per date, whatever device writes it: ``uuid5(ns(table), date)``."""
    return uuid.uuid5(namespace(table), date)


def _date_key(name: str = "date") -> ColumnSpec:
    return text_column(
        name, min_length=10, max_length=10, pattern=DATE_PATTERN, required=True, immutable=True
    )


def _day_id_rule(table: str) -> Any:
    def rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
        return None if row_id == day_id(table, values["date"]) else "id must be uuid5(ns, date)"

    return rule


def _note() -> ColumnSpec:
    return text_column("note", max_length=2000, nullable=True, required=False)


def _canonical_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _uuid_list_problem(name: str, value: object, limit: int) -> str | None:
    if not isinstance(value, list) or len(value) > limit:
        return f"{name} must be a list of at most {limit} ids"
    if not all(_canonical_uuid(item) for item in value):
        return f"{name} must hold task ids (lower-case uuid)"
    if len(set(value)) != len(value):
        return f"{name} must not repeat a task"
    return None


# ------------------------------------------------------------------ sleep_entries

SLEEP_COLUMNS: tuple[ColumnSpec, ...] = (
    _date_key(),
    datetime_column("bed_at"),
    datetime_column("wake_at"),
    text_column("bed_tz", max_length=64, nullable=True, required=False),
    text_column("wake_tz", min_length=1, max_length=64),
    enum_column("source", SLEEP_SOURCES),
    int_column("quality", ge=1, le=5, nullable=True, required=False),
    _note(),
)


def local_date(moment: datetime, tz: str) -> str:
    return moment.astimezone(ZoneInfo(tz)).date().isoformat()


def sleep_problem(row: Row) -> str | None:
    if parse_date(row["date"]) is None:
        return "date must be a real date"
    for name in ("wake_tz", "bed_tz"):
        if row[name] is not None and not valid_timezone(row[name]):
            return f"{name} is not a known IANA time zone"
    bed, wake = row["bed_at"], row["wake_at"]
    if wake <= bed:
        return "wake_at must be after bed_at"
    if (wake - bed).total_seconds() > MAX_SLEEP_SECONDS:
        return "a sleep lasts at most 24 hours"
    if local_date(wake, row["wake_tz"]) != row["date"]:
        return "date must be the local date of wake_at in wake_tz"
    return None


# ------------------------------------------------------------------ daily_plans

PLAN_COLUMNS: tuple[ColumnSpec, ...] = (
    _date_key(),
    json_column("task_ids", max_bytes=1024),
    uuid_column("main_task_id", nullable=True, required=False),
    _note(),
)


def plan_problem(row: Row) -> str | None:
    if parse_date(row["date"]) is None:
        return "date must be a real date"
    return _uuid_list_problem("task_ids", row["task_ids"], MAX_PLAN_TASKS)


# ------------------------------------------------------------------ evening_checkins

CHECKIN_COLUMNS: tuple[ColumnSpec, ...] = (
    _date_key(),
    int_column("rating", ge=1, le=5, nullable=True, required=False),
    json_column("done_task_ids", max_bytes=4096),
    json_column("carry_over", max_bytes=8192),
    _note(),
)


def carry_problem(value: object) -> str | None:
    if not isinstance(value, list) or len(value) > MAX_CHECKIN_TASKS:
        return f"carry_over must be a list of at most {MAX_CHECKIN_TASKS} decisions"
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or not set(item) <= _CARRY_KEYS:
            return "a decision is {task_id, to[, date]}"
        task_id = item.get("task_id")
        if not _canonical_uuid(task_id) or item.get("to") not in CARRY_TARGETS:
            return "a decision needs a task id and to = tomorrow | date"
        date = item.get("date")
        if item["to"] == "date":
            if not isinstance(date, str) or not re.fullmatch(DATE_PATTERN, date):
                return "a decision to a date needs date YYYY-MM-DD"
            if parse_date(date) is None:
                return "a decision date must be a real date"
        elif date is not None:
            return "only a decision to a date has date"
        if task_id in seen:
            return "carry_over must not repeat a task"
        seen.add(str(task_id))
    return None


def checkin_problem(row: Row) -> str | None:
    if parse_date(row["date"]) is None:
        return "date must be a real date"
    return _uuid_list_problem("done_task_ids", row["done_task_ids"], MAX_CHECKIN_TASKS) or (
        carry_problem(row["carry_over"])
    )


sleep_entry_id_rule = _day_id_rule("sleep_entries")
daily_plan_id_rule = _day_id_rule("daily_plans")
checkin_id_rule = _day_id_rule("evening_checkins")
