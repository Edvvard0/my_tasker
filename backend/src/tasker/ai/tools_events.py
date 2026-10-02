"""``get_events``: calendar events in a date range, recurring ones expanded (Stage 2, 5.3)."""

import json
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Annotated, Any
from zoneinfo import ZoneInfo

import sqlalchemy as sa
import structlog
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.reference_expand import expand, local_to_utc
from tasker.calendar.tables import calendars, event_overrides, events
from tasker.calendar.timefmt import format_utc, parse_date, parse_utc

log = structlog.get_logger("ai.tools")
MAX_SPAN_DAYS = 62
_MAX_ROWS = 2000
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


class GetEventsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    from_date: Day
    to_date: Day
    limit: StrictInt = Field(default=50, ge=1, le=200)

    @model_validator(mode="after")
    def _range(self) -> "GetEventsArgs":
        first, last = parse_date(self.from_date), parse_date(self.to_date)
        if first is None or last is None:
            raise ValueError("from_date and to_date must be real dates YYYY-MM-DD")
        if last < first:
            raise ValueError("to_date must not be before from_date")
        if (last - first).days >= MAX_SPAN_DAYS:
            raise ValueError(f"the range is limited to {MAX_SPAN_DAYS} days")
        return self


def _local_midnight_utc(day: date, zone: ZoneInfo) -> datetime:
    return local_to_utc(datetime(day.year, day.month, day.day), zone)


async def get_events(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetEventsArgs)  # noqa: S101 - the registry pairs handler and model
    first, last = date.fromisoformat(args.from_date), date.fromisoformat(args.to_date)
    after_last = last + timedelta(days=1)
    timed_window = {
        "from": format_utc(_local_midnight_utc(first, ctx.timezone)),
        "to": format_utc(_local_midnight_utc(after_last, ctx.timezone)),
    }
    day_window = {"from": first.isoformat(), "to": after_last.isoformat()}

    table = events.table
    async with ctx.sessionmaker() as session:
        rows = (
            (
                await session.execute(
                    sa.select(table, calendars.table.c.name.label("calendar_name"))
                    .join(calendars.table, calendars.table.c.id == table.c.calendar_id)
                    .where(table.c.deleted_at.is_(None), calendars.table.c.deleted_at.is_(None))
                    .limit(_MAX_ROWS)
                )
            )
            .mappings()
            .all()
        )
        override_rows: list[Any] = []
        if rows:
            override_rows = list(
                (
                    await session.execute(
                        sa.select(event_overrides.table).where(
                            event_overrides.table.c.deleted_at.is_(None),
                            event_overrides.table.c.event_id.in_([row["id"] for row in rows]),
                        )
                    )
                )
                .mappings()
                .all()
            )
    by_event: dict[Any, list[Any]] = defaultdict(list)
    for override in override_rows:
        by_event[override["event_id"]].append(override)

    found: list[dict[str, Any]] = []
    for row in rows:
        try:
            instances = expand(_expand_input(row, by_event[row["id"]], timed_window, day_window))
        except (ValueError, RuntimeError, KeyError):
            log.warning("event_expand_failed")
            continue
        for item in instances:
            found.append(_describe(row, item, ctx.timezone))
    found.sort(key=lambda e: (e["start"], e["title"]))
    return _fit(found, args.limit)


def _expand_input(
    row: Any, overrides: list[Any], timed_window: dict[str, str], day_window: dict[str, str]
) -> dict[str, Any]:
    all_day = bool(row["all_day"])
    cancelled = [o["original_start"] for o in overrides if o["cancelled"]]
    changes: list[dict[str, Any]] = []
    for override in overrides:
        if override["cancelled"]:
            continue
        item: dict[str, Any] = {"original_start": override["original_start"]}
        if override["title"] is not None:
            item["title"] = override["title"]
        if override["start_at"] is not None:
            item["start"], item["end"] = (
                format_utc(override["start_at"]),
                format_utc(override["end_at"]),
            )
        elif override["start_date"] is not None:
            item["start"], item["end"] = override["start_date"], override["end_date"]
        changes.append(item)
    if all_day:
        start, end = row["start_date"], row["end_date"]
    else:
        start, end = format_utc(row["start_at"]), format_utc(row["end_at"])
    return {
        "all_day": all_day,
        "tz": row["tz"],
        "start": start,
        "end": end,
        "rrule": row["rrule"],
        "title": row["title"],
        "cancelled": cancelled,
        "overrides": changes,
        "window": day_window if all_day else timed_window,
    }


def _describe(row: Any, item: dict[str, str], zone: ZoneInfo) -> dict[str, Any]:
    all_day = bool(row["all_day"])
    start, end = item["start"], item["end"]
    if not all_day:
        start_utc, end_utc = parse_utc(start), parse_utc(end)
        assert start_utc is not None  # noqa: S101 - formatted by this module
        assert end_utc is not None  # noqa: S101
        start = f"{start_utc.astimezone(zone):%Y-%m-%dT%H:%M}"
        end = f"{end_utc.astimezone(zone):%Y-%m-%dT%H:%M}"
    return {
        "id": str(row["id"]),
        "title": item["title"],
        "calendar": row["calendar_name"],
        "all_day": all_day,
        "start": start,
        "end": end,
        "location": row["location"],
        "recurring": row["rrule"] is not None,
    }


def _fit(found: list[dict[str, Any]], limit: int) -> str:
    shown = found[:limit]
    while True:
        text = json.dumps(
            {"count": len(shown), "truncated": len(shown) < len(found), "events": shown},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if len(text) <= MAX_TOOL_RESULT_CHARS or not shown:
            return text
        shown = shown[: len(shown) // 2]


GET_EVENTS = TOOLS.register(
    ToolSpec(
        name="get_events",
        description=(
            "List calendar events between two dates (YYYY-MM-DD, inclusive, at most 62 days). "
            "Recurring events are expanded; times are in the user's time zone."
        ),
        parameters={
            "type": "object",
            "properties": {
                "from_date": {"type": "string", "description": "YYYY-MM-DD"},
                "to_date": {"type": "string", "description": "YYYY-MM-DD"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            },
            "required": ["from_date", "to_date"],
        },
        args_model=GetEventsArgs,
        kind="read",
        handler=get_events,
    )
)
