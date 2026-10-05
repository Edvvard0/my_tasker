"""Builders of valid Stage 8 rows."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from tasker.sleep.schema import day_id
from tests.api_support import DeviceClient


def sleep_fields(
    dc: DeviceClient, date: str = "2026-10-02", minutes: int = 450, **over: Any
) -> dict[str, Any]:
    """A Moscow night ending at 07:00 local (04:00 UTC) on ``date``."""
    try:
        wake = datetime.fromisoformat(f"{date}T04:00:00").replace(tzinfo=UTC)
    except ValueError:  # a deliberately broken date: the moments stay valid
        wake = datetime(2026, 10, 2, 4, tzinfo=UTC)
    bed = wake - timedelta(minutes=minutes)
    return {
        "date": date,
        "bed_at": bed.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "wake_at": wake.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "wake_tz": "Europe/Moscow",
        "source": "manual",
        "created_at": dc.created(),
        **over,
    }


def plan_fields(dc: DeviceClient, date: str = "2026-10-02", **over: Any) -> dict[str, Any]:
    return {"date": date, "task_ids": [], "created_at": dc.created(), **over}


def checkin_fields(dc: DeviceClient, date: str = "2026-10-02", **over: Any) -> dict[str, Any]:
    return {
        "date": date,
        "done_task_ids": [],
        "carry_over": [],
        "created_at": dc.created(),
        **over,
    }


def sleep_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return day_id("sleep_entries", fields["date"])


def plan_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return day_id("daily_plans", fields["date"])


def checkin_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return day_id("evening_checkins", fields["date"])
