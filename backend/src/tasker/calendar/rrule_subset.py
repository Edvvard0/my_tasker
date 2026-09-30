"""Strict parser/validator for the supported RRULE subset (spec stage2 section 5).

Only the rule body is stored (no ``RRULE:`` prefix, no ``DTSTART``, no ``EXDATE`` lines):
``FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20261231T210000Z``.
"""

import re
from dataclasses import dataclass
from datetime import date, datetime

from tasker.calendar.timefmt import parse_date, parse_utc

WEEKDAYS = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")
FREQS = ("DAILY", "WEEKLY", "MONTHLY", "YEARLY")
MAX_LENGTH = 200
MAX_COUNT = 1000

_INTERVAL = re.compile(r"[1-9][0-9]{0,2}")
_COUNT = re.compile(r"[1-9][0-9]{0,3}")
_UNTIL_TIMED = re.compile(r"[0-9]{8}T[0-9]{6}Z")
_UNTIL_DATE = re.compile(r"[0-9]{8}")
_BYDAY = re.compile(r"(-?[1-5])?(MO|TU|WE|TH|FR|SA|SU)")
_BYDAY_PLAIN = re.compile(r"(MO|TU|WE|TH|FR|SA|SU)")
_BYMONTHDAY = re.compile(r"-?([1-9]|[12][0-9]|3[01])")
_PART = re.compile(r"([A-Z]+)=([A-Za-z0-9,+-]+)")


class RRuleError(ValueError):
    """The rule is not in the supported subset."""


@dataclass(frozen=True, slots=True)
class Rule:
    freq: str
    interval: int = 1
    count: int | None = None
    until_utc: datetime | None = None  # timed events: inclusive UTC instant
    until_date: date | None = None  # all-day events: inclusive local date
    byday: tuple[tuple[int | None, int], ...] = ()  # (ordinal or None, weekday 0=MO)
    bymonthday: tuple[int, ...] = ()


def _parse_until(value: str, *, all_day: bool) -> tuple[datetime | None, date | None]:
    if all_day:
        if not _UNTIL_DATE.fullmatch(value):
            raise RRuleError("UNTIL of an all-day event must be YYYYMMDD")
        parsed = parse_date(f"{value[:4]}-{value[4:6]}-{value[6:]}")
        if parsed is None:
            raise RRuleError("UNTIL is not a valid date")
        return None, parsed
    if not _UNTIL_TIMED.fullmatch(value):
        raise RRuleError("UNTIL of a timed event must be YYYYMMDDTHHMMSSZ")
    text = f"{value[:4]}-{value[4:6]}-{value[6:8]}T{value[9:11]}:{value[11:13]}:{value[13:15]}Z"
    instant = parse_utc(text)
    if instant is None:
        raise RRuleError("UNTIL is not a valid instant")
    return instant, None


def _parse_byday(value: str, freq: str) -> tuple[tuple[int | None, int], ...]:
    if freq not in ("WEEKLY", "MONTHLY"):
        raise RRuleError("BYDAY is supported only with WEEKLY and MONTHLY")
    items = value.split(",")
    if len(items) > 7 * 2:
        raise RRuleError("BYDAY has too many items")
    result: list[tuple[int | None, int]] = []
    for item in items:
        pattern = _BYDAY if freq == "MONTHLY" else _BYDAY_PLAIN
        match = pattern.fullmatch(item)
        if match is None:
            raise RRuleError(f"BYDAY item {item!r} is not supported for {freq}")
        if freq == "MONTHLY":
            ordinal = int(match.group(1)) if match.group(1) else None
            weekday = WEEKDAYS.index(match.group(2))
        else:
            ordinal, weekday = None, WEEKDAYS.index(match.group(1))
        entry = (ordinal, weekday)
        if entry in result:
            raise RRuleError("BYDAY has duplicates")
        result.append(entry)
    return tuple(result)


def _parse_bymonthday(value: str, freq: str) -> tuple[int, ...]:
    if freq != "MONTHLY":
        raise RRuleError("BYMONTHDAY is supported only with MONTHLY")
    result: list[int] = []
    for item in value.split(","):
        if _BYMONTHDAY.fullmatch(item) is None:
            raise RRuleError(f"BYMONTHDAY item {item!r} is out of range")
        number = int(item)
        if number in result:
            raise RRuleError("BYMONTHDAY has duplicates")
        result.append(number)
    return tuple(result)


def parse_rrule(text: str, *, all_day: bool) -> Rule:  # noqa: PLR0912
    """Parse ``text``; raise :class:`RRuleError` when it is outside the subset."""
    if not text or len(text) > MAX_LENGTH:
        raise RRuleError("rule is empty or too long")
    parts: dict[str, str] = {}
    for chunk in text.split(";"):
        match = _PART.fullmatch(chunk)
        if match is None:
            raise RRuleError(f"malformed part {chunk!r}")
        name, value = match.groups()
        if name in parts:
            raise RRuleError(f"{name} is given twice")
        parts[name] = value
    unknown = set(parts) - {"FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY"}
    if unknown:
        raise RRuleError("unsupported part: " + ", ".join(sorted(unknown)))
    freq = parts.get("FREQ")
    if freq not in FREQS:
        raise RRuleError("FREQ must be DAILY, WEEKLY, MONTHLY or YEARLY")
    interval = 1
    if "INTERVAL" in parts:
        if not _INTERVAL.fullmatch(parts["INTERVAL"]):
            raise RRuleError("INTERVAL must be 1..999")
        interval = int(parts["INTERVAL"])
    if "COUNT" in parts and "UNTIL" in parts:
        raise RRuleError("COUNT and UNTIL are mutually exclusive")
    count: int | None = None
    if "COUNT" in parts:
        if not _COUNT.fullmatch(parts["COUNT"]) or int(parts["COUNT"]) > MAX_COUNT:
            raise RRuleError(f"COUNT must be 1..{MAX_COUNT}")
        count = int(parts["COUNT"])
    until_utc: datetime | None = None
    until_date: date | None = None
    if "UNTIL" in parts:
        until_utc, until_date = _parse_until(parts["UNTIL"], all_day=all_day)
    if "BYDAY" in parts and "BYMONTHDAY" in parts:
        raise RRuleError("BYDAY and BYMONTHDAY cannot be combined")
    byday = _parse_byday(parts["BYDAY"], freq) if "BYDAY" in parts else ()
    bymonthday = _parse_bymonthday(parts["BYMONTHDAY"], freq) if "BYMONTHDAY" in parts else ()
    return Rule(freq, interval, count, until_utc, until_date, byday, bymonthday)


def rrule_problem(text: str, *, all_day: bool) -> str | None:
    """Error message for a rule outside the subset, ``None`` when it is fine."""
    try:
        parse_rrule(text, all_day=all_day)
    except RRuleError as exc:
        return str(exc)
    return None
