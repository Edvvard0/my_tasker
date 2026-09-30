"""Login rate limiting with exponential backoff, kept in PostgreSQL (no Redis)."""

from datetime import datetime, timedelta

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.tables import login_failures

IP_THRESHOLD = 5
GLOBAL_THRESHOLD = 20
BASE_LOCK_SECONDS = 30
MAX_LOCK_SECONDS = 900
FORGET_AFTER = timedelta(hours=1)


def _keys(ip: str) -> list[tuple[str, str, int]]:
    return [("ip", ip, IP_THRESHOLD), ("global", "", GLOBAL_THRESHOLD)]


async def retry_after_seconds(session: AsyncSession, now: datetime, ip: str) -> int | None:
    """Seconds until login is allowed again, or ``None`` when not locked."""
    rows = await session.execute(
        sa.select(login_failures.c.locked_until).where(
            sa.or_(
                sa.and_(login_failures.c.scope == "ip", login_failures.c.key == ip),
                sa.and_(login_failures.c.scope == "global", login_failures.c.key == ""),
            ),
            login_failures.c.locked_until > now,
        )
    )
    locked_untils: list[datetime] = list(rows.scalars())
    remaining = [(locked - now).total_seconds() for locked in locked_untils]
    return max(1, int(max(remaining) + 0.999)) if remaining else None


async def record_failure(session: AsyncSession, now: datetime, ip: str) -> None:
    for scope, key, threshold in _keys(ip):
        await session.execute(
            pg_insert(login_failures)
            .values(scope=scope, key=key, failures=0, last_failure_at=now)
            .on_conflict_do_nothing()
        )
        row = (
            await session.execute(
                sa.select(login_failures)
                .where(login_failures.c.scope == scope, login_failures.c.key == key)
                .with_for_update()
            )
        ).one()
        failures = 0 if now - row.last_failure_at > FORGET_AFTER else row.failures
        failures += 1
        locked_until = row.locked_until
        if failures >= threshold:
            seconds = min(MAX_LOCK_SECONDS, BASE_LOCK_SECONDS * 2 ** (failures - threshold))
            locked_until = now + timedelta(seconds=seconds)
        await session.execute(
            sa.update(login_failures)
            .where(login_failures.c.scope == scope, login_failures.c.key == key)
            .values(failures=failures, last_failure_at=now, locked_until=locked_until)
        )


async def record_success(session: AsyncSession, ip: str) -> None:
    await session.execute(
        sa.delete(login_failures).where(login_failures.c.scope == "ip", login_failures.c.key == ip)
    )
