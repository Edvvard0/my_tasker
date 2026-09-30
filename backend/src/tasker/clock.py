from datetime import UTC, datetime
from typing import Protocol


class Clock(Protocol):
    """Source of the current time; tests substitute a controllable one."""

    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)


def to_ms(moment: datetime) -> int:
    """Whole milliseconds since the Unix epoch."""
    return int(moment.timestamp() * 1000)


def from_ms(ms: int) -> datetime:
    return datetime.fromtimestamp(ms // 1000, UTC).replace(microsecond=(ms % 1000) * 1000)
