"""Pulse numbers (spec stage9, section 8): availability from hourly buckets, integer only."""

from collections.abc import Iterable, Mapping
from typing import Any

HOUR = 3600
BASIS = 10_000
WINDOW_HOURS = {"h24": 24, "d7": 7 * 24, "d30": 30 * 24}


def hour_floor(ts: int) -> int:
    return ts - ts % HOUR


def availability_bp(buckets: Iterable[Mapping[str, Any]], now: int, hours: int) -> int | None:
    """Share of successful checks, in basis points (floor), over the last ``hours`` hourly buckets
    counted back from the bucket of ``now`` inclusive (a window of 24 hours is 24 buckets, the
    current, partial one among them). A bucket is ``{hour, total, ok}`` (``hour`` = Unix seconds
    of its start). ``None`` when the window holds no check."""
    last = hour_floor(now)
    first = last - (hours - 1) * HOUR
    total = ok = 0
    for bucket in buckets:
        if first <= bucket["hour"] <= last:
            total += bucket["total"]
            ok += bucket["ok"]
    return ok * BASIS // total if total else None


def mean_ms(total_ms: int, count: int) -> int | None:
    """Mean response time in whole milliseconds (floor); ``None`` without successful checks."""
    return total_ms // count if count else None
