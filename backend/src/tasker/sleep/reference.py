"""Reference rules of Stage 8: sleep arithmetic, averages, the sleep/tasks link, ritual streaks and
the carry-over of tasks (spec: ``docs/specs/stage8_sleep_rituals.md``).

Pure functions over JSON-shaped rows (dicts with the table column names; moments
``YYYY-MM-DDTHH:MM:SSZ`` in UTC, dates ``YYYY-MM-DD``). All arithmetic is integer: durations are
whole minutes (floor), shares are basis points (floor), averages are whole minutes (floor). The
Dart client runs the same rules on ``shared-test-vectors/sleep/``.
"""

from collections.abc import Iterable, Mapping, Sequence
from datetime import UTC, date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from tasker.calendar.timefmt import format_utc, parse_date, parse_utc

Row = Mapping[str, Any]
Rows = Sequence[Row]

MAX_SLEEP_MINUTES = 24 * 60
SHORT_SLEEP_MINUTES = 360  # a night shorter than 6 hours is "short"
MIN_GROUP_DAYS = 2  # days with tasks per group before the comparison counts as meaningful
WEEK_DAYS = 7
BASIS = 10_000


# ------------------------------------------------------------------ one night


def duration_minutes(bed_at: str, wake_at: str) -> int | None:
    """Whole minutes (floor) between two UTC moments; ``None`` unless 0 < length <= 24 h or when a
    moment is malformed. Time zones play no part: the length is the difference of the instants, so
    a night over midnight, over a change of time zone or over a daylight-saving switch is simply
    ``wake - bed``."""
    bed, wake = parse_utc(bed_at), parse_utc(wake_at)
    if bed is None or wake is None:
        return None
    seconds = int((wake - bed).total_seconds())
    if seconds <= 0 or seconds > MAX_SLEEP_MINUTES * 60:
        return None
    return seconds // 60


def local_moment(moment: str, tz: str) -> datetime | None:
    parsed = parse_utc(moment)
    return None if parsed is None else parsed.astimezone(ZoneInfo(tz))


def sleep_date(wake_at: str, wake_tz: str) -> str | None:
    """The date of a sleep: the local date of waking up in the zone where the person woke."""
    local = local_moment(wake_at, wake_tz)
    return None if local is None else local.date().isoformat()


def local_clock(moment: str, tz: str) -> str | None:
    """``HH:MM`` of a moment on the wall clock of ``tz`` (minutes are cut, not rounded)."""
    local = local_moment(moment, tz)
    return None if local is None else f"{local.hour:02d}:{local.minute:02d}"


def entry_view(row: Row) -> dict[str, Any] | None:
    """What a sleep row shows: the duration, the date it belongs to and the two wall-clock times
    (bed in ``bed_tz``, which defaults to ``wake_tz``; wake in ``wake_tz``). ``None`` when the row
    is invalid (a bad moment or length)."""
    minutes = duration_minutes(row["bed_at"], row["wake_at"])
    if minutes is None:
        return None
    wake_tz = row["wake_tz"]
    bed_tz = row.get("bed_tz") or wake_tz
    return {
        "date": sleep_date(row["wake_at"], wake_tz),
        "minutes": minutes,
        "bed_local": local_clock(row["bed_at"], bed_tz),
        "wake_local": local_clock(row["wake_at"], wake_tz),
    }


# ------------------------------------------------------------------ windows


def window(through: str, days: int) -> tuple[date, date]:
    """The ``days`` dates ending at ``through`` inclusive."""
    last = parse_date(through)
    if last is None or days < 1:
        raise ValueError("a window needs a real date and at least one day")
    return last - timedelta(days=days - 1), last


def _minutes_by_date(entries: Rows, first: date, last: date) -> dict[str, int]:
    """Sleep minutes per date of the window; invalid rows are skipped, the highest id wins when a
    date has two rows (cannot happen with the deterministic ids)."""
    found: dict[str, int] = {}
    for row in sorted(entries, key=lambda r: str(r.get("id", ""))):
        view = entry_view(row)
        if view is None:
            continue
        day = parse_date(str(row["date"]))
        if day is not None and first <= day <= last:
            found[day.isoformat()] = view["minutes"]
    return found


def average_sleep(entries: Rows, through: str, days: int) -> dict[str, Any]:
    """The average night of the window. Days without an entry are *skipped*, never counted as
    zero: ``average_minutes = floor(sum / days_with_data)``, ``None`` without any entry."""
    first, last = window(through, days)
    by_date = _minutes_by_date(entries, first, last)
    total = sum(by_date.values())
    return {
        "from": first.isoformat(),
        "to": last.isoformat(),
        "days": days,
        "days_with_data": len(by_date),
        "total_minutes": total,
        "average_minutes": total // len(by_date) if by_date else None,
    }


# ------------------------------------------------------------------ sleep and tasks


def task_day(task: Row) -> str | None:
    """The local date a task is planned for: ``due_date``, or the date of ``due_at`` on the wall
    clock of ``due_tz``; ``None`` for a task without a date."""
    if task.get("due_date"):
        return str(task["due_date"])
    if task.get("due_at") and task.get("due_tz"):
        local = local_moment(str(task["due_at"]), str(task["due_tz"]))
        return None if local is None else local.date().isoformat()
    return None


def _counts_for_link(task: Row) -> bool:
    return not task.get("rrule") and task.get("status") != "cancelled"


def _group(days: int, tasks: int, done: int) -> dict[str, Any]:
    return {
        "days": days,
        "tasks": tasks,
        "done": done,
        "share_bp": done * BASIS // tasks if tasks else None,
    }


def sleep_task_link(entries: Rows, tasks: Rows, through: str) -> dict[str, Any]:
    """Compare the share of finished tasks on days after a short night (< 6 h) with the days after
    a normal one, over the last 7 days. Not a statistic and not a cause: two pooled shares.

    For every date of the window with a sleep entry the tasks planned for that date count
    (recurring and cancelled tasks do not); ``done`` is status ``done``. A date without tasks takes
    no part. Per group ``share_bp = floor(10000 * done / tasks)`` (pooled over its days);
    ``difference_bp = normal - short`` when both exist; ``enough_data`` needs at least 2 days with
    tasks in each group."""
    first, last = window(through, WEEK_DAYS)
    minutes = _minutes_by_date(entries, first, last)
    planned: dict[str, list[int]] = {}  # date -> [tasks, done]
    for task in tasks:
        day = task_day(task)
        if day is None or not _counts_for_link(task):
            continue
        parsed = parse_date(day)
        if parsed is None or not first <= parsed <= last:
            continue
        counts = planned.setdefault(day, [0, 0])
        counts[0] += 1
        counts[1] += 1 if task.get("status") == "done" else 0
    groups = {"short": [0, 0, 0], "normal": [0, 0, 0]}  # days, tasks, done
    without_sleep = 0
    for day, (count, done) in planned.items():
        if day not in minutes:
            without_sleep += 1
            continue
        key = "short" if minutes[day] < SHORT_SLEEP_MINUTES else "normal"
        groups[key][0] += 1
        groups[key][1] += count
        groups[key][2] += done
    short, normal = (_group(*groups[k]) for k in ("short", "normal"))
    difference = (
        normal["share_bp"] - short["share_bp"]
        if short["share_bp"] is not None and normal["share_bp"] is not None
        else None
    )
    return {
        "from": first.isoformat(),
        "to": last.isoformat(),
        "threshold_minutes": SHORT_SLEEP_MINUTES,
        "short": short,
        "normal": normal,
        "difference_bp": difference,
        "days_without_sleep": without_sleep,
        "enough_data": short["days"] >= MIN_GROUP_DAYS and normal["days"] >= MIN_GROUP_DAYS,
    }


# ------------------------------------------------------------------ ritual streaks


def streak(dates: Iterable[str], through: str) -> dict[str, Any]:
    """Consecutive days with a ritual. ``current`` counts back from ``through``; if ``through``
    itself is not done yet the streak is still alive and counts back from the day before. ``best``
    is the longest run up to ``through``; ``last`` the latest done date up to ``through``. Dates
    after ``through`` and malformed ones are ignored."""
    end = parse_date(through)
    if end is None:
        raise ValueError("through must be a real date")
    done = {d for d in (parse_date(x) for x in dates) if d is not None and d <= end}
    cursor = end if end in done else end - timedelta(days=1)
    current = 0
    while cursor in done:
        current += 1
        cursor -= timedelta(days=1)
    best = run = 0
    previous: date | None = None
    for day in sorted(done):
        run = run + 1 if previous is not None and day - previous == timedelta(days=1) else 1
        best = max(best, run)
        previous = day
    return {"current": current, "best": best, "last": max(done).isoformat() if done else None}


def ritual_streaks(morning: Iterable[str], evening: Iterable[str], through: str) -> dict[str, Any]:
    """Streaks of the morning plan, the evening check-in and of days with both."""
    plan, checkin = set(morning), set(evening)
    return {
        "morning": streak(plan, through),
        "evening": streak(checkin, through),
        "both": streak(plan & checkin, through),
    }


# ------------------------------------------------------------------ carry-over of tasks


def _at_local_date(moment: str, tz: str, target: date) -> str:
    """The same wall-clock time on ``target`` in ``tz``, as a UTC moment. A time that does not exist
    (daylight-saving gap) uses the offset from before the switch, so it lands one gap later; an
    ambiguous one means its first occurrence (both: PEP 495 ``fold = 0``, Temporal "compatible")."""
    local = local_moment(moment, tz)
    assert local is not None  # noqa: S101 - the caller checked the moment
    wall = datetime(
        target.year, target.month, target.day, local.hour, local.minute, local.second,
        tzinfo=ZoneInfo(tz),
    )  # fmt: skip
    return format_utc(wall.astimezone(UTC))


def _skip(task_id: str, reason: str) -> dict[str, Any]:
    return {"task_id": task_id, "action": "skip", "reason": reason}


def plan_carry_over(checkin_date: str, decisions: Rows, tasks: Rows) -> list[dict[str, Any]]:
    """What to change for the tasks the evening check-in moves; one result per decision, in order.

    ``to = tomorrow`` is the day after ``checkin_date``; ``to = date`` must be after
    ``checkin_date``. A task with ``due_date`` (or without any date) gets the new ``due_date``; a
    task with ``due_at`` keeps its wall-clock time in ``due_tz`` on the new date. An ``inbox`` task
    also becomes ``todo`` (a dated task is "to do"). The result is a plan: the server writes
    nothing, the client applies it through ordinary sync. Skips: ``not_found``, ``closed`` (done or
    cancelled), ``recurring``, ``duplicate`` (a task twice), ``not_in_future``, ``unchanged``."""
    today = parse_date(checkin_date)
    if today is None:
        raise ValueError("checkin_date must be a real date")
    by_id = {str(t["id"]): t for t in tasks}
    seen: set[str] = set()
    results: list[dict[str, Any]] = []
    for decision in decisions:
        task_id = str(decision["task_id"])
        task = by_id.get(task_id)
        if task_id in seen:
            results.append(_skip(task_id, "duplicate"))
            continue
        seen.add(task_id)
        if task is None:
            results.append(_skip(task_id, "not_found"))
            continue
        if task.get("status") in ("done", "cancelled"):
            results.append(_skip(task_id, "closed"))
            continue
        if task.get("rrule"):
            results.append(_skip(task_id, "recurring"))
            continue
        target = today + timedelta(days=1) if decision["to"] == "tomorrow" else None
        if target is None:
            target = parse_date(str(decision.get("date")))
        if target is None or target <= today:
            results.append(_skip(task_id, "not_in_future"))
            continue
        timed = bool(task.get("due_at") and task.get("due_tz"))
        if timed and task_day(task) == target.isoformat():
            results.append(_skip(task_id, "unchanged"))
            continue
        if not timed and task.get("due_date") == target.isoformat():
            results.append(_skip(task_id, "unchanged"))
            continue
        change: dict[str, Any] = {"task_id": task_id}
        if timed:
            change |= {
                "action": "set_due_at",
                "due_at": _at_local_date(str(task["due_at"]), str(task["due_tz"]), target),
                "due_tz": task["due_tz"],
            }
        else:
            change |= {"action": "set_due_date", "due_date": target.isoformat()}
        change["status"] = "todo" if task.get("status") == "inbox" else None
        results.append(change)
    return results
