"""Columns and validators of the Stage 7 tables (spec: ``docs/specs/stage7_study.md``)."""

import re
import uuid
from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from tasker.calendar.ids import namespace
from tasker.calendar.timefmt import DATE_PATTERN, parse_date
from tasker.sync.registry import (
    ColumnSpec,
    bool_column,
    enum_column,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid_column,
)

Row = Mapping[str, Any]

LESSON_KINDS = ("lecture", "practice", "lab", "other")
OVERRIDE_ACTIONS = ("cancel", "change", "move")
ATTENDANCE_STATUSES = ("present", "absent", "cancelled")
DEBT_KINDS = ("lab", "practice", "rgr", "coursework", "credit", "exam", "other")
DEBT_STATUSES = ("open", "submitted", "credited")
UPLOAD_STATUSES = ("pending", "uploaded")

MAX_SEMESTER_DAYS = 400
MAX_SHIFTS = 30
MAX_RULE_ITEMS = 12
MAX_FILE_BYTES = 25 * 1024 * 1024
TIME_PATTERN = r"^([01][0-9]|2[0-3]):[0-5][0-9]$"
ITEM_KEY_PATTERN = r"^[a-z0-9_]{1,20}$"
BUILDING_PATTERN = r"^[^ \t\r\n]{1,10}$"
SHA256_PATTERN = r"^[0-9a-f]{64}$"

# MIME type -> extensions (lower case, with the dot) that a file of this type may carry.
ALLOWED_FILES: dict[str, tuple[str, ...]] = {
    "image/jpeg": (".jpg", ".jpeg"),
    "image/png": (".png",),
    "image/heic": (".heic", ".heif"),
    "image/heif": (".heic", ".heif"),
    "image/webp": (".webp",),
    "application/pdf": (".pdf",),
    "application/msword": (".doc",),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": (".docx",),
    "application/vnd.ms-excel": (".xls",),
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": (".xlsx",),
    "application/vnd.ms-powerpoint": (".ppt",),
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": (".pptx",),
    "text/plain": (".txt",),
    "application/zip": (".zip",),
}


def _blank(value: object) -> bool:
    return not str(value).strip()


def _date(name: str, *, required: bool = False, immutable: bool = False) -> ColumnSpec:
    return text_column(
        name,
        min_length=10,
        max_length=10,
        pattern=DATE_PATTERN,
        nullable=not required,
        required=required,
        immutable=immutable,
    )


def _time(name: str, *, required: bool = False) -> ColumnSpec:
    return text_column(
        name,
        min_length=5,
        max_length=5,
        pattern=TIME_PATTERN,
        nullable=not required,
        required=required,
    )


def _fixed(column: ColumnSpec) -> ColumnSpec:
    return replace(column, immutable=True)


def _building(name: str = "building") -> ColumnSpec:
    return text_column(name, max_length=10, pattern=BUILDING_PATTERN, nullable=True, required=False)


def _room(name: str = "room") -> ColumnSpec:
    return text_column(name, max_length=20, nullable=True, required=False)


def _times_problem(start: str | None, end: str | None) -> str | None:
    if (start is None) != (end is None):
        return "start_time and end_time go together"
    if start is not None and end is not None and end <= start:
        return "end_time must be after start_time"
    return None


# ------------------------------------------------------------------ study_semesters

SEMESTER_COLUMNS: tuple[ColumnSpec, ...] = (
    text_column("name", min_length=1, max_length=100),
    _date("start_date", required=True),
    _date("end_date", required=True),
    _date("week1_start", required=True),
    int_column("cycle_length", ge=1, le=8),
    json_column("week_shifts", max_bytes=4096, nullable=True, required=False),
    bool_column("archived"),
)


def _shifts_problem(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) > MAX_SHIFTS:
        return f"week_shifts must be a list of at most {MAX_SHIFTS} entries"
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {"from", "weeks"}:
            return "a shift is {from, weeks}"
        start, weeks = entry["from"], entry["weeks"]
        if not isinstance(start, str) or parse_date(start) is None:
            return "a shift needs a real date"
        if type(weeks) is not int or not -8 <= weeks <= 8:
            return "a shift moves by -8..8 weeks"
    return None


def semester_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    first, last, anchor = (parse_date(row[k]) for k in ("start_date", "end_date", "week1_start"))
    if first is None or last is None or anchor is None:
        return "dates must be real dates"
    if last < first:
        return "end_date must not be before start_date"
    if (last - first).days > MAX_SEMESTER_DAYS:
        return f"a semester is at most {MAX_SEMESTER_DAYS} days"
    return _shifts_problem(row["week_shifts"])


# ------------------------------------------------------------------ study_subjects

SUBJECT_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("semester_id", "study_semesters", immutable=True),
    text_column("name", min_length=1, max_length=200),
    text_column("teacher", max_length=200, nullable=True, required=False),
    _building(),
    _room(),
    int_column("absence_limit", ge=1, le=999, nullable=True, required=False),
    text_column("note", max_length=5000, nullable=True, required=False),
    bool_column("archived"),
)


def subject_problem(row: Row) -> str | None:
    return "name must not be blank" if _blank(row["name"]) else None


# ------------------------------------------------------------------ study_bells


def bell_id(semester_id: str | uuid.UUID, on_date: str | None, number: int) -> uuid.UUID:
    return uuid.uuid5(namespace("study_bells"), f"{semester_id}|{on_date or ''}|{number}")


BELL_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("semester_id", "study_semesters", immutable=True),
    _fixed(_date("on_date")),
    _fixed(int_column("number", ge=1, le=12)),
    _time("start_time", required=True),
    _time("end_time", required=True),
)


def bell_problem(row: Row) -> str | None:
    if row["on_date"] is not None and parse_date(row["on_date"]) is None:
        return "on_date must be a real date"
    return _times_problem(row["start_time"], row["end_time"])


def bell_id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    expected = bell_id(values["semester_id"], values.get("on_date"), values["number"])
    return None if row_id == expected else "id must be uuid5(namespace, semester|date|number)"


# ------------------------------------------------------------------ class_slots

SLOT_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("semester_id", "study_semesters", immutable=True),
    reference_column("subject_id", "study_subjects", nullable=True, required=False),
    text_column("title", max_length=200, nullable=True, required=False),
    int_column("weekday", ge=1, le=7),
    int_column("number", ge=1, le=12, nullable=True, required=False),
    _time("start_time"),
    _time("end_time"),
    enum_column("kind", LESSON_KINDS),
    _building(),
    _room(),
    int_column("cycle_week", ge=1, le=8, nullable=True, required=False),
)


def slot_problem(row: Row) -> str | None:
    if row["subject_id"] is None and (row["title"] is None or _blank(row["title"])):
        return "a slot needs a subject or a title"
    if row["title"] is not None and _blank(row["title"]):
        return "title must not be blank"
    if row["number"] is None and row["start_time"] is None:
        return "a slot needs a pair number or its own time"
    return _times_problem(row["start_time"], row["end_time"])


# ------------------------------------------------------------------ study_day_rules


def day_rule_id(
    semester_id: str | uuid.UUID, weekday: int | None, on_date: str | None, cycle_week: int | None
) -> uuid.UUID:
    scope = f"date:{on_date}" if on_date is not None else f"weekday:{weekday}:{cycle_week or ''}"
    return uuid.uuid5(namespace("study_day_rules"), f"{semester_id}|{scope}")


_ITEM_KEYS = {
    "key",
    "number",
    "start_time",
    "end_time",
    "title",
    "kind",
    "building",
    "room",
    "cycle_week",
}


def _item_problem(item: object) -> str | None:
    if not isinstance(item, dict) or not set(item) <= _ITEM_KEYS:
        return "an item has only its own keys"
    key, title = item.get("key"), item.get("title")
    if not isinstance(key, str) or not _matches(ITEM_KEY_PATTERN, key):
        return "an item needs a key of 1..20 characters a-z 0-9 _"
    if not isinstance(title, str) or _blank(title) or len(title) > 200:
        return "an item needs a title of 1..200 characters"
    if item.get("kind") not in LESSON_KINDS:
        return "an item needs a known kind"
    number = item.get("number")
    if number is not None and (type(number) is not int or not 1 <= number <= 12):
        return "number is 1..12"
    cycle = item.get("cycle_week")
    if cycle is not None and (type(cycle) is not int or not 1 <= cycle <= 8):
        return "cycle_week is 1..8"
    start, end = item.get("start_time"), item.get("end_time")
    for name, value in (("start_time", start), ("end_time", end)):
        if value is not None and (not isinstance(value, str) or not _matches(TIME_PATTERN, value)):
            return f"{name} must be HH:MM"
    for name, limit in (("building", 10), ("room", 20)):
        value = item.get(name)
        if value is not None and (not isinstance(value, str) or not 1 <= len(value) <= limit):
            return f"{name} is a text of 1..{limit} characters"
    if number is None and start is None:
        return "an item needs a pair number or its own time"
    return _times_problem(start, end)


def _matches(pattern: str, value: str) -> bool:
    return re.fullmatch(pattern, value) is not None


def items_problem(value: object) -> str | None:
    if not isinstance(value, list) or len(value) > MAX_RULE_ITEMS:
        return f"items must be a list of at most {MAX_RULE_ITEMS} entries"
    keys = []
    for item in value:
        if (problem := _item_problem(item)) is not None:
            return problem
        keys.append(item["key"])
    return "item keys must be unique" if len(set(keys)) != len(keys) else None


DAY_RULE_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("semester_id", "study_semesters", immutable=True),
    _fixed(int_column("weekday", ge=1, le=7, nullable=True, required=False)),
    _fixed(_date("on_date")),
    _fixed(int_column("cycle_week", ge=1, le=8, nullable=True, required=False)),
    text_column("title", min_length=1, max_length=200),
    bool_column("hide_regular"),
    json_column("items", max_bytes=8192),
)


def day_rule_problem(row: Row) -> str | None:
    if _blank(row["title"]):
        return "title must not be blank"
    if (row["weekday"] is None) == (row["on_date"] is None):
        return "a rule is for a weekday or for a date, not both and not neither"
    if row["on_date"] is not None and parse_date(row["on_date"]) is None:
        return "on_date must be a real date"
    if row["cycle_week"] is not None and row["weekday"] is None:
        return "cycle_week goes with a weekday rule"
    return items_problem(row["items"])


def day_rule_id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    expected = day_rule_id(
        values["semester_id"],
        values.get("weekday"),
        values.get("on_date"),
        values.get("cycle_week"),
    )
    return None if row_id == expected else "id must be uuid5(namespace, semester|scope)"


# ------------------------------------------------------------------ class_overrides


def slot_date_id(table: str, slot_id: str | uuid.UUID, on_date: str) -> uuid.UUID:
    """One override (or attendance mark) per slot and date, whatever device writes it."""
    return uuid.uuid5(namespace(table), f"{slot_id}|{on_date}")


OVERRIDE_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("slot_id", "class_slots", immutable=True),
    _date("date", required=True, immutable=True),
    enum_column("action", OVERRIDE_ACTIONS),
    _date("new_date"),
    _time("start_time"),
    _time("end_time"),
    _building(),
    _room(),
    uuid_column("subject_id", nullable=True, required=False),
    text_column("title", max_length=200, nullable=True, required=False),
    enum_column("lesson_kind", LESSON_KINDS, nullable=True, required=False),
)


def override_problem(row: Row) -> str | None:
    if parse_date(row["date"]) is None:
        return "date must be a real date"
    if row["action"] == "move":
        if row["new_date"] is None or parse_date(row["new_date"]) is None:
            return "a move needs a real new_date"
        if row["new_date"] == row["date"]:
            return "a move needs another date"
    elif row["new_date"] is not None:
        return "only a move has new_date"
    if row["title"] is not None and _blank(row["title"]):
        return "title must not be blank"
    return _times_problem(row["start_time"], row["end_time"])


def override_id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    expected = slot_date_id("class_overrides", values["slot_id"], values["date"])
    return None if row_id == expected else "id must be uuid5(namespace, slot|date)"


# ------------------------------------------------------------------ study_attendance

ATTENDANCE_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("slot_id", "class_slots", immutable=True),
    _date("date", required=True, immutable=True),
    enum_column("status", ATTENDANCE_STATUSES),
    text_column("note", max_length=500, nullable=True, required=False),
)


def attendance_problem(row: Row) -> str | None:
    return None if parse_date(row["date"]) is not None else "date must be a real date"


def attendance_id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    expected = slot_date_id("study_attendance", values["slot_id"], values["date"])
    return None if row_id == expected else "id must be uuid5(namespace, slot|date)"


# ------------------------------------------------------------------ study_debts

DEBT_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("subject_id", "study_subjects", immutable=True),
    enum_column("kind", DEBT_KINDS),
    text_column("title", min_length=1, max_length=200),
    enum_column("status", DEBT_STATUSES),
    _date("due_date"),
    _date("done_date"),
    text_column("note", max_length=5000, nullable=True, required=False),
    uuid_column("task_id", nullable=True, required=False),
)


def debt_problem(row: Row) -> str | None:
    if _blank(row["title"]):
        return "title must not be blank"
    for name in ("due_date", "done_date"):
        if row[name] is not None and parse_date(row[name]) is None:
            return f"{name} must be a real date"
    return None


# ------------------------------------------------------------------ attachments

ATTACHMENT_COLUMNS: tuple[ColumnSpec, ...] = (
    _fixed(reference_column("subject_id", "study_subjects", nullable=True, required=False)),
    _fixed(reference_column("debt_id", "study_debts", nullable=True, required=False)),
    text_column("file_name", min_length=1, max_length=255),
    _fixed(enum_column("mime_type", tuple(re.escape(m) for m in ALLOWED_FILES))),
    _fixed(int_column("size_bytes", ge=1, le=MAX_FILE_BYTES)),
    _fixed(text_column("sha256", min_length=64, max_length=64, pattern=SHA256_PATTERN)),
    enum_column("upload_status", UPLOAD_STATUSES),
)


def file_name_problem(name: str) -> str | None:
    if _blank(name) or name in (".", ".."):
        return "file_name must not be blank"
    if any(c in "/\\" or ord(c) < 32 or ord(c) == 127 for c in name):
        return "file_name must not contain path separators or control characters"
    return None


def attachment_problem(row: Row) -> str | None:
    if (row["subject_id"] is None) == (row["debt_id"] is None):
        return "an attachment belongs to exactly one subject or debt"
    if (bad := file_name_problem(row["file_name"])) is not None:
        return bad
    name = row["file_name"]
    extension = "." + name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if extension not in ALLOWED_FILES.get(row["mime_type"], ()):
        return "file_name extension does not fit mime_type"
    return None
