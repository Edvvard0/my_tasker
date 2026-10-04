"""Read tools of the "Study" agent: ``get_study_schedule``, ``get_study_absences``,
``get_study_debts``. Contract: ``docs/specs/stage7_study.md``, section 8. The numbers come from
``tasker.study.reference``; only visible rows (live, with live parents) are read.
"""

import json
import uuid
from datetime import datetime
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.timefmt import parse_date
from tasker.datafiles import load_json
from tasker.study import reference
from tasker.study.tables import (
    attachments,
    class_overrides,
    class_slots,
    study_attendance,
    study_bells,
    study_day_rules,
    study_debts,
    study_semesters,
    study_subjects,
)

MAX_PERIOD_DAYS = 31
NOTE_CHARS = 300
HOLIDAYS_FILE = "calendar/holidays_ru.json"
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


def _json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _clip(payload: dict[str, Any], key: str) -> str:
    """Drop trailing list items until the JSON fits the tool result limit."""
    items: list[Any] = payload[key]
    while True:
        text = _json(payload)
        if len(text) <= MAX_TOOL_RESULT_CHARS or not items:
            return text
        del items[len(items) // 2 :]
        payload["truncated"] = True
        payload["count"] = len(items)


def _plain(row: Any) -> dict[str, Any]:
    return {k: str(v) if isinstance(v, uuid.UUID) else v for k, v in dict(row).items()}


class Data:
    """Visible rows of the Study tables in the JSON shape of ``reference``."""

    def __init__(self) -> None:
        self.semesters: list[dict[str, Any]] = []
        self.subjects: list[dict[str, Any]] = []
        self.bells: list[dict[str, Any]] = []
        self.slots: list[dict[str, Any]] = []
        self.day_rules: list[dict[str, Any]] = []
        self.overrides: list[dict[str, Any]] = []
        self.attendance: list[dict[str, Any]] = []
        self.debts: list[dict[str, Any]] = []
        self.files: dict[str, int] = {}  # debt id -> number of attachments


async def load(ctx: ToolContext) -> Data:
    async def rows(table: sa.Table) -> list[dict[str, Any]]:
        query = sa.select(table).where(table.c.deleted_at.is_(None)).order_by(table.c.created_at)
        return [_plain(r) for r in (await session.execute(query)).mappings().all()]

    async with ctx.sessionmaker() as session:
        semesters = await rows(study_semesters.table)
        subjects = await rows(study_subjects.table)
        bells = await rows(study_bells.table)
        slots = await rows(class_slots.table)
        day_rules = await rows(study_day_rules.table)
        overrides = await rows(class_overrides.table)
        attendance = await rows(study_attendance.table)
        debts = await rows(study_debts.table)
        files = await rows(attachments.table)
    data = Data()
    data.semesters = semesters
    live_semesters = {s["id"] for s in semesters}
    data.subjects = [s for s in subjects if s["semester_id"] in live_semesters]
    live_subjects = {s["id"] for s in data.subjects}
    data.bells = [b for b in bells if b["semester_id"] in live_semesters]
    data.slots = [
        s
        for s in slots
        if s["semester_id"] in live_semesters
        and (s["subject_id"] is None or s["subject_id"] in live_subjects)
    ]
    live_slots = {s["id"] for s in data.slots}
    data.day_rules = [r for r in day_rules if r["semester_id"] in live_semesters]
    data.overrides = [o for o in overrides if o["slot_id"] in live_slots]
    data.attendance = [a for a in attendance if a["slot_id"] in live_slots]
    data.debts = [d for d in debts if d["subject_id"] in live_subjects]
    live_debts = {d["id"] for d in data.debts}
    for f in files:
        owner = f["debt_id"] if f["debt_id"] is not None else f["subject_id"]
        if (f["debt_id"] is not None and owner in live_debts) or f["subject_id"] in live_subjects:
            data.files[owner] = data.files.get(owner, 0) + 1
    return data


def _holidays(first: str, last: str) -> dict[str, str]:
    if last < first:
        return {}
    return reference.holidays_between(load_json(HOLIDAYS_FILE), first, last)


def _coverage(first: str, last: str) -> dict[str, Any]:
    """What the holiday file knows: ``holidays_covered_until`` always, and ``holidays_warning`` when
    a year of ``first``..``last`` is not in the file (its days all count as teaching days, so the
    answer may show lessons on public holidays)."""
    years = sorted(int(year) for year in load_json(HOLIDAYS_FILE)["years"])
    info: dict[str, Any] = {"holidays_covered_until": f"{years[-1]}-12-31" if years else None}
    missing = [y for y in range(int(first[:4]), int(max(first, last)[:4]) + 1) if y not in years]
    if missing:
        info["holidays_warning"] = (
            "no holiday data for " + ", ".join(str(y) for y in missing) + ": public holidays of "
            "these years are unknown, every day is treated as a teaching day"
        )
    return info


def _today(ctx: ToolContext) -> str:
    return datetime.now(ctx.timezone).date().isoformat()


# ------------------------------------------------------------------ get_study_schedule


class GetStudyScheduleArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    from_date: Day
    to_date: Day

    @model_validator(mode="after")
    def _range(self) -> "GetStudyScheduleArgs":
        first, last = parse_date(self.from_date), parse_date(self.to_date)
        if first is None or last is None:
            raise ValueError("from_date and to_date must be real dates YYYY-MM-DD")
        if last < first:
            raise ValueError("to_date must not be before from_date")
        if (last - first).days >= MAX_PERIOD_DAYS:
            raise ValueError(f"the range is limited to {MAX_PERIOD_DAYS} days")
        return self


async def get_study_schedule(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetStudyScheduleArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    teachers = {s["id"]: s["teacher"] for s in data.subjects}
    days = reference.expand_range(
        args.from_date,
        args.to_date,
        data.semesters,
        data.subjects,
        data.bells,
        data.slots,
        data.day_rules,
        data.overrides,
        _holidays(args.from_date, args.to_date),
    )
    shown = []
    for entry in days:
        if not entry["lessons"] and entry["day"]["kind"] in ("regular", "no_semester"):
            continue
        shown.append(
            {
                "date": entry["date"],
                "weekday": entry["weekday"],
                "cycle_week": entry["cycle_week"],
                "kind": entry["day"]["kind"],
                "name": entry["day"]["name"],
                "lessons": [
                    {
                        "number": lesson["number"],
                        "start": lesson["start"],
                        "end": lesson["end"],
                        "title": lesson["title"],
                        "kind": lesson["kind"],
                        "room": lesson["room_text"] or None,
                        "teacher": teachers.get(lesson["subject_id"] or ""),
                        "cancelled": lesson["cancelled"],
                        "changed": lesson["changed"],
                        "moved_from": lesson["moved_from"],
                        "moved_to": lesson["moved_to"],
                    }
                    for lesson in entry["lessons"]
                ],
            }
        )
    payload = {
        "period": {"from": args.from_date, "to": args.to_date},
        "count": len(shown),
        "truncated": False,
        **_coverage(args.from_date, args.to_date),
        "days": shown,
    }
    return _clip(payload, "days")


# ------------------------------------------------------------------ get_study_absences


class GetStudyAbsencesArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    subject_id: uuid.UUID | None = None
    through_date: Day | None = None

    @model_validator(mode="after")
    def _date(self) -> "GetStudyAbsencesArgs":
        if self.through_date is not None and parse_date(self.through_date) is None:
            raise ValueError("through_date must be a real date YYYY-MM-DD")
        return self


async def get_study_absences(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetStudyAbsencesArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    through = args.through_date or _today(ctx)
    semesters = [s for s in data.semesters if not s["archived"]]
    names = {s["id"]: s["name"] for s in semesters}
    subjects = [
        s
        for s in data.subjects
        if s["semester_id"] in names
        and not s["archived"]
        and (args.subject_id is None or s["id"] == str(args.subject_id))
    ]
    first = min((s["start_date"] for s in semesters), default=through)
    counts = reference.attendance_summary(
        through,
        semesters,
        subjects,
        data.bells,
        data.slots,
        data.day_rules,
        data.overrides,
        _holidays(first, through),
        data.attendance,
    )
    by_id = {s["id"]: s for s in subjects}
    lines = [
        {
            "subject_id": c["subject_id"],
            "subject": by_id[c["subject_id"]]["name"],
            "semester": names[by_id[c["subject_id"]]["semester_id"]],
            "teacher": by_id[c["subject_id"]]["teacher"],
            **{k: c[k] for k in ("present", "absent", "cancelled", "unmarked", "limit", "left")},
            "state": c["state"],
        }
        for c in counts
    ]
    payload = {
        "through": through,
        "count": len(lines),
        "truncated": False,
        **_coverage(first, through),
        "subjects": lines,
    }
    return _clip(payload, "subjects")


# ------------------------------------------------------------------ get_study_debts


class GetStudyDebtsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    subject_id: uuid.UUID | None = None
    status: Literal["open", "submitted", "credited", "all"] = "open"
    limit: StrictInt = Field(default=50, ge=1, le=100)


async def get_study_debts(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetStudyDebtsArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    today = _today(ctx)
    names = {s["id"]: s["name"] for s in data.subjects}
    found = []
    for debt in data.debts:
        if args.subject_id is not None and debt["subject_id"] != str(args.subject_id):
            continue
        if args.status != "all" and debt["status"] != args.status:
            continue
        due = debt["due_date"]
        note = debt["note"]
        found.append(
            {
                "id": debt["id"],
                "subject_id": debt["subject_id"],
                "subject": names.get(debt["subject_id"]),
                "kind": debt["kind"],
                "title": debt["title"],
                "status": debt["status"],
                "due_date": due,
                "done_date": debt["done_date"],
                "overdue": debt["status"] == "open" and due is not None and due < today,
                "note": note[:NOTE_CHARS] if note else None,
                "attachments": data.files.get(debt["id"], 0),
            }
        )
    found.sort(
        key=lambda d: (d["due_date"] is None, d["due_date"] or "", d["subject"] or "", d["id"])
    )
    shown = found[: args.limit]
    payload = {
        "today": today,
        "count": len(shown),
        "truncated": len(shown) < len(found),
        "debts": shown,
    }
    return _clip(payload, "debts")


GET_STUDY_SCHEDULE = TOOLS.register(
    ToolSpec(
        name="get_study_schedule",
        description=(
            "The user's class schedule for a period (dates YYYY-MM-DD, at most 31 days): lessons "
            "per day with times, subject, type, room (e.g. 'к1 28'), teacher, cancellations, "
            "changes and moves; holidays and special days (e.g. Thursday olympiad preparation, "
            "when regular classes are off) are marked by the day's kind. Public holidays are known "
            "only up to holidays_covered_until; holidays_warning says when the period goes beyond."
        ),
        parameters={
            "type": "object",
            "properties": {
                "from_date": {"type": "string", "description": "YYYY-MM-DD"},
                "to_date": {"type": "string", "description": "YYYY-MM-DD"},
            },
            "required": ["from_date", "to_date"],
        },
        args_model=GetStudyScheduleArgs,
        kind="read",
        handler=get_study_schedule,
    )
)

GET_STUDY_ABSENCES = TOOLS.register(
    ToolSpec(
        name="get_study_absences",
        description=(
            "Attendance per subject from the start of the semester: classes attended, missed "
            "(absent), cancelled (never counted as missed) and not yet marked, the absence limit, "
            "how many absences are left and the state (ok, near, reached, over). Optional "
            "subject_id and through_date (default today)."
        ),
        parameters={
            "type": "object",
            "properties": {
                "subject_id": {"type": "string", "description": "uuid of one subject"},
                "through_date": {"type": "string", "description": "YYYY-MM-DD, default today"},
            },
        },
        args_model=GetStudyAbsencesArgs,
        kind="read",
        handler=get_study_absences,
    )
)

GET_STUDY_DEBTS = TOOLS.register(
    ToolSpec(
        name="get_study_debts",
        description=(
            "Study debts (labs, practicals, term papers, credits, exams) with subject, status "
            "(open, submitted, credited), due date, overdue flag and note. Open ones by default; "
            "optional subject_id, status (open|submitted|credited|all) and limit."
        ),
        parameters={
            "type": "object",
            "properties": {
                "subject_id": {"type": "string", "description": "uuid of one subject"},
                "status": {"type": "string", "enum": ["open", "submitted", "credited", "all"]},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
        args_model=GetStudyDebtsArgs,
        kind="read",
        handler=get_study_debts,
    )
)

__all__ = ["GET_STUDY_ABSENCES", "GET_STUDY_DEBTS", "GET_STUDY_SCHEDULE"]
