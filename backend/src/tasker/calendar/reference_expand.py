"""REFERENCE implementation of recurrence expansion (python-dateutil).

The clients expand on their own (Dart); this module exists to produce and validate the shared
vectors ``shared-test-vectors/calendar/rrule_expand.json``. The algorithm is normative and
specified in ``docs/specs/stage2_calendar_tasks.md`` section 5.3.
"""

from collections.abc import Iterator, Mapping
from datetime import UTC, date, datetime, timedelta
from typing import Any, Literal
from zoneinfo import ZoneInfo

from dateutil import rrule as du

from tasker.calendar.rrule_subset import Rule, parse_rrule
from tasker.calendar.timefmt import format_utc, parse_date, parse_utc

_FREQ: dict[str, Literal[0, 1, 2, 3]] = {"YEARLY": 0, "MONTHLY": 1, "WEEKLY": 2, "DAILY": 3}
_MAX_ITERATIONS = 200_000


def local_to_utc(naive: datetime, zone: ZoneInfo) -> datetime:
    """Wall time -> UTC. Ambiguous or missing wall times use the offset BEFORE the transition."""
    return naive.replace(tzinfo=zone, fold=0).astimezone(UTC)


def _weekday(entry: tuple[int | None, int]) -> Any:
    ordinal, weekday = entry
    day = du.weekdays[weekday]
    return day(ordinal) if ordinal is not None else day


def _local_starts(rule: Rule, first_local: datetime) -> Iterator[datetime]:
    """Occurrence starts as naive wall-clock datetimes, ascending, ignoring UNTIL."""
    byweekday = [_weekday(entry) for entry in rule.byday] or None
    bymonthday = list(rule.bymonthday) or None
    generator = du.rrule(
        _FREQ[rule.freq],
        dtstart=first_local,
        interval=rule.interval,
        count=rule.count,
        byweekday=byweekday,
        bymonthday=bymonthday,
        wkst=du.MO,
    )
    for index, value in enumerate(generator):
        if index >= _MAX_ITERATIONS:
            raise RuntimeError("expansion did not reach the window")
        yield value


def _date(text: str) -> date:
    parsed = parse_date(text)
    if parsed is None:
        raise ValueError(f"not a date: {text!r}")
    return parsed


def _instant(text: str) -> datetime:
    parsed = parse_utc(text)
    if parsed is None:
        raise ValueError(f"not a UTC instant: {text!r}")
    return parsed


class _Series:
    """One event's occurrences as ``(original_key, start, end)`` in a uniform representation."""

    def __init__(self, event: Mapping[str, Any]) -> None:
        self.all_day: bool = bool(event["all_day"])
        rule_text = event.get("rrule")
        self.rule = parse_rrule(rule_text, all_day=self.all_day) if rule_text else None
        if self.all_day:
            start, end = _date(event["start"]), _date(event["end"])
            self.first_local = datetime(start.year, start.month, start.day)
            self.span_days = (end - start).days
            self.zone = ZoneInfo("UTC")
            self.duration = timedelta(0)
        else:
            self.zone = ZoneInfo(event["tz"])
            start_utc, end_utc = _instant(event["start"]), _instant(event["end"])
            self.first_local = start_utc.astimezone(self.zone).replace(tzinfo=None)
            self.duration = end_utc - start_utc
            self.span_days = 0

    def original_starts(self) -> Iterator[str]:
        """Original instance keys in ascending order (date or UTC instant strings)."""
        if self.rule is None:
            yield self._key(self.first_local)
            return
        rule = self.rule
        for local in _local_starts(rule, self.first_local):
            if self.all_day:
                if rule.until_date is not None and local.date() > rule.until_date:
                    return
                yield local.date().isoformat()
            else:
                instant = local_to_utc(local, self.zone)
                if rule.until_utc is not None and instant > rule.until_utc:
                    return
                yield format_utc(instant)

    def _key(self, local: datetime) -> str:
        if self.all_day:
            return local.date().isoformat()
        return format_utc(local_to_utc(local, self.zone))

    def span(self, key: str) -> tuple[str, str]:
        """Original ``(start, end)`` of the instance with this key (end inclusive for dates)."""
        if self.all_day:
            return key, (_date(key) + timedelta(days=self.span_days)).isoformat()
        return key, format_utc(_instant(key) + self.duration)


def _overlaps(start: str, end: str, window: Mapping[str, str], *, all_day: bool) -> bool:
    lo, hi = window["from"], window["to"]
    if all_day:
        end_day = date.fromisoformat(end) + timedelta(days=1)
        return start < hi and end_day.isoformat() > lo
    if end == start:
        return lo <= start < hi
    return start < hi and end > lo


def expand(event: Mapping[str, Any]) -> list[dict[str, str]]:
    """Instances of the series that overlap ``event["window"]``, sorted by start.

    ``event`` is the ``input`` object of a ``rrule_expand.json`` case.
    """
    series = _Series(event)
    window: Mapping[str, str] = event["window"]
    cancelled = set(event.get("cancelled", ()))
    overrides = {o["original_start"]: o for o in event.get("overrides", ())}
    overrides = {key: o for key, o in overrides.items() if key not in cancelled}
    title = str(event.get("title", ""))
    found: dict[str, dict[str, str]] = {}
    for key in series.original_starts():
        if key >= window["to"]:
            break
        if key in cancelled:
            continue
        start, end = series.span(key)
        if key in overrides:
            # An override is applied below whether or not the original slot is in the window.
            continue
        if _overlaps(start, end, window, all_day=series.all_day):
            found[key] = {"original_start": key, "start": start, "end": end, "title": title}
    valid_keys = _valid_override_keys(series, overrides)
    for key in valid_keys:
        override = overrides[key]
        start, end = series.span(key)
        if override.get("start") is not None:
            start, end = str(override["start"]), str(override["end"])
        if _overlaps(start, end, window, all_day=series.all_day):
            found[key] = {
                "original_start": key,
                "start": start,
                "end": end,
                "title": str(override.get("title") or title),
            }
    return sorted(found.values(), key=lambda i: (i["start"], i["original_start"]))


def _valid_override_keys(series: _Series, overrides: Mapping[str, Any]) -> list[str]:
    """Overrides whose ``original_start`` really is an occurrence of the rule."""
    if not overrides:
        return []
    wanted = set(overrides)
    last = max(wanted)
    valid: list[str] = []
    for key in series.original_starts():
        if key in wanted:
            valid.append(key)
        if key >= last:
            break
    return valid
