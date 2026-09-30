"""Login rate limiting with exponential backoff, kept in PostgreSQL (no Redis).

Scheme (spec 1.1): every attempt is *recorded before* the password is checked, in one short
transaction that holds a row lock on the counters. Attempts therefore serialise: a parallel
burst cannot pass the check more often than the threshold allows. A successful login gives its
reservation back (per-IP counter cleared, global counter decremented).

The global lock is capped lower than the per-IP one and can be lifted on the server with
``python -m tasker.cli user unlock``: a distributed guesser can throttle sign-ins, but never lock
the owner out for good.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.tables import login_failures

IP_THRESHOLD = 5
GLOBAL_THRESHOLD = 20
BASE_LOCK_SECONDS = 30
MAX_LOCK_SECONDS = 900
GLOBAL_MAX_LOCK_SECONDS = 300
FORGET_AFTER = timedelta(hours=1)


class LockedError(Exception):
    def __init__(self, retry_after_seconds: int) -> None:
        super().__init__(f"locked for {retry_after_seconds}s")
        self.retry_after_seconds = retry_after_seconds


@dataclass(frozen=True, slots=True)
class Reservation:
    """What ``reserve`` did to the counters, so ``release`` can undo exactly that."""

    ip: str
    global_locked_by_us: bool


def _scopes(ip: str) -> list[tuple[str, str, int, int]]:
    # Fixed order (ip, then global): concurrent reservations cannot deadlock on the row locks.
    return [
        ("ip", ip, IP_THRESHOLD, MAX_LOCK_SECONDS),
        ("global", "", GLOBAL_THRESHOLD, GLOBAL_MAX_LOCK_SECONDS),
    ]


async def _locked_row(session: AsyncSession, scope: str, key: str, now: datetime) -> Any:
    """Create-if-missing and lock the counter row in one statement.

    ``DO UPDATE`` (a no-op assignment) takes the row lock and returns the row atomically; a
    separate INSERT-then-SELECT could lose the row to a concurrent ``release`` in between.
    """
    result = await session.execute(
        pg_insert(login_failures)
        .values(scope=scope, key=key, failures=0, last_failure_at=now)
        .on_conflict_do_update(
            index_elements=[login_failures.c.scope, login_failures.c.key],
            set_={"failures": login_failures.c.failures},
        )
        .returning(login_failures)
    )
    return result.one()


def _remaining(locked_until: datetime | None, now: datetime) -> int | None:
    if locked_until is None or locked_until <= now:
        return None
    return max(1, int((locked_until - now).total_seconds() + 0.999))


async def reserve(session: AsyncSession, now: datetime, ip: str) -> Reservation:
    """Atomically check the locks and count this attempt as a failure.

    Raises ``LockedError`` (nothing is counted) when a lock is active. The caller must run this
    inside its own transaction and commit it *before* the slow password check.
    """
    global_locked = False
    rows = []
    for scope, key, threshold, cap in _scopes(ip):
        rows.append((scope, key, threshold, cap, await _locked_row(session, scope, key, now)))
    waits = [w for *_, row in rows if (w := _remaining(row.locked_until, now)) is not None]
    if waits:
        raise LockedError(max(waits))
    for scope, key, threshold, cap, row in rows:
        failures = 0 if now - row.last_failure_at > FORGET_AFTER else row.failures
        failures += 1
        locked_until = row.locked_until
        if failures >= threshold:
            seconds = min(cap, BASE_LOCK_SECONDS * 2 ** min(failures - threshold, 20))
            locked_until = now + timedelta(seconds=seconds)
            global_locked = global_locked or scope == "global"
        await session.execute(
            sa.update(login_failures)
            .where(login_failures.c.scope == scope, login_failures.c.key == key)
            .values(failures=failures, last_failure_at=now, locked_until=locked_until)
        )
    return Reservation(ip, global_locked)


async def release(session: AsyncSession, reservation: Reservation) -> None:
    """Successful login: forget this address; give the global counter its attempt back."""
    await session.execute(
        sa.delete(login_failures).where(
            login_failures.c.scope == "ip", login_failures.c.key == reservation.ip
        )
    )
    values: dict[str, object] = {"failures": sa.func.greatest(login_failures.c.failures - 1, 0)}
    if reservation.global_locked_by_us:
        values["locked_until"] = None  # our own attempt tripped it; the attempt was legitimate
    await session.execute(
        sa.update(login_failures)
        .where(login_failures.c.scope == "global", login_failures.c.key == "")
        .values(**values)
    )


async def clear_all(session: AsyncSession) -> int:
    """Forget every counter and lock (``user unlock`` / ``user reset``)."""
    result = await session.execute(sa.delete(login_failures))
    return int(getattr(result, "rowcount", 0) or 0)
