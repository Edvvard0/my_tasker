"""Strict string forms of dates and instants used in synced columns and vectors."""

import re
from datetime import UTC, date, datetime

_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")

DATE_PATTERN = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
UTC_PATTERN = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"


def parse_date(text: str) -> date | None:
    """``YYYY-MM-DD`` (a real calendar date, years 1970-2200) or None."""
    if not _DATE.fullmatch(text):
        return None
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        return None
    return parsed if 1970 <= parsed.year <= 2200 else None


def parse_utc(text: str) -> datetime | None:
    """``YYYY-MM-DDTHH:MM:SSZ`` (whole seconds, UTC) or None."""
    if not _UTC.fullmatch(text):
        return None
    try:
        parsed = datetime.fromisoformat(text[:-1]).replace(tzinfo=UTC)
    except ValueError:
        return None
    return parsed if 1970 <= parsed.year <= 2200 else None


def format_utc(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
