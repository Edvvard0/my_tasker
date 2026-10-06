"""Task tools: ``get_tasks`` (read) and ``create_task`` (write: becomes a proposal)."""

import json
import re
from datetime import date
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.tables import TASK_STATUSES, tasks
from tasker.calendar.timefmt import parse_date

TAG_PATTERN = re.compile(r"^[^\s#@+!]{1,50}$")
_TIME = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
_MAX_ROWS = 5000
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


def _day(value: str | None, field: str) -> date | None:
    if value is None:
        return None
    parsed = parse_date(value)
    if parsed is None:
        raise ValueError(f"{field} must be a real date YYYY-MM-DD")
    return parsed


# ------------------------------------------------------------------ get_tasks


class GetTasksArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    status: list[Literal["inbox", "todo", "in_progress", "done", "cancelled"]] | None = None
    priority_min: StrictInt | None = Field(default=None, ge=1, le=5)
    priority_max: StrictInt | None = Field(default=None, ge=1, le=5)
    due_from: Day | None = None
    due_to: Day | None = None
    no_due_date: bool = False
    query: str | None = Field(default=None, max_length=200)
    include_archived: bool = False
    limit: StrictInt = Field(default=50, ge=1, le=100)

    @model_validator(mode="after")
    def _dates(self) -> "GetTasksArgs":
        _day(self.due_from, "due_from")
        _day(self.due_to, "due_to")
        return self


def _like(text: str) -> str:
    return "%" + text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


async def get_tasks(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetTasksArgs)  # noqa: S101 - the registry pairs handler and model
    table = tasks.table
    query = sa.select(table).where(table.c.deleted_at.is_(None))
    if not args.include_archived:
        query = query.where(table.c.archived_at.is_(None))
    if args.status:
        query = query.where(table.c.status.in_(args.status))
    if args.priority_min is not None:
        query = query.where(table.c.priority >= args.priority_min)
    if args.priority_max is not None:
        query = query.where(table.c.priority <= args.priority_max)
    if args.query:
        query = query.where(table.c.title.ilike(_like(args.query), escape="\\"))
    async with ctx.sessionmaker() as session:
        rows = (await session.execute(query.limit(_MAX_ROWS))).mappings().all()

    first, last = _day(args.due_from, "due_from"), _day(args.due_to, "due_to")
    found: list[dict[str, Any]] = []
    for row in rows:
        due_date, due_time = row["due_date"], None
        if row["due_at"] is not None:
            local = row["due_at"].astimezone(ctx.timezone)
            due_date, due_time = local.date().isoformat(), f"{local:%H:%M}"
        if args.no_due_date and due_date is not None:
            continue
        if first is not None or last is not None:
            when = None if due_date is None else date.fromisoformat(due_date)
            if when is None or (first and when < first) or (last and when > last):
                continue
        found.append(
            {
                "id": str(row["id"]),
                "title": row["title"],
                "status": row["status"],
                "priority": row["priority"],
                "due_date": due_date,
                "due_time": due_time,
                "duration_minutes": row["duration_minutes"],
                "recurring": row["rrule"] is not None,
                "notes": None if row["notes"] is None else row["notes"][:300],
                "_created": row["created_at"].isoformat(),
            }
        )
    found.sort(
        key=lambda t: (
            t["due_date"] is None,
            t["due_date"] or "",
            t["due_time"] or "",
            t["priority"] or 99,
            t["_created"],
        )
    )
    for item in found:
        del item["_created"]
    return _fit(found, args.limit)


def _fit(found: list[dict[str, Any]], limit: int) -> str:
    shown = found[:limit]
    while True:
        text = json.dumps(
            {"count": len(shown), "truncated": len(shown) < len(found), "tasks": shown},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if len(text) <= MAX_TOOL_RESULT_CHARS or not shown:
            return text
        shown = shown[: max(len(shown) // 2, 0)]


GET_TASKS = TOOLS.register(
    ToolSpec(
        name="get_tasks",
        description=(
            "List the user's tasks. Filter by status, priority (1 is the highest), due date range "
            "(YYYY-MM-DD, inclusive) or text. Use it to answer questions about the plan."
        ),
        parameters={
            "type": "object",
            "properties": {
                "status": {
                    "type": "array",
                    "items": {"type": "string", "enum": list(TASK_STATUSES)},
                },
                "priority_min": {"type": "integer", "minimum": 1, "maximum": 5},
                "priority_max": {"type": "integer", "minimum": 1, "maximum": 5},
                "due_from": {"type": "string", "description": "YYYY-MM-DD"},
                "due_to": {"type": "string", "description": "YYYY-MM-DD"},
                "no_due_date": {"type": "boolean", "description": "only tasks without a due date"},
                "query": {"type": "string", "description": "substring of the title"},
                "include_archived": {"type": "boolean"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
        args_model=GetTasksArgs,
        kind="read",
        handler=get_tasks,
    )
)


# ------------------------------------------------------------------ create_task


NOTES_MAX_CHARS = 2000  # the proposal (UTF-8 JSON, <= 16 KiB) is then guaranteed to fit its column


class CreateTaskArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    title: str = Field(min_length=1, max_length=500)
    notes: str | None = Field(default=None, max_length=NOTES_MAX_CHARS)
    priority: StrictInt | None = Field(default=None, ge=1, le=5)
    due_date: Day | None = None
    due_time: str | None = None
    duration_minutes: StrictInt | None = Field(default=None, ge=1, le=1440)
    project: str | None = Field(default=None, max_length=200)
    tags: list[str] | None = Field(default=None, max_length=5)

    @model_validator(mode="after")
    def _consistent(self) -> "CreateTaskArgs":
        if not self.title.strip():
            raise ValueError("title must not be blank")
        _day(self.due_date, "due_date")
        if self.due_time is not None:
            if self.due_date is None:
                raise ValueError("due_time needs due_date")
            if not _TIME.fullmatch(self.due_time):
                raise ValueError("due_time must be HH:MM")
        for tag in self.tags or []:
            if not TAG_PATTERN.fullmatch(tag):
                raise ValueError("a tag has 1..50 characters without spaces and # @ + !")
        return self

    def normalised(self) -> dict[str, Any]:
        return self.model_dump(exclude_none=True)


CREATE_TASK = TOOLS.register(
    ToolSpec(
        name="create_task",
        description=(
            "Propose a new task. The user reviews and approves it; nothing is created until then. "
            "Put dates in ISO form (convert relative dates using the current date) and the time "
            "in the user's local time."
        ),
        parameters={
            "type": "object",
            "properties": {
                "title": {"type": "string", "maxLength": 500},
                "notes": {"type": "string", "maxLength": NOTES_MAX_CHARS},
                "priority": {"type": "integer", "minimum": 1, "maximum": 5},
                "due_date": {"type": "string", "description": "YYYY-MM-DD"},
                "due_time": {"type": "string", "description": "HH:MM local time; needs due_date"},
                "duration_minutes": {"type": "integer", "minimum": 1, "maximum": 1440},
                "project": {"type": "string", "description": "project name"},
                "tags": {"type": "array", "items": {"type": "string"}, "maxItems": 5},
            },
            "required": ["title"],
        },
        args_model=CreateTaskArgs,
        kind="write",
        entity_type="task",
    )
)
