# ruff: noqa: PLR0911, PLR0912 - validators return the first problem found
"""Synchronised tables of Stage 2: calendars, events, overrides, tasks and their satellites.

Field semantics and validation rules: ``docs/specs/stage2_calendar_tasks.md`` (sections 2-5).
Validators see the *merged* row (all declared columns) and return an error message or ``None``.
"""

import re
import uuid
from collections.abc import Callable, Mapping
from datetime import datetime
from functools import lru_cache
from typing import Any
from zoneinfo import available_timezones

from tasker.calendar import ids
from tasker.calendar.rrule_subset import RRuleError, parse_rrule
from tasker.calendar.timefmt import DATE_PATTERN, parse_date, parse_utc
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

CALENDAR_KINDS = ("user", "system")
SYSTEM_KEYS = ("personal", "work", "study", "tasks", "holidays_ru")
EVENT_SOURCES = ("manual", "template", "study", "ai", "import")
TASK_STATUSES = ("inbox", "todo", "in_progress", "done", "cancelled")
TASK_SOURCES = ("manual", "ai", "telegram", "import")
RECURRENCE_MODES = ("schedule", "after_completion")
COMPLETION_STATES = ("done", "skipped")

COLOR_PATTERN = r"^#[0-9a-fA-F]{6}$"
SYSTEM_KEY_PATTERN = r"^[a-z][a-z0-9_]{0,31}$"
TAG_PATTERN = r"^[^\s#@+!]{1,50}$"
MAX_REMINDERS = 5
MAX_REMINDER_MINUTES = 40320  # 28 days
MAX_SPAN_DAYS = 366
_UTC_KEY = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


@lru_cache(maxsize=1)
def _timezones() -> frozenset[str]:
    return frozenset(available_timezones())


def valid_timezone(name: str) -> bool:
    return name in _timezones()


def _blank(value: object) -> bool:
    return not str(value).strip()


def reminders_problem(value: object) -> str | None:
    """``None``/absent means no reminders; otherwise a list of unique minutes-before offsets."""
    if value is None:
        return None
    if not isinstance(value, list) or len(value) > MAX_REMINDERS:
        return f"reminders must be a list of at most {MAX_REMINDERS} numbers"
    for item in value:
        if not isinstance(item, int) or isinstance(item, bool):
            return "reminders must be integers"
        if not 0 <= item <= MAX_REMINDER_MINUTES:
            return f"a reminder must be 0..{MAX_REMINDER_MINUTES} minutes"
    if len(set(value)) != len(value):
        return "reminders must be unique"
    return None


def _uuid_column(name: str, *, nullable: bool = False, required: bool = True) -> ColumnSpec:
    return uuid_column(name, nullable=nullable, required=required)


def _reference(name: str, parent: str, *, fixed: bool = False) -> ColumnSpec:
    """A parent link; ``fixed`` = the row belongs to its parent for life (immutable)."""
    return reference_column(name, parent, immutable=fixed)


def _date_column(name: str, *, nullable: bool = True, required: bool = False) -> ColumnSpec:
    return text_column(
        name,
        min_length=10,
        max_length=10,
        pattern=DATE_PATTERN,
        nullable=nullable,
        required=required,
    )


def _tz_column(name: str) -> ColumnSpec:
    return text_column(name, max_length=64, nullable=True, required=False)


def _instant(value: object) -> datetime | None:
    return value if isinstance(value, datetime) and 1970 <= value.year <= 2200 else None


def _timed_or_dated(row: Row, prefix: str = "") -> str | None:
    """Shared span checks for ``start_*``/``end_*`` pairs; returns a problem or ``None``."""
    start_at, end_at = row[f"{prefix}start_at"], row[f"{prefix}end_at"]
    start_date, end_date = row[f"{prefix}start_date"], row[f"{prefix}end_date"]
    if (start_at is None) != (end_at is None) or (start_date is None) != (end_date is None):
        return "start and end must be given together"
    if start_at is not None:
        if _instant(start_at) is None or _instant(end_at) is None:
            return "start_at/end_at are out of range"
        if end_at < start_at:
            return "end_at must not be before start_at"
        if (end_at - start_at).days > MAX_SPAN_DAYS:
            return f"an event cannot last longer than {MAX_SPAN_DAYS} days"
    if start_date is not None:
        first, last = parse_date(start_date), parse_date(end_date)
        if first is None or last is None:
            return "start_date/end_date must be real dates"
        if last < first:
            return "end_date must not be before start_date"
        if (last - first).days > MAX_SPAN_DAYS:
            return f"an event cannot last longer than {MAX_SPAN_DAYS} days"
    return None


# ------------------------------------------------------------------ calendars


def _calendar_valid(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    if row["kind"] == "system":
        if row["system_key"] not in SYSTEM_KEYS:
            return "a system calendar needs a known system_key"
    elif row["system_key"] is not None:
        return "system_key is only for system calendars"
    return None


def _calendar_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    # The engine passes only the columns the client sent, so optional ones may be absent.
    key = values.get("system_key")
    if values["kind"] == "system" and key in SYSTEM_KEYS:
        if row_id != ids.system_calendar_id(key):
            return "a system calendar id must be uuid5(namespace, system_key)"
        return None
    return uuid7_id_rule(row_id, values)


calendars: SyncTableSpec = define_sync_table(
    metadata,
    "calendars",
    (
        text_column("name", min_length=1, max_length=100),
        text_column("color", max_length=7, pattern=COLOR_PATTERN, nullable=True, required=False),
        enum_column("kind", CALENDAR_KINDS),
        text_column(
            "system_key",
            max_length=32,
            pattern=SYSTEM_KEY_PATTERN,
            nullable=True,
            required=False,
            immutable=True,
        ),
        bool_column("visible"),
        int_column("position", ge=0, le=1_000_000),
    ),
    id_rule=_calendar_id_rule,
    validators=(_calendar_valid,),
)


# ------------------------------------------------------------------ events


def _rule_problem(row: Row, *, all_day: bool, start: datetime | str | None) -> str | None:
    text = row["rrule"]
    if text is None:
        return None
    try:
        rule = parse_rrule(text, all_day=all_day)
    except RRuleError as exc:
        return f"rrule: {exc}"
    if all_day and rule.until_date is not None and start is not None:
        first = parse_date(str(start))
        if first is not None and rule.until_date < first:
            return "rrule: UNTIL is before the start"
    if (
        not all_day
        and rule.until_utc is not None
        and isinstance(start, datetime)
        and rule.until_utc < start
    ):
        return "rrule: UNTIL is before the start"
    return None


def _event_valid(row: Row) -> str | None:
    if _blank(row["title"]):
        return "title must not be blank"
    problem = reminders_problem(row["reminders"])
    if problem:
        return problem
    if row["all_day"]:
        if row["start_date"] is None or any(
            row[name] is not None for name in ("start_at", "end_at", "tz")
        ):
            return "an all-day event needs start_date/end_date and no start_at/end_at/tz"
        problem = _timed_or_dated(row)
        return problem or _rule_problem(row, all_day=True, start=row["start_date"])
    if row["start_at"] is None or row["tz"] is None:
        return "a timed event needs start_at, end_at and tz"
    if row["start_date"] is not None or row["end_date"] is not None:
        return "a timed event must not have start_date/end_date"
    if not valid_timezone(row["tz"]):
        return "tz is not a known IANA time zone"
    problem = _timed_or_dated(row)
    return problem or _rule_problem(row, all_day=False, start=row["start_at"])


events: SyncTableSpec = define_sync_table(
    metadata,
    "events",
    (
        _reference("calendar_id", "calendars"),
        text_column("title", min_length=1, max_length=300),
        text_column("description", max_length=10000, nullable=True, required=False),
        text_column("location", max_length=500, nullable=True, required=False),
        bool_column("all_day"),
        datetime_column("start_at", nullable=True, required=False),
        datetime_column("end_at", nullable=True, required=False),
        _tz_column("tz"),
        _date_column("start_date"),
        _date_column("end_date"),
        text_column("rrule", max_length=200, nullable=True, required=False),
        json_column("reminders", max_bytes=256, nullable=True, required=False),
        enum_column("source", EVENT_SOURCES),
    ),
    validators=(_event_valid,),
)


# ------------------------------------------------------------------ event overrides


def _original_start_ok(value: str) -> bool:
    return parse_date(value) is not None or parse_utc(value) is not None


def _override_valid(row: Row) -> str | None:
    if not _original_start_ok(row["original_start"]):
        return "original_start must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"
    for name in ("title",):
        if row[name] is not None and _blank(row[name]):
            return f"{name} must not be blank"
    problem = reminders_problem(row["reminders"])
    if problem:
        return problem
    if row["start_at"] is not None and row["start_date"] is not None:
        return "an override moves either an instant or a date, not both"
    return _timed_or_dated(row)


def _override_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    expected = ids.override_id(values["event_id"], values["original_start"])
    return None if row_id == expected else "id must be uuid5(namespace, event_id|original_start)"


event_overrides: SyncTableSpec = define_sync_table(
    metadata,
    "event_overrides",
    (
        _reference("event_id", "events", fixed=True),
        text_column("original_start", min_length=10, max_length=20, immutable=True),
        bool_column("cancelled"),
        text_column("title", max_length=300, nullable=True, required=False),
        text_column("description", max_length=10000, nullable=True, required=False),
        text_column("location", max_length=500, nullable=True, required=False),
        datetime_column("start_at", nullable=True, required=False),
        datetime_column("end_at", nullable=True, required=False),
        _date_column("start_date"),
        _date_column("end_date"),
        json_column("reminders", max_bytes=256, nullable=True, required=False),
    ),
    id_rule=_override_id_rule,
    validators=(_override_valid,),
)


# ------------------------------------------------------------------ projects, people, tags


def _name_valid(field: str) -> Validator:
    def check(row: Row) -> str | None:
        return f"{field} must not be blank" if _blank(row[field]) else None

    return check


projects: SyncTableSpec = define_sync_table(
    metadata,
    "projects",
    (
        text_column("title", min_length=1, max_length=200),
        text_column("color", max_length=7, pattern=COLOR_PATTERN, nullable=True, required=False),
        bool_column("archived"),
    ),
    validators=(_name_valid("title"),),
)

people: SyncTableSpec = define_sync_table(
    metadata,
    "people",
    (text_column("name", min_length=1, max_length=100), bool_column("archived")),
    validators=(_name_valid("name"),),
)


def _tag_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    return (
        None if row_id == ids.tag_id(values["name"]) else "id must be uuid5(namespace, lower(name))"
    )


tags: SyncTableSpec = define_sync_table(
    metadata,
    "tags",
    (
        text_column("name", max_length=50, pattern=TAG_PATTERN, immutable=True),
        text_column("color", max_length=7, pattern=COLOR_PATTERN, nullable=True, required=False),
    ),
    id_rule=_tag_id_rule,
)


# ------------------------------------------------------------------ tasks


def _task_valid(row: Row) -> str | None:
    if _blank(row["title"]):
        return "title must not be blank"
    problem = reminders_problem(row["reminders"])
    if problem:
        return problem
    due_date, due_at, due_tz = row["due_date"], row["due_at"], row["due_tz"]
    if due_date is not None and due_at is not None:
        return "due_date and due_at are mutually exclusive"
    if due_date is not None and parse_date(due_date) is None:
        return "due_date must be a real date"
    if due_at is not None and (_instant(due_at) is None or due_tz is None):
        return "due_at needs a valid instant and due_tz"
    if due_at is None and due_tz is not None:
        return "due_tz is only for due_at"
    if due_tz is not None and not valid_timezone(due_tz):
        return "due_tz is not a known IANA time zone"
    if row["rrule"] is None:
        if row["recurrence_mode"] is not None:
            return "recurrence_mode requires rrule"
    else:
        if due_date is None and due_at is None:
            return "a recurring task needs a due date"
        if row["recurrence_mode"] is None:
            return "a recurring task needs recurrence_mode"
        problem = _rule_problem(row, all_day=due_at is None, start=due_at or due_date)
        if problem:
            return problem
    if row["reminders"] and due_date is None and due_at is None:
        return "reminders need a due date"
    return None


tasks: SyncTableSpec = define_sync_table(
    metadata,
    "tasks",
    (
        text_column("title", min_length=1, max_length=500),
        text_column("notes", max_length=20000, nullable=True, required=False),
        enum_column("status", TASK_STATUSES),
        int_column("priority", ge=1, le=5, nullable=True, required=False),
        _date_column("due_date"),
        datetime_column("due_at", nullable=True, required=False),
        _tz_column("due_tz"),
        int_column("duration_minutes", ge=1, le=1440, nullable=True, required=False),
        text_column("rrule", max_length=200, nullable=True, required=False),
        enum_column("recurrence_mode", RECURRENCE_MODES, nullable=True, required=False),
        datetime_column("completed_at", nullable=True, required=False),
        datetime_column("archived_at", nullable=True, required=False),
        _uuid_column("project_id", nullable=True, required=False),
        _uuid_column("person_id", nullable=True, required=False),
        json_column("reminders", max_bytes=256, nullable=True, required=False),
        int_column("sort_order", ge=0, le=2**53, nullable=True, required=False),
        enum_column("source", TASK_SOURCES),
    ),
    validators=(_task_valid,),
)

subtasks: SyncTableSpec = define_sync_table(
    metadata,
    "subtasks",
    (
        _reference("task_id", "tasks", fixed=True),
        text_column("title", min_length=1, max_length=500),
        bool_column("done"),
        int_column("position", ge=0, le=2**53),
    ),
    validators=(_name_valid("title"),),
)


def _task_tag_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    if row_id == ids.task_tag_id(values["task_id"], values["tag_id"]):
        return None
    return "id must be uuid5(namespace, task_id|tag_id)"


task_tags: SyncTableSpec = define_sync_table(
    metadata,
    "task_tags",
    (_reference("task_id", "tasks", fixed=True), _reference("tag_id", "tags", fixed=True)),
    id_rule=_task_tag_id_rule,
)


def _completion_valid(row: Row) -> str | None:
    if parse_date(row["instance_date"]) is None:
        return "instance_date must be a real date"
    return None


def _completion_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    if row_id == ids.completion_id(values["task_id"], values["instance_date"]):
        return None
    return "id must be uuid5(namespace, task_id|instance_date)"


task_completions: SyncTableSpec = define_sync_table(
    metadata,
    "task_completions",
    (
        _reference("task_id", "tasks", fixed=True),
        text_column(
            "instance_date", min_length=10, max_length=10, pattern=DATE_PATTERN, immutable=True
        ),
        enum_column("state", COMPLETION_STATES),
        datetime_column("completed_at"),
    ),
    id_rule=_completion_id_rule,
    validators=(_completion_valid,),
)


# Parents first: the registry and the purge order depend on it.
CALENDAR_TABLES: tuple[SyncTableSpec, ...] = (
    calendars,
    events,
    event_overrides,
    projects,
    people,
    tags,
    tasks,
    subtasks,
    task_tags,
    task_completions,
)
