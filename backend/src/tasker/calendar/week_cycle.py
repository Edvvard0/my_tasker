"""Alternating weeks (spec stage2 section 6): cycle week numbers and first-occurrence helper."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, timedelta

Shift = tuple[date, int]  # (from date, offset in weeks): "shift the parity" records


@dataclass(frozen=True, slots=True)
class Cycle:
    """The ``calendar.week_cycle`` setting."""

    week1_start: date
    length: int
    shifts: tuple[Shift, ...] = ()


def monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def cycle_week(day: date, week1_start: date, length: int, shifts: Sequence[Shift] = ()) -> int:
    """1-based number of the cycle week that contains ``day``.

    ``week1_start`` may be any date of week 1 (it is normalised to that week's Monday). Each
    shift adds its offset to every week from the Monday of its ``from`` date onwards. Floor
    division and a non-negative modulo make dates before the anchor work.
    """
    monday = monday_of(day)
    weeks = (monday - monday_of(week1_start)).days // 7
    weeks += sum(offset for start, offset in shifts if monday_of(start) <= monday)
    return weeks % length + 1


def first_date(after: date, weekday: int, week: int, cycle: "Cycle") -> date:
    """Earliest date >= ``after`` that is ``weekday`` (0=Monday) inside cycle week ``week``."""
    candidate = monday_of(after) + timedelta(days=weekday)
    if candidate < after:
        candidate += timedelta(days=7)
    while cycle_week(candidate, cycle.week1_start, cycle.length, cycle.shifts) != week:
        candidate += timedelta(days=7)
    return candidate
