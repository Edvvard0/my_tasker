"""Hybrid logical clock: sortable string ``{ms:015d}-{counter:05d}-{device_id}``.

Plain string comparison equals comparing ``(ms, counter, device_id)``. The canonical rules and
test cases live in ``docs/specs/stage1_sync_and_auth.md`` (section 2) and
``shared-test-vectors/sync/hlc.json``.
"""

import re
import uuid
from dataclasses import dataclass

MAX_COUNTER = 99_999
HLC_LENGTH = 58
_PATTERN = re.compile(
    r"(?P<ms>[0-9]{15})-(?P<counter>[0-9]{5})-"
    r"(?P<device>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
)


class HlcError(ValueError):
    """The string is not a valid HLC."""


@dataclass(frozen=True, order=True, slots=True)
class Hlc:
    ms: int
    counter: int
    device: str

    def __str__(self) -> str:
        return format_hlc(self.ms, self.counter, self.device)


def format_hlc(ms: int, counter: int, device: str) -> str:
    if not 0 <= ms < 10**15 or not 0 <= counter <= MAX_COUNTER:
        raise HlcError("hlc component out of range")
    return f"{ms:015d}-{counter:05d}-{device}"


def parse_hlc(value: object) -> Hlc:
    if not isinstance(value, str):
        raise HlcError("hlc must be a string")
    match = _PATTERN.fullmatch(value)
    if match is None:
        raise HlcError("malformed hlc")
    return Hlc(int(match["ms"]), int(match["counter"]), match["device"])


def device_of(value: str) -> str:
    """Device id of a valid HLC string (last 36 characters)."""
    return value[-36:]


def hlc_ms(value: str) -> int:
    return int(value[:15])


class HlcClock:
    """Client-side clock state ``(l, c)``; used by the server for server-made operations."""

    def __init__(self, device: uuid.UUID | str, last_ms: int = 0, counter: int = 0) -> None:
        self.device = str(device)
        self.last_ms = last_ms
        self.counter = counter

    def send(self, now_ms: int) -> str:
        if now_ms > self.last_ms:
            self.last_ms, self.counter = now_ms, 0
        else:
            self.counter += 1
        if self.counter > MAX_COUNTER:
            self.last_ms, self.counter = self.last_ms + 1, 0
        return format_hlc(self.last_ms, self.counter, self.device)

    def receive(self, remote: str, now_ms: int) -> None:
        parsed = parse_hlc(remote)
        new_ms = max(self.last_ms, parsed.ms, now_ms)
        if new_ms == self.last_ms == parsed.ms:
            self.counter = max(self.counter, parsed.counter) + 1
        elif new_ms == self.last_ms:
            self.counter += 1
        elif new_ms == parsed.ms:
            self.counter = parsed.counter + 1
        else:
            self.counter = 0
        self.last_ms = new_ms
        if self.counter > MAX_COUNTER:
            self.last_ms, self.counter = self.last_ms + 1, 0
