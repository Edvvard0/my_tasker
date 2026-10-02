"""Spend ledger, the monthly limit and the usage summary (spec stage3, 5.5), in kopecks."""

import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from zoneinfo import ZoneInfo

import sqlalchemy as sa
import structlog
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.ai.tables import ai_spend
from tasker.errors import ApiError
from tasker.ids import uuid7
from tasker.sync.user_settings import user_settings

log = structlog.get_logger("ai.spend")
LIMIT_KEY = "ai.monthly_limit_kopecks"
_MONTH = re.compile(r"^([0-9]{4})-(0[1-9]|1[0-2])$")


@dataclass(frozen=True, slots=True)
class Month:
    label: str  # YYYY-MM
    start: datetime  # UTC, inclusive
    end: datetime  # UTC, exclusive


@dataclass(frozen=True, slots=True)
class LimitExceeded:
    limit_kopecks: int
    spent_kopecks: int
    month: str


def month_of(moment: datetime, zone: ZoneInfo) -> Month:
    local = moment.astimezone(zone)
    return _bounds(local.year, local.month, zone)


def parse_month(label: str, zone: ZoneInfo) -> Month:
    match = _MONTH.fullmatch(label)
    if match is None or not 1970 <= int(match[1]) <= 2200:
        raise ApiError(422, "validation_error", "month must be YYYY-MM")
    return _bounds(int(match[1]), int(match[2]), zone)


def _bounds(year: int, month: int, zone: ZoneInfo) -> Month:
    start = datetime(year, month, 1, tzinfo=zone)
    following = datetime(year + (month == 12), month % 12 + 1, 1, tzinfo=zone)
    return Month(f"{year:04d}-{month:02d}", start.astimezone(UTC), following.astimezone(UTC))


async def read_limit(session: AsyncSession) -> int | None:
    """The monthly limit in kopecks, or ``None`` (no row, ``null`` or a malformed value)."""
    table = user_settings.table
    value = (
        await session.execute(
            sa.select(table.c.value).where(table.c.key == LIMIT_KEY, table.c.deleted_at.is_(None))
        )
    ).scalar_one_or_none()
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    if value is not None:
        log.warning("ai_limit_ignored", reason="not a non-negative integer")
    return None


async def spent_in(session: AsyncSession, month: Month) -> int:
    total: Any = (
        await session.execute(
            sa.select(sa.func.coalesce(sa.func.sum(ai_spend.c.cost_kopecks), 0)).where(
                ai_spend.c.created_at >= month.start, ai_spend.c.created_at < month.end
            )
        )
    ).scalar_one()
    return int(total)


async def check_limit(session: AsyncSession, now: datetime, zone: ZoneInfo) -> LimitExceeded | None:
    """``None`` while the user may still spend; otherwise what blocks them."""
    limit = await read_limit(session)
    if limit is None:
        return None
    month = month_of(now, zone)
    spent = await spent_in(session, month)
    return LimitExceeded(limit, spent, month.label) if spent >= limit else None


async def record(
    session: AsyncSession,
    *,
    now: datetime,
    message_id: uuid.UUID,
    model: str,
    prompt_tokens: int,
    completion_tokens: int,
    cost_kopecks: int,
    estimated: bool,
) -> None:
    await session.execute(
        sa.insert(ai_spend).values(
            id=uuid7(),
            created_at=now,
            message_id=message_id,
            model=model[:200],
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            cost_kopecks=cost_kopecks,
            estimated=estimated,
        )
    )


async def summary(session: AsyncSession, month: Month) -> dict[str, object]:
    limit = await read_limit(session)
    rows = (
        await session.execute(
            sa.select(
                ai_spend.c.model,
                sa.func.count().label("requests"),
                sa.func.sum(ai_spend.c.prompt_tokens).label("prompt_tokens"),
                sa.func.sum(ai_spend.c.completion_tokens).label("completion_tokens"),
                sa.func.sum(ai_spend.c.cost_kopecks).label("cost_kopecks"),
            )
            .where(ai_spend.c.created_at >= month.start, ai_spend.c.created_at < month.end)
            .group_by(ai_spend.c.model)
            .order_by(sa.func.sum(ai_spend.c.cost_kopecks).desc(), ai_spend.c.model)
        )
    ).all()
    by_model = [
        {
            "model": row.model,
            "requests": int(row.requests),
            "prompt_tokens": int(row.prompt_tokens),
            "completion_tokens": int(row.completion_tokens),
            "cost_kopecks": int(row.cost_kopecks),
        }
        for row in rows
    ]
    spent = sum(int(item["cost_kopecks"]) for item in by_model)
    return {
        "month": month.label,
        "limit_kopecks": limit,
        "spent_kopecks": spent,
        "remaining_kopecks": None if limit is None else max(limit - spent, 0),
        "requests": sum(int(item["requests"]) for item in by_model),
        "prompt_tokens": sum(int(item["prompt_tokens"]) for item in by_model),
        "completion_tokens": sum(int(item["completion_tokens"]) for item in by_model),
        "by_model": by_model,
    }
