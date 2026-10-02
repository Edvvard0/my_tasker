"""Read tools of the "Work" agent: ``get_projects``, ``get_receivables``, ``get_work_hours``.

Contract: ``docs/specs/stage4_work.md``, section 6. All numbers come from
``tasker.work.reference``; amounts are integer kopecks with a ready-made text next to them.
"""

import json
import uuid
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.tables import people, projects
from tasker.calendar.timefmt import format_utc, parse_date
from tasker.money import format_amount
from tasker.work import reference
from tasker.work.schema import PROJECT_STATUSES
from tasker.work.tables import change_requests, payment_allocations, payments, time_entries

MAX_PERIOD_DAYS = 366
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


def _like(text: str) -> str:
    return text.casefold()


def _money(name: str, value: int | None) -> dict[str, Any]:
    return {
        f"{name}_kopecks": value,
        f"{name}_text": None if value is None else format_amount(value),
    }


def _hours_text(seconds: int) -> str:
    minutes = seconds // 60
    return f"{minutes // 60} ч {minutes % 60:02d} мин"


def _json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _clip(payload: dict[str, Any], key: str) -> str:
    """Drop trailing list items until the JSON fits the tool result limit."""
    items: list[Any] = payload[key]
    while True:
        text = _json(payload)
        if len(text) <= MAX_TOOL_RESULT_CHARS or not items:
            return text
        del items[max(len(items) // 2, 0) :]
        payload["truncated"] = True
        payload["count"] = len(items)


class Data:
    """Live rows of the Work tables in the JSON shape of ``reference``."""

    def __init__(
        self,
        projects_: list[dict[str, Any]],
        crs: list[dict[str, Any]],
        pays: list[dict[str, Any]],
        allocs: list[dict[str, Any]],
        entries: list[dict[str, Any]],
        names: dict[str, str],
    ) -> None:
        self.projects, self.change_requests, self.payments = projects_, crs, pays
        self.allocations, self.entries, self.names = allocs, entries, names


def _plain(row: Any, *, instants: tuple[str, ...] = ()) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in dict(row).items():
        if isinstance(value, uuid.UUID):
            out[key] = str(value)
        elif key in instants and value is not None:
            out[key] = format_utc(value)
        else:
            out[key] = value
    return out


async def load(ctx: ToolContext) -> Data:
    async def rows(table: sa.Table) -> list[Any]:
        query = sa.select(table).where(table.c.deleted_at.is_(None)).order_by(table.c.created_at)
        return list((await session.execute(query)).mappings().all())

    async with ctx.sessionmaker() as session:
        project_rows = await rows(projects.table)
        cr_rows = await rows(change_requests.table)
        payment_rows = await rows(payments.table)
        alloc_rows = await rows(payment_allocations.table)
        entry_rows = await rows(time_entries.table)
        person_rows = await rows(people.table)
    return Data(
        [_plain(r) for r in project_rows],
        [_plain(r) for r in cr_rows],
        [_plain(r, instants=("paid_at",)) for r in payment_rows],
        [_plain(r) for r in alloc_rows],
        [_plain(r, instants=("started_at", "ended_at")) for r in entry_rows],
        {str(r["id"]): r["name"] for r in person_rows},
    )


# ------------------------------------------------------------------ get_projects


class GetProjectsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    status: list[Literal["lead", "active", "paused", "completed", "cancelled"]] | None = None
    include_archived: bool = False
    query: str | None = Field(default=None, max_length=200)
    project_id: uuid.UUID | None = None
    limit: StrictInt = Field(default=30, ge=1, le=100)


def _project_line(data: Data, project: dict[str, Any]) -> dict[str, Any]:
    summary = reference.project_summary(project, data.change_requests, data.allocations)
    client = project.get("client_id")
    line: dict[str, Any] = {
        "id": project["id"],
        "title": project["title"],
        "status": reference.DEFAULT_STATUS if project.get("status") is None else project["status"],
        "archived": project["archived"],
        "client_id": client,
        "client": data.names.get(client) if client else None,
        "pay_type": project.get("pay_type") or "fixed",
        "deadline_date": project.get("deadline_date"),
        **_money("total", summary["total"]),
        **_money("received", summary["received"]),
        **_money("remaining", summary["remaining"]),
        "paid_percent": summary["paid_bp"] / 100,
    }
    if project.get("pay_type") == "hourly":
        line.update(_money("hourly_rate", project.get("hourly_rate")))
    return line | {"_summary": summary}


async def get_projects(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetProjectsArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    found = []
    for project in data.projects:
        status = project.get("status") or reference.DEFAULT_STATUS
        if args.project_id is not None and project["id"] != str(args.project_id):
            continue
        if args.project_id is None and project["archived"] and not args.include_archived:
            continue
        if args.status and status not in args.status:
            continue
        if args.query and _like(args.query) not in _like(project["title"]):
            continue
        found.append(_project_line(data, project))
    found.sort(key=lambda line: (-max(line["remaining_kopecks"], 0), line["title"], line["id"]))
    shown = found[: args.limit]
    for line in shown:
        summary = line.pop("_summary")
        if args.project_id is not None:
            titles = {cr["id"]: cr for cr in data.change_requests}
            line.update(_money("base_received", summary["base_received"]))
            line.update(_money("base_remaining", summary["base_remaining"]))
            line["change_requests"] = [
                {
                    "id": row["id"],
                    "title": titles[row["id"]]["title"],
                    "status": titles[row["id"]]["status"],
                    **_money("amount", row["amount"]),
                    **_money("received", row["received"]),
                    **_money("remaining", row["remaining"]),
                }
                for row in summary["change_requests"]
            ]
    payload = {"count": len(shown), "truncated": len(shown) < len(found), "projects": shown}
    return _clip(payload, "projects")


# ------------------------------------------------------------------ get_receivables


class GetReceivablesArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    client: str | None = Field(default=None, max_length=200)


async def get_receivables(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetReceivablesArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    result = reference.receivables(data.projects, data.change_requests, data.allocations)
    titles = {p["id"]: p["title"] for p in data.projects}
    clients = []
    for group in result["clients"]:
        name = data.names.get(group["client_id"]) if group["client_id"] else None
        if args.client and (name is None or _like(args.client) not in _like(name)):
            continue
        clients.append(
            {
                "client_id": group["client_id"],
                "client": name,
                **_money("remaining", group["remaining"]),
                "projects": [
                    {"id": r["id"], "title": titles[r["id"]], **_money("remaining", r["remaining"])}
                    for r in group["projects"]
                ],
            }
        )
    payload = {
        "currency": "RUB",
        **_money("total", result["total"]),
        "count": len(clients),
        "truncated": False,
        "clients": clients,
    }
    return _clip(payload, "clients")


# ------------------------------------------------------------------ get_work_hours


class GetWorkHoursArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    from_date: Day
    to_date: Day
    project: str | None = Field(default=None, max_length=200)

    @model_validator(mode="after")
    def _range(self) -> "GetWorkHoursArgs":
        first, last = parse_date(self.from_date), parse_date(self.to_date)
        if first is None or last is None:
            raise ValueError("from_date and to_date must be real dates YYYY-MM-DD")
        if last < first:
            raise ValueError("to_date must not be before from_date")
        if (last - first).days >= MAX_PERIOD_DAYS:
            raise ValueError(f"the range is limited to {MAX_PERIOD_DAYS} days")
        return self


def _income_line(line: dict[str, Any], title: str) -> dict[str, Any]:
    return {
        "id": line["id"],
        "title": title,
        "billable_seconds": line["seconds"],
        "billable_hours_text": _hours_text(line["seconds"]),
        **_money("received", line["received"]),
        **_money("accrued", line["accrued"]),
        **_money("per_hour_fact", line["per_hour_fact"]),
        **_money("per_hour_accrued", line["per_hour_accrued"]),
    }


async def get_work_hours(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetWorkHoursArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    chosen = [
        p
        for p in data.projects
        if args.project is None
        or p["id"] == args.project
        or _like(args.project) in _like(p["title"])
    ]
    period = {"from": args.from_date, "to": args.to_date}
    result = reference.income(
        chosen, data.change_requests, data.payments, data.allocations, data.entries, period
    )
    titles = {p["id"]: p["title"] for p in chosen}
    ids = set(titles)
    running = sum(1 for e in data.entries if e["ended_at"] is None and e["project_id"] in ids)
    lines = [
        _income_line(line, titles[line["id"]])
        for line in result["projects"]
        if line["seconds"] or line["received"] or line["accrued"]
    ]
    payload = {
        "period": period,
        "billable_seconds": result["seconds"],
        "billable_hours_text": _hours_text(result["seconds"]),
        **_money("received", result["received"]),
        **_money("accrued", result["accrued"]),
        **_money("per_hour_fact", result["per_hour_fact"]),
        **_money("per_hour_accrued", result["per_hour_accrued"]),
        "running_timers": running,
        "count": len(lines),
        "truncated": False,
        "projects": lines,
    }
    return _clip(payload, "projects")


GET_PROJECTS = TOOLS.register(
    ToolSpec(
        name="get_projects",
        description=(
            "List the user's work projects with status, customer, total, received and remaining "
            "amounts (integer kopecks and text, RUB). Pass project_id for one project with its "
            "change requests. Archived projects only with include_archived."
        ),
        parameters={
            "type": "object",
            "properties": {
                "status": {
                    "type": "array",
                    "items": {"type": "string", "enum": list(PROJECT_STATUSES)},
                },
                "include_archived": {"type": "boolean"},
                "query": {"type": "string", "description": "substring of the project title"},
                "project_id": {"type": "string", "description": "uuid of one project"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
        args_model=GetProjectsArgs,
        kind="read",
        handler=get_projects,
    )
)

GET_RECEIVABLES = TOOLS.register(
    ToolSpec(
        name="get_receivables",
        description=(
            "Who owes the user money: the unpaid remainder of every active, paused or completed "
            "project (not leads, not cancelled), "
            "summed per customer, with the overall total. Optional filter by customer name."
        ),
        parameters={
            "type": "object",
            "properties": {"client": {"type": "string", "description": "substring of the name"}},
        },
        args_model=GetReceivablesArgs,
        kind="read",
        handler=get_receivables,
    )
)

GET_WORK_HOURS = TOOLS.register(
    ToolSpec(
        name="get_work_hours",
        description=(
            "Billable hours and income per hour for a period (Europe/Moscow dates, inclusive, "
            "at most 366 days): by fact (money received) and by accrual (closed change requests "
            "and base amounts of completed projects). Optional filter by project title or id."
        ),
        parameters={
            "type": "object",
            "properties": {
                "from_date": {"type": "string", "description": "YYYY-MM-DD"},
                "to_date": {"type": "string", "description": "YYYY-MM-DD"},
                "project": {"type": "string", "description": "project title substring or id"},
            },
            "required": ["from_date", "to_date"],
        },
        args_model=GetWorkHoursArgs,
        kind="read",
        handler=get_work_hours,
    )
)

__all__ = ["GET_PROJECTS", "GET_RECEIVABLES", "GET_WORK_HOURS"]
