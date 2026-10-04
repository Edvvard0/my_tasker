"""Reference rules of the Study module (spec: ``docs/specs/stage7_study.md``).

Pure functions over JSON-shaped rows (dicts with the table column names; dates ``YYYY-MM-DD``,
times ``HH:MM``). The schedule of a date is *computed* from the semester, the bell grid, the slots,
the special-day rules, the per-date overrides and the Russian holidays; it is never stored. The Dart
client runs the same rules on ``shared-test-vectors/study/``.
"""

import re
from collections.abc import Mapping, Sequence
from datetime import date, timedelta
from typing import Any

from tasker.calendar.week_cycle import cycle_week

Row = Mapping[str, Any]
Rows = Sequence[Row]

LESSON_KINDS = ("lecture", "practice", "lab", "other")
UNSORTED_TIME = "99:99"
UNSORTED_NUMBER = 99
HOLIDAY_TYPES = ("holiday", "transfer_off")
NEAR_NUMERATOR, NEAR_DENOMINATOR = 3, 4  # "close to the limit" from 3/4 of it
_TIME = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])")


# ------------------------------------------------------------------ times and rooms


def to_minutes(text: str) -> int:
    """Minutes since midnight of an ``HH:MM`` time."""
    return int(text[:2]) * 60 + int(text[3:])


def from_minutes(minutes: int) -> str:
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def generate_bells(
    first_start: str, duration: int, breaks: int | Sequence[int], count: int
) -> list[dict[str, Any]] | None:
    """The bell grid from the start of pair 1, the length of a pair and the breaks after pairs
    (one number for all, or a list: ``breaks[i]`` follows pair ``i + 1``). ``None`` when the
    arguments are out of range or the last pair ends after 23:59."""
    if not _TIME.fullmatch(first_start) or not 1 <= count <= 12 or not 1 <= duration <= 300:
        return None
    gaps = [breaks] * (count - 1) if isinstance(breaks, int) else list(breaks)
    if len(gaps) < count - 1 or any(not 0 <= gap <= 240 for gap in gaps[: count - 1]):
        return None
    result = []
    start = to_minutes(first_start)
    for number in range(1, count + 1):
        end = start + duration
        if end > 23 * 60 + 59:
            return None
        result.append(
            {"number": number, "start_time": from_minutes(start), "end_time": from_minutes(end)}
        )
        if number < count:
            start = end + gaps[number - 1]
    return result


_ROOM_MARK = r"(?:кабинет|каб|аудитория|ауд|к)"
_BUILDING_MARK = r"(?:корпус|корп|к|k)"
_ROOM_NUMBER = r"([0-9]+[a-zа-я]?)"
_SEPARATED = rf"(?:[ .,/\-]+{_ROOM_MARK}?[. ]*|{_ROOM_MARK}[. ]*)"
_WITH_MARK = re.compile(rf"{_BUILDING_MARK}[. ]*([0-9]{{1,2}}){_SEPARATED}{_ROOM_NUMBER}")
_PLAIN_PAIR = re.compile(rf"([0-9]{{1,2}})[ .,/\-]+{_ROOM_NUMBER}")
MAX_ROOM_LENGTH = 20


_SPACES = " \u00a0\u202f\u2009\t\r\n"


def _collapse(text: str) -> str:
    """Whitespace runs (only the characters of ``_SPACES``) become one space; the ends trim."""
    flat = "".join(" " if char in _SPACES else char for char in text)
    return " ".join(part for part in flat.split(" ") if part)


def _fold(text: str) -> str:
    """Lower case for ASCII and Cyrillic only; ё = е."""
    out = []
    for char in text:
        if "A" <= char <= "Z" or "А" <= char <= "Я":
            out.append(chr(ord(char) + 32))
        elif char in ("ё", "Ё"):
            out.append("е")
        else:
            out.append(char)
    return "".join(out)


def parse_room(text: str) -> dict[str, str | None] | None:
    """``"к1 28"`` -> ``{"building": "1", "room": "28"}``. Also ``К2 101``, ``к 1 28``, ``к1-28``,
    ``корп. 2 каб. 101``, ``1-28``, ``2 101``, a bare ``28`` (no building) or any other short text
    (kept as the room, e.g. ``спортзал``). ``None`` for an empty or too long text."""
    collapsed = _collapse(text)
    if not collapsed or len(collapsed) > MAX_ROOM_LENGTH:
        return None
    folded = _fold(collapsed)
    for pattern in (_WITH_MARK, _PLAIN_PAIR):
        match = pattern.fullmatch(folded)
        if match:
            return {"building": match[1], "room": match[2]}
    return {"building": None, "room": collapsed}


def format_room(building: str | None, room: str | None) -> str:
    """The way a room is shown and typed: ``к1 28``; a building without a room ``к1``."""
    if building and room:
        return f"к{building} {room}"
    if building:
        return f"к{building}"
    return room or ""


# ------------------------------------------------------------------ semester, holidays


def _day(text: str) -> date:
    return date.fromisoformat(text)


def week_number(day: str, semester: Row) -> int:
    """The cycle week (1-based) of ``day`` in the semester's own cycle."""
    shifts = tuple((_day(s["from"]), int(s["weeks"])) for s in semester.get("week_shifts") or [])
    return cycle_week(
        _day(day), _day(semester["week1_start"]), int(semester["cycle_length"]), shifts
    )


def semester_for(day: str, semesters: Rows) -> Row | None:
    """The live semester that contains ``day`` (several: the latest start, then the largest id)."""
    found = [
        s for s in semesters if not s.get("archived") and s["start_date"] <= day <= s["end_date"]
    ]
    return max(found, key=lambda s: (s["start_date"], s["id"])) if found else None


def holidays_between(data: Mapping[str, Any], first: str, last: str) -> dict[str, str]:
    """Non-teaching days from the Stage 2 holiday file: only listed ``holiday`` and
    ``transfer_off`` days (a plain Saturday or Sunday is a teaching day for a university)."""
    found: dict[str, str] = {}
    for year in range(_day(first).year, _day(last).year + 1):
        for entry in (data["years"].get(str(year)) or {"days": []})["days"]:
            if entry["type"] in HOLIDAY_TYPES and first <= entry["date"] <= last:
                found[entry["date"]] = entry["name"]
    return found


# ------------------------------------------------------------------ lessons of a date


def _times(
    number: int | None,
    own_start: str | None,
    own_end: str | None,
    semester_id: str,
    day: str,
    bells: Rows,
) -> tuple[str | None, str | None]:
    """Own time of the lesson, else the bell of its number on ``day`` (a bell row for exactly that
    date beats the semester's regular grid)."""
    if own_start is not None:
        return own_start, own_end
    if number is None:
        return None, None
    mine = [b for b in bells if b["semester_id"] == semester_id and b["number"] == number]
    chosen = next((b for b in mine if b.get("on_date") == day), None) or next(
        (b for b in mine if b.get("on_date") is None), None
    )
    return (chosen["start_time"], chosen["end_time"]) if chosen else (None, None)


def _pair(*levels: tuple[str | None, str | None]) -> tuple[str | None, str | None]:
    """The first level that names a building or a room (the pair is never mixed)."""
    for building, room in levels:
        if building or room:
            return building, room
    return None, None


def _lesson(
    day: str,
    semester: Row,
    slot: Row,
    subjects: Mapping[str, Row],
    bells: Rows,
    override: Row | None,
    *,
    scheduled: str,
    moved_from: str | None = None,
    moved_to: str | None = None,
) -> dict[str, Any]:
    """A regular lesson on ``day``. A lesson moved *away* keeps its original look (the changes of
    the move belong to the day it moves to)."""
    applies = override is not None and override["action"] != "cancel" and moved_to is None
    changes: Mapping[str, Any] = override if applies and override is not None else {}
    subject_id = changes.get("subject_id") or slot.get("subject_id")
    subject = subjects.get(subject_id) if subject_id else None
    start, end = _times(
        slot.get("number"), slot.get("start_time"), slot.get("end_time"), semester["id"], day, bells
    )
    if changes.get("start_time") is not None:
        start, end = changes["start_time"], changes["end_time"]
    building, room = _pair(
        (changes.get("building"), changes.get("room")),
        (slot.get("building"), slot.get("room")),
        (subject.get("building"), subject.get("room")) if subject else (None, None),
    )
    title = changes.get("title") or slot.get("title") or (subject["name"] if subject else None)
    cancelled = override is not None and override["action"] == "cancel"
    return {
        "key": f"slot:{slot['id']}@{scheduled}",
        "source": "slot",
        "slot_id": slot["id"],
        "rule_id": None,
        "scheduled_date": scheduled,
        "date": day,
        "number": slot.get("number"),
        "start": start,
        "end": end,
        "title": title,
        "subject_id": subject_id,
        "kind": changes.get("lesson_kind") or slot["kind"],
        "building": building,
        "room": room,
        "room_text": format_room(building, room),
        "cancelled": cancelled,
        "changed": applies,
        "moved_from": moved_from,
        "moved_to": moved_to,
        "override_id": override["id"] if override is not None else None,
        "trackable": not cancelled and moved_to is None,
    }


def _on_cycle_week(item: Row, number: int) -> bool:
    return item.get("cycle_week") is None or item["cycle_week"] == number


def _item_lesson(day: str, semester: Row, rule: Row, item: Row, bells: Rows) -> dict[str, Any]:
    start, end = _times(
        item.get("number"), item.get("start_time"), item.get("end_time"), semester["id"], day, bells
    )
    building, room = item.get("building"), item.get("room")
    return {
        "key": f"rule:{rule['id']}:{item['key']}",
        "source": "rule",
        "slot_id": None,
        "rule_id": rule["id"],
        "scheduled_date": day,
        "date": day,
        "number": item.get("number"),
        "start": start,
        "end": end,
        "title": item["title"],
        "subject_id": None,
        "kind": item["kind"],
        "building": building,
        "room": room,
        "room_text": format_room(building, room),
        "cancelled": False,
        "changed": False,
        "moved_from": None,
        "moved_to": None,
        "override_id": None,
        "trackable": False,
    }


def _order(lesson: Row) -> tuple[str, int, str]:
    number = lesson["number"]
    return (
        lesson["start"] or UNSORTED_TIME,
        UNSORTED_NUMBER if number is None else number,
        lesson["key"],
    )


def _active_rule(day: str, weekday: int, week: int, rules: Rows) -> Row | None:
    """A rule for exactly this date beats a weekday rule (maybe limited to one cycle week)."""
    dated = [r for r in rules if r.get("on_date") == day]
    if dated:
        return max(dated, key=lambda r: r["id"])
    weekly = [
        r
        for r in rules
        if r.get("on_date") is None and r.get("weekday") == weekday and _on_cycle_week(r, week)
    ]
    return max(weekly, key=lambda r: (r.get("cycle_week") is not None, r["id"])) if weekly else None


def expand_day(
    day: str,
    semesters: Rows,
    subjects: Rows,
    bells: Rows,
    slots: Rows,
    day_rules: Rows,
    overrides: Rows,
    holidays: Mapping[str, str],
) -> dict[str, Any]:
    """The schedule of one date.

    Order of precedence for what the day is: a day rule for exactly this date, then a holiday,
    then a weekday rule (``hide_regular`` removes the regular lessons, its ``items`` are the day's
    own occupations), otherwise a regular day. Overrides (cancel / change / move) apply to regular
    lessons; a lesson moved here is shown whatever the day is.
    """
    weekday = _day(day).isoweekday()
    semester = semester_for(day, semesters)
    if semester is None:
        return {
            "date": day,
            "weekday": weekday,
            "semester_id": None,
            "cycle_week": None,
            "day": {"kind": "no_semester", "name": None, "rule_id": None},
            "lessons": [],
        }
    week = week_number(day, semester)
    by_subject = {s["id"]: s for s in subjects}
    my_slots = {s["id"]: s for s in slots if s["semester_id"] == semester["id"]}
    my_rules = [r for r in day_rules if r["semester_id"] == semester["id"]]
    by_slot_date = {
        (o["slot_id"], o["date"]): o
        for o in sorted(overrides, key=lambda o: o["id"])
        if o["slot_id"] in my_slots
    }

    rule = _active_rule(day, weekday, week, my_rules)
    dated_rule = rule is not None and rule.get("on_date") == day
    holiday = holidays.get(day)
    if dated_rule or (rule is not None and holiday is None):
        assert rule is not None  # noqa: S101 - narrowed above
        kind, name, rule_id = "special", rule["title"], rule["id"]
    elif holiday is not None:
        kind, name, rule_id = "holiday", holiday, None
    else:
        kind, name, rule_id = "regular", None, None

    lessons: list[dict[str, Any]] = []
    shows_regular = kind == "regular" or (
        kind == "special" and rule is not None and not rule["hide_regular"]
    )
    for slot in my_slots.values():
        if slot["weekday"] != weekday or not _on_cycle_week(slot, week):
            continue
        override = by_slot_date.get((slot["id"], day))
        if shows_regular:
            moved_to = override["new_date"] if override and override["action"] == "move" else None
            lessons.append(
                _lesson(
                    day,
                    semester,
                    slot,
                    by_subject,
                    bells,
                    override,
                    scheduled=day,
                    moved_to=moved_to,
                )
            )
    if kind == "special" and rule is not None:
        lessons.extend(
            _item_lesson(day, semester, rule, item, bells)
            for item in rule["items"]
            if _on_cycle_week(item, week)
        )
    for (slot_id, original), override in by_slot_date.items():
        if override["action"] == "move" and override["new_date"] == day:
            lessons.append(
                _lesson(
                    day,
                    semester,
                    my_slots[slot_id],
                    by_subject,
                    bells,
                    override,
                    scheduled=original,
                    moved_from=original,
                )
            )
    lessons.sort(key=_order)
    return {
        "date": day,
        "weekday": weekday,
        "semester_id": semester["id"],
        "cycle_week": week,
        "day": {"kind": kind, "name": name, "rule_id": rule_id},
        "lessons": lessons,
    }


def expand_range(
    first: str,
    last: str,
    semesters: Rows,
    subjects: Rows,
    bells: Rows,
    slots: Rows,
    day_rules: Rows,
    overrides: Rows,
    holidays: Mapping[str, str],
) -> list[dict[str, Any]]:
    """``expand_day`` for every date from ``first`` to ``last`` inclusive."""
    days = []
    current = _day(first)
    while current <= _day(last):
        days.append(
            expand_day(
                current.isoformat(),
                semesters,
                subjects,
                bells,
                slots,
                day_rules,
                overrides,
                holidays,
            )
        )
        current += timedelta(days=1)
    return days


# ------------------------------------------------------------------ attendance


def attendance_state(absent: int, limit: int | None) -> str:
    """``no_limit``, ``ok``, ``near`` (from three quarters of the limit), ``reached`` (equal),
    ``over``."""
    if limit is None:
        return "no_limit"
    if absent > limit:
        return "over"
    if absent == limit:
        return "reached"
    return "near" if absent * NEAR_DENOMINATOR >= limit * NEAR_NUMERATOR else "ok"


def attendance_summary(
    through: str,
    semesters: Rows,
    subjects: Rows,
    bells: Rows,
    slots: Rows,
    day_rules: Rows,
    overrides: Rows,
    holidays: Mapping[str, str],
    attendance: Rows,
) -> list[dict[str, Any]]:
    """Per subject (in input order): counts of lessons from the semester start through ``through``.

    Only regular lessons of the subject count: lessons of special days (day rules), holidays and
    lessons moved away are not lessons at all; a lesson cancelled by an override, or marked
    ``cancelled``, is ``cancelled`` and never an absence; an unmarked one is ``unmarked``.
    """
    marks = {(a["slot_id"], a["date"]): a["status"] for a in attendance}
    counts: dict[str, dict[str, int]] = {
        s["id"]: {"present": 0, "absent": 0, "cancelled": 0, "unmarked": 0} for s in subjects
    }
    for semester in semesters:
        if semester.get("archived"):
            continue
        last = min(through, semester["end_date"])
        for entry in expand_range(
            semester["start_date"],
            last,
            [semester],
            subjects,
            bells,
            slots,
            day_rules,
            overrides,
            holidays,
        ):
            for lesson in entry["lessons"]:
                if lesson["source"] != "slot" or lesson["moved_to"] is not None:
                    continue
                bucket = counts.get(lesson["subject_id"] or "")
                if bucket is None:
                    continue
                mark = marks.get((lesson["slot_id"], lesson["scheduled_date"]))
                if lesson["cancelled"] or mark == "cancelled":
                    bucket["cancelled"] += 1
                elif mark in ("present", "absent"):
                    bucket["present" if mark == "present" else "absent"] += 1
                else:
                    bucket["unmarked"] += 1
    result = []
    for subject in subjects:
        bucket = counts[subject["id"]]
        limit = subject.get("absence_limit")
        result.append(
            {
                "subject_id": subject["id"],
                **bucket,
                "limit": limit,
                "left": None if limit is None else limit - bucket["absent"],
                "state": attendance_state(bucket["absent"], limit),
            }
        )
    return result
