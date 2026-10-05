"""Read tools of the "Sleep" agent: ``get_sleep_stats`` and ``get_daily_rituals``. Contract:
``docs/specs/stage8_sleep_rituals.md``, section 7. The numbers come from ``tasker.sleep.reference``;
only live rows are read (the tables have no parents).
"""

import json
from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Any

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.tables import tasks
from tasker.calendar.timefmt import format_utc, parse_date
from tasker.sleep import reference
from tasker.sleep.tables import daily_plans, evening_checkins, sleep_entries

NOTE_CHARS = 300
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


def _json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _clip(payload: dict[str, Any], key: str) -> str:
    """Drop the older half of the list until the JSON fits the tool result limit."""
    items: list[Any] = payload[key]
    while True:
        text = _json(payload)
        if len(text) <= MAX_TOOL_RESULT_CHARS or not items:
            return text
        del items[: (len(items) + 1) // 2]  # the lists are oldest first: keep the newest
        payload["truncated"] = True
        payload["count"] = len(items)


def _midnight(day: date) -> datetime:
    return datetime(day.year, day.month, day.day, tzinfo=UTC)


def _today(ctx: ToolContext) -> str:
    return datetime.now(ctx.timezone).date().isoformat()


def _sleep_row(row: Any) -> dict[str, Any]:
    return {
        "id": str(row["id"]),
        "date": row["date"],
        "bed_at": format_utc(row["bed_at"]),
        "wake_at": format_utc(row["wake_at"]),
        "bed_tz": row["bed_tz"],
        "wake_tz": row["wake_tz"],
    }


class _Args(BaseModel):
    model_config = ConfigDict(extra="ignore")

    through_date: Day | None = None

    @model_validator(mode="after")
    def _date(self) -> "_Args":
        if self.through_date is not None and parse_date(self.through_date) is None:
            raise ValueError("through_date must be a real date YYYY-MM-DD")
        return self


# ------------------------------------------------------------------ get_sleep_stats


class GetSleepStatsArgs(_Args):
    days: StrictInt = Field(default=14, ge=1, le=60)


async def get_sleep_stats(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetSleepStatsArgs)  # noqa: S101 - the registry pairs handler and model
    through = args.through_date or _today(ctx)
    wide_first, last = reference.window(through, 30)
    week_first, _ = reference.window(through, reference.WEEK_DAYS)
    first = min(wide_first, last - timedelta(days=args.days - 1))
    async with ctx.sessionmaker() as session:
        sleep = sleep_entries.table
        found = (
            (
                await session.execute(
                    sa.select(sleep)
                    .where(
                        sleep.c.deleted_at.is_(None),
                        sleep.c.date >= first.isoformat(),
                        sleep.c.date <= last.isoformat(),
                    )
                    .order_by(sleep.c.date)
                )
            )
            .mappings()
            .all()
        )
        t = tasks.table
        near = sa.and_(
            t.c.due_at >= _midnight(week_first - timedelta(days=1)),
            t.c.due_at <= _midnight(last + timedelta(days=2)),
        )
        task_rows = (
            (
                await session.execute(
                    sa.select(t.c.id, t.c.status, t.c.due_date, t.c.due_at, t.c.due_tz, t.c.rrule)
                    .where(
                        t.c.deleted_at.is_(None),
                        sa.or_(
                            sa.and_(
                                t.c.due_date >= week_first.isoformat(),
                                t.c.due_date <= last.isoformat(),
                            ),
                            near,
                        ),
                    )
                    .limit(5000)
                )
            )
            .mappings()
            .all()
        )
    entries = [_sleep_row(r) for r in found]
    notes = {r["date"]: r for r in found}
    shown = []
    for entry in entries:
        if entry["date"] < (last - timedelta(days=args.days - 1)).isoformat():
            continue
        view = reference.entry_view(entry)
        if view is None:
            continue
        row = notes[entry["date"]]
        note = row["note"]
        shown.append(
            {
                "date": entry["date"],
                "bed": view["bed_local"],
                "wake": view["wake_local"],
                "minutes": view["minutes"],
                "quality": row["quality"],
                "note": note[:NOTE_CHARS] if note else None,
            }
        )
    plain_tasks = [
        {
            "id": str(r["id"]),
            "status": r["status"],
            "due_date": r["due_date"],
            "due_at": format_utc(r["due_at"]) if r["due_at"] is not None else None,
            "due_tz": r["due_tz"],
            "rrule": r["rrule"],
        }
        for r in task_rows
    ]
    payload = {
        "through": through,
        "count": len(shown),
        "truncated": False,
        "average_7_days": reference.average_sleep(entries, through, 7),
        "average_30_days": reference.average_sleep(entries, through, 30),
        "tasks_vs_sleep_last_7_days": reference.sleep_task_link(entries, plain_tasks, through),
        "entries": shown,
    }
    return _clip(payload, "entries")


# ------------------------------------------------------------------ get_daily_rituals


class GetDailyRitualsArgs(_Args):
    days: StrictInt = Field(default=7, ge=1, le=30)


async def get_daily_rituals(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetDailyRitualsArgs)  # noqa: S101 - the registry pairs handler and model
    through = args.through_date or _today(ctx)
    first, last = reference.window(through, args.days)
    plans, checkins = daily_plans.table, evening_checkins.table
    async with ctx.sessionmaker() as session:
        plan_rows = (
            (
                await session.execute(
                    sa.select(plans).where(plans.c.deleted_at.is_(None)).order_by(plans.c.date)
                )
            )
            .mappings()
            .all()
        )
        checkin_rows = (
            (
                await session.execute(
                    sa.select(checkins)
                    .where(checkins.c.deleted_at.is_(None))
                    .order_by(checkins.c.date)
                )
            )
            .mappings()
            .all()
        )

    def in_window(row: Any) -> bool:
        return bool(first.isoformat() <= row["date"] <= last.isoformat())

    shown_plans = [
        {
            "date": r["date"],
            "main_task_id": str(r["main_task_id"]) if r["main_task_id"] else None,
            "task_ids": r["task_ids"],
            "note": r["note"][:NOTE_CHARS] if r["note"] else None,
        }
        for r in plan_rows
        if in_window(r)
    ]
    shown_checkins = [
        {
            "date": r["date"],
            "rating": r["rating"],
            "done_tasks": len(r["done_task_ids"]),
            "carried_tasks": len(r["carry_over"]),
            "note": r["note"][:NOTE_CHARS] if r["note"] else None,
        }
        for r in checkin_rows
        if in_window(r)
    ]
    payload = {
        "through": through,
        "count": len(shown_plans) + len(shown_checkins),
        "truncated": False,
        "streaks": reference.ritual_streaks(
            [r["date"] for r in plan_rows], [r["date"] for r in checkin_rows], through
        ),
        "plans": shown_plans,
        "checkins": shown_checkins,
    }
    return _clip(payload, "plans")


GET_SLEEP_STATS = TOOLS.register(
    ToolSpec(
        name="get_sleep_stats",
        description=(
            "The user's sleep: nights of the last days (bed and wake wall-clock times, length in "
            "minutes, quality 1-5, note), the average night over 7 and 30 days (days without an "
            "entry are skipped, not counted as zero) and a simple comparison of the share of "
            "finished tasks after short (< 6 h) and normal nights over the last 7 days (not a "
            "proof of cause). Optional through_date (default today) and days (1-60, default 14)."
        ),
        parameters={
            "type": "object",
            "properties": {
                "through_date": {"type": "string", "description": "YYYY-MM-DD, default today"},
                "days": {"type": "integer", "minimum": 1, "maximum": 60},
            },
        },
        args_model=GetSleepStatsArgs,
        kind="read",
        handler=get_sleep_stats,
    )
)

GET_DAILY_RITUALS = TOOLS.register(
    ToolSpec(
        name="get_daily_rituals",
        description=(
            "The morning plans and evening check-ins of the last days (chosen main task, task "
            "counts, day rating 1-5, notes) and the streaks of days with a morning plan, an "
            "evening check-in and both. Optional through_date (default today) and days (1-30, "
            "default 7)."
        ),
        parameters={
            "type": "object",
            "properties": {
                "through_date": {"type": "string", "description": "YYYY-MM-DD, default today"},
                "days": {"type": "integer", "minimum": 1, "maximum": 30},
            },
        },
        args_model=GetDailyRitualsArgs,
        kind="read",
        handler=get_daily_rituals,
    )
)

__all__ = ["GET_DAILY_RITUALS", "GET_SLEEP_STATS"]
