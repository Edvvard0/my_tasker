"""Builds ``shared-test-vectors/sleep/*.json``: inputs are written here, expected values come from
the reference implementation (``tasker.sleep.reference``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.sleep_vectors_gen``. A test checks that the files
on disk are exactly this output.
"""

import json
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from tasker.sleep import reference as ref

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "sleep"
Case = tuple[str, dict[str, Any]]  # (name, input)

MSK = "Europe/Moscow"


def moment(text: str) -> str:
    """``2026-10-02T04:00`` or ``2026-10-02T04:00:30`` -> a moment with seconds and ``Z``."""
    if text.endswith("Z"):
        return text
    return f"{text}:00Z" if len(text) == 16 else f"{text}Z"


def night(
    date: str, minutes: int, *, wake_utc: str = "04:00", tz: str = MSK, **over: Any
) -> dict[str, Any]:
    """A Moscow night that ends on ``date`` at 07:00 local (04:00 UTC) and lasts ``minutes``."""
    wake = datetime.fromisoformat(f"{date}T{wake_utc}:00").replace(tzinfo=UTC)
    bed = wake - timedelta(minutes=minutes)
    return {
        "id": f"sleep-{date}",
        "date": date,
        "bed_at": bed.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "wake_at": wake.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bed_tz": None,
        "wake_tz": tz,
        **over,
    }


def task(
    tid: str,
    day: str | None,
    status: str = "todo",
    *,
    due_at: str | None = None,
    due_tz: str | None = None,
    rrule: str | None = None,
) -> dict[str, Any]:
    return {
        "id": tid,
        "status": status,
        "due_date": day if due_at is None else None,
        "due_at": moment(due_at) if due_at else None,
        "due_tz": due_tz,
        "rrule": rrule,
    }


# ------------------------------------------------------------------ duration.json (entry_view)


def view(bed: str, wake: str, wake_tz: str = MSK, bed_tz: str | None = None) -> dict[str, Any]:
    return {"bed_at": moment(bed), "wake_at": moment(wake), "bed_tz": bed_tz, "wake_tz": wake_tz}


DURATION: list[Case] = [
    ("night_over_midnight", view("2026-10-01T20:30", "2026-10-02T04:10")),
    ("bed_after_local_midnight_same_local_date", view("2026-10-02T22:00", "2026-10-03T04:00", MSK)),
    ("minutes_are_floored", view("2026-10-01T20:00:00", "2026-10-02T03:59:59")),
    ("exactly_one_minute", view("2026-10-02T03:59", "2026-10-02T04:00")),
    ("exactly_24_hours_is_valid", view("2026-10-01T04:00", "2026-10-02T04:00")),
    ("24_hours_and_one_second_is_invalid", view("2026-10-01T03:59:59", "2026-10-02T04:00:00")),
    ("wake_equals_bed_is_invalid", view("2026-10-02T04:00", "2026-10-02T04:00")),
    ("wake_before_bed_is_invalid", view("2026-10-02T05:00", "2026-10-02T04:00")),
    (
        "malformed_moment_is_invalid",
        {**view("2026-10-01T20:30", "2026-10-02T04:10"), "bed_at": "2026-10-01 20:30"},
    ),
    (
        "flight_east_moscow_to_vladivostok",
        view("2026-10-01T20:30", "2026-10-02T03:00", "Asia/Vladivostok", MSK),
    ),
    (
        "flight_west_vladivostok_to_moscow",
        view("2026-10-01T14:00", "2026-10-01T22:00", MSK, "Asia/Vladivostok"),
    ),
    (
        "date_is_the_local_date_of_waking_not_the_utc_date",
        view("2026-10-01T18:00", "2026-10-01T21:30"),
    ),
    (
        "date_in_a_west_zone_is_the_previous_utc_day",
        view("2026-10-02T04:00", "2026-10-02T11:30", "America/Los_Angeles"),
    ),
    (
        "spring_forward_berlin_the_night_is_one_hour_shorter",
        view("2026-03-28T23:30", "2026-03-29T05:30", "Europe/Berlin"),
    ),
    (
        "fall_back_berlin_the_night_is_one_hour_longer",
        view("2026-10-24T22:30", "2026-10-25T06:30", "Europe/Berlin"),
    ),
    ("half_hour_zone_kolkata", view("2026-10-01T17:00", "2026-10-02T00:30", "Asia/Kolkata")),
    ("quarter_hour_zone_kathmandu", view("2026-10-01T17:00", "2026-10-02T00:30", "Asia/Kathmandu")),
    (
        "bed_zone_defaults_to_wake_zone",
        view("2026-10-01T20:30", "2026-10-02T04:10", "Asia/Yekaterinburg"),
    ),
    ("leap_day_night", view("2028-02-28T21:00", "2028-02-29T04:00")),
    ("new_year_night", view("2026-12-31T19:00", "2026-12-31T21:00")),
]


def run_duration(given: dict[str, Any]) -> Any:
    found = ref.entry_view(given)
    return {"error": True} if found is None else found


# ------------------------------------------------------------------ averages.json

AVERAGES: list[Case] = [
    ("no_entries", {"entries": [], "through": "2026-10-07", "days": 7}),
    (
        "one_entry",
        {"entries": [night("2026-10-05", 450)], "through": "2026-10-07", "days": 7},
    ),
    (
        "missing_days_are_skipped_not_zeros",
        {
            "entries": [
                night("2026-10-01", 480),
                night("2026-10-03", 360),
                night("2026-10-07", 420),
            ],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "average_is_floored",
        {
            "entries": [night("2026-10-06", 421), night("2026-10-07", 420)],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "full_week",
        {
            "entries": [
                night(f"2026-10-{d:02d}", m)
                for d, m in zip(range(1, 8), (400, 410, 420, 430, 440, 450, 460), strict=True)
            ],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "the_window_includes_both_ends",
        {
            "entries": [night("2026-10-01", 300), night("2026-10-07", 500)],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "older_than_the_window_is_left_out",
        {
            "entries": [night("2026-09-30", 100), night("2026-10-07", 500)],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "after_through_is_left_out",
        {
            "entries": [night("2026-10-08", 100), night("2026-10-07", 500)],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "thirty_days_wider_than_seven",
        {
            "entries": [
                night("2026-09-10", 300),
                night("2026-09-20", 360),
                night("2026-10-07", 480),
            ],
            "through": "2026-10-07",
            "days": 30,
        },
    ),
    (
        "seven_days_of_the_same_data_drop_the_old_ones",
        {
            "entries": [
                night("2026-09-10", 300),
                night("2026-09-20", 360),
                night("2026-10-07", 480),
            ],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "one_day_window",
        {
            "entries": [night("2026-10-06", 300), night("2026-10-07", 480)],
            "through": "2026-10-07",
            "days": 1,
        },
    ),
    (
        "window_over_the_new_year",
        {
            "entries": [night("2026-12-30", 420), night("2027-01-02", 360)],
            "through": "2027-01-03",
            "days": 7,
        },
    ),
    (
        "window_over_a_leap_day",
        {
            "entries": [
                night("2028-02-28", 400),
                night("2028-02-29", 440),
                night("2028-03-01", 480),
            ],
            "through": "2028-03-01",
            "days": 7,
        },
    ),
    (
        "an_invalid_row_is_skipped",
        {
            "entries": [
                {
                    **night("2026-10-06", 420),
                    "wake_at": "2026-10-05T20:00:00Z",
                },  # wakes before bedtime
                night("2026-10-07", 480),
            ],
            "through": "2026-10-07",
            "days": 7,
        },
    ),
    (
        "dst_night_counts_real_minutes",
        {
            "entries": [
                night("2026-03-29", 360, wake_utc="05:30", tz="Europe/Berlin"),
                night("2026-03-28", 480, wake_utc="06:00", tz="Europe/Berlin"),
            ],
            "through": "2026-03-29",
            "days": 7,
        },
    ),
]


def run_average(given: dict[str, Any]) -> Any:
    return ref.average_sleep(given["entries"], given["through"], given["days"])


# ------------------------------------------------------------------ link.json

THU = "2026-10-01"
LINK_DAYS = [f"2026-10-{d:02d}" for d in range(1, 8)]


def week(minutes: list[int | None]) -> list[dict[str, Any]]:
    return [night(d, m) for d, m in zip(LINK_DAYS, minutes, strict=True) if m is not None]


def day_tasks(day: str, done: int, total: int, prefix: str | None = None) -> list[dict[str, Any]]:
    stem = prefix or day
    return [task(f"{stem}-{i}", day, "done" if i < done else "todo") for i in range(total)]


LINK: list[Case] = [
    ("nothing_at_all", {"entries": [], "tasks": [], "through": "2026-10-07"}),
    (
        "short_nights_finish_less",
        {
            "entries": week([300, 330, 480, 450, 470, 440, 500]),
            "tasks": [
                *day_tasks(LINK_DAYS[0], 1, 4),
                *day_tasks(LINK_DAYS[1], 1, 2),
                *day_tasks(LINK_DAYS[2], 3, 4),
                *day_tasks(LINK_DAYS[3], 2, 2),
                *day_tasks(LINK_DAYS[4], 4, 5),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "threshold_is_exactly_six_hours",
        {
            "entries": week([359, 360, None, None, None, None, None]),
            "tasks": [*day_tasks(LINK_DAYS[0], 0, 2), *day_tasks(LINK_DAYS[1], 2, 2)],
            "through": "2026-10-07",
        },
    ),
    (
        "shares_are_floored_basis_points",
        {
            "entries": week([300, 300, 420, 420, None, None, None]),
            "tasks": [
                *day_tasks(LINK_DAYS[0], 1, 3),
                *day_tasks(LINK_DAYS[1], 0, 3),
                *day_tasks(LINK_DAYS[2], 2, 3),
                *day_tasks(LINK_DAYS[3], 2, 3),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "one_group_only_gives_no_difference",
        {
            "entries": week([480, 470, 460, None, None, None, None]),
            "tasks": [*day_tasks(LINK_DAYS[0], 1, 2), *day_tasks(LINK_DAYS[1], 2, 2)],
            "through": "2026-10-07",
        },
    ),
    (
        "days_without_tasks_take_no_part",
        {
            "entries": week([300, 300, 480, 480, 480, None, None]),
            "tasks": [*day_tasks(LINK_DAYS[0], 1, 2), *day_tasks(LINK_DAYS[2], 2, 2)],
            "through": "2026-10-07",
        },
    ),
    (
        "days_with_tasks_but_without_sleep_are_counted_aside",
        {
            "entries": week([300, None, 480, None, None, None, None]),
            "tasks": [
                *day_tasks(LINK_DAYS[0], 1, 2),
                *day_tasks(LINK_DAYS[1], 1, 2),
                *day_tasks(LINK_DAYS[2], 2, 2),
                *day_tasks(LINK_DAYS[3], 0, 1),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "cancelled_and_recurring_tasks_do_not_count",
        {
            "entries": week([300, 480, None, None, None, None, None]),
            "tasks": [
                task("a", LINK_DAYS[0], "done"),
                task("b", LINK_DAYS[0], "cancelled"),
                task("c", LINK_DAYS[0], "todo", rrule="FREQ=DAILY"),
                task("d", LINK_DAYS[1], "in_progress"),
                task("e", LINK_DAYS[1], "done", rrule="FREQ=WEEKLY"),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "inbox_and_in_progress_count_as_not_done",
        {
            "entries": week([300, None, None, None, None, None, None]),
            "tasks": [
                task("a", LINK_DAYS[0], "inbox"),
                task("b", LINK_DAYS[0], "in_progress"),
                task("c", LINK_DAYS[0], "done"),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "a_timed_task_belongs_to_its_local_date",
        {
            "entries": week([300, 480, None, None, None, None, None]),
            "tasks": [
                task("late", None, "done", due_at="2026-10-01T22:30", due_tz=MSK),
                task("early", None, "todo", due_at="2026-10-01T22:30", due_tz="America/New_York"),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "tasks_outside_the_week_are_left_out",
        {
            "entries": week([300, 480, None, None, None, None, None]),
            "tasks": [
                *day_tasks("2026-09-30", 1, 1, "old"),
                *day_tasks("2026-10-08", 1, 1, "new"),
                *day_tasks(LINK_DAYS[0], 1, 1),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "tasks_without_a_date_are_left_out",
        {
            "entries": week([300, None, None, None, None, None, None]),
            "tasks": [task("x", None, "done"), task("y", LINK_DAYS[0], "done")],
            "through": "2026-10-07",
        },
    ),
    (
        "enough_data_needs_two_days_in_each_group",
        {
            "entries": week([300, 310, 480, 490, None, None, None]),
            "tasks": [
                *day_tasks(LINK_DAYS[0], 0, 1),
                *day_tasks(LINK_DAYS[1], 1, 1),
                *day_tasks(LINK_DAYS[2], 1, 1),
                *day_tasks(LINK_DAYS[3], 1, 1),
            ],
            "through": "2026-10-07",
        },
    ),
    (
        "normal_nights_finish_less_gives_a_negative_difference",
        {
            "entries": week([300, 300, 480, 480, None, None, None]),
            "tasks": [
                *day_tasks(LINK_DAYS[0], 2, 2),
                *day_tasks(LINK_DAYS[1], 2, 2),
                *day_tasks(LINK_DAYS[2], 0, 2),
                *day_tasks(LINK_DAYS[3], 1, 2),
            ],
            "through": "2026-10-07",
        },
    ),
]


def run_link(given: dict[str, Any]) -> Any:
    return ref.sleep_task_link(given["entries"], given["tasks"], given["through"])


# ------------------------------------------------------------------ streaks.json


def days(*numbers: int, month: str = "2026-10") -> list[str]:
    return [f"{month}-{n:02d}" for n in numbers]


STREAKS: list[Case] = [
    ("no_rituals_yet", {"morning": [], "evening": [], "through": "2026-10-07"}),
    ("only_today", {"morning": days(7), "evening": [], "through": "2026-10-07"}),
    (
        "today_not_done_yet_keeps_the_streak_alive",
        {"morning": days(4, 5, 6), "evening": days(4, 5, 6), "through": "2026-10-07"},
    ),
    (
        "a_missed_yesterday_breaks_it",
        {"morning": days(3, 4, 5), "evening": days(3, 4, 5), "through": "2026-10-07"},
    ),
    (
        "best_is_longer_than_current",
        {
            "morning": days(1, 2, 3, 4, 5, 7),
            "evening": days(1, 2, 3, 4, 5, 6, 7),
            "through": "2026-10-07",
        },
    ),
    (
        "dates_after_through_are_ignored",
        {"morning": days(5, 6, 7, 8, 9), "evening": days(8, 9), "through": "2026-10-06"},
    ),
    (
        "duplicates_count_once",
        {"morning": days(5, 5, 6, 6, 7), "evening": days(7, 7), "through": "2026-10-07"},
    ),
    (
        "both_is_the_intersection",
        {
            "morning": days(1, 2, 3, 5, 6, 7),
            "evening": days(2, 3, 4, 6, 7),
            "through": "2026-10-07",
        },
    ),
    (
        "streak_over_a_month_boundary",
        {
            "morning": ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"],
            "evening": ["2026-09-30", "2026-10-01", "2026-10-02"],
            "through": "2026-10-02",
        },
    ),
    (
        "streak_over_a_leap_day",
        {
            "morning": ["2028-02-28", "2028-02-29", "2028-03-01"],
            "evening": ["2028-02-29", "2028-03-01"],
            "through": "2028-03-01",
        },
    ),
    (
        "streak_over_the_new_year",
        {
            "morning": ["2026-12-30", "2026-12-31", "2027-01-01"],
            "evening": ["2026-12-31", "2027-01-01"],
            "through": "2027-01-01",
        },
    ),
    (
        "garbage_dates_are_ignored",
        {
            "morning": ["nope", "2026-13-01", "2026-10-07", "2026-10-06"],
            "evening": [""],
            "through": "2026-10-07",
        },
    ),
    (
        "old_streak_is_best_but_not_current",
        {"morning": days(1, 2, 3, 4), "evening": days(1, 2), "through": "2026-10-20"},
    ),
]


def run_streaks(given: dict[str, Any]) -> Any:
    return ref.ritual_streaks(given["morning"], given["evening"], given["through"])


# ------------------------------------------------------------------ carry_over.json


def tomorrow(tid: str) -> dict[str, Any]:
    return {"task_id": tid, "to": "tomorrow"}


def on_date(tid: str, date: str) -> dict[str, Any]:
    return {"task_id": tid, "to": "date", "date": date}


CARRY: list[Case] = [
    (
        "dated_task_to_tomorrow",
        {"date": "2026-10-04", "decisions": [tomorrow("a")], "tasks": [task("a", "2026-10-04")]},
    ),
    (
        "dated_task_to_a_date",
        {
            "date": "2026-10-04",
            "decisions": [on_date("a", "2026-10-11")],
            "tasks": [task("a", "2026-10-04")],
        },
    ),
    (
        "task_without_a_date_gets_one",
        {"date": "2026-10-04", "decisions": [tomorrow("a")], "tasks": [task("a", None, "todo")]},
    ),
    (
        "inbox_becomes_todo",
        {"date": "2026-10-04", "decisions": [tomorrow("a")], "tasks": [task("a", None, "inbox")]},
    ),
    (
        "in_progress_stays_in_progress",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", "2026-10-04", "in_progress")],
        },
    ),
    (
        "timed_task_keeps_its_wall_clock_time",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", None, due_at="2026-10-04T15:00", due_tz=MSK)],
        },
    ),
    (
        "timed_task_in_another_zone_keeps_its_local_time",
        {
            "date": "2026-10-04",
            "decisions": [on_date("a", "2026-10-06")],
            "tasks": [task("a", None, due_at="2026-10-04T23:30", due_tz="Asia/Vladivostok")],
        },
    ),
    (
        "timed_task_over_the_utc_date_line",
        {
            "date": "2026-10-03",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", None, due_at="2026-10-04T03:00", due_tz="America/Los_Angeles")],
        },
    ),
    (
        "timed_task_moved_across_the_spring_dst_switch",
        {
            "date": "2026-03-07",
            "decisions": [tomorrow("a"), on_date("b", "2026-03-09")],
            "tasks": [
                task("a", None, due_at="2026-03-07T15:00", due_tz="America/New_York"),
                task("b", None, due_at="2026-03-07T15:00", due_tz="America/New_York"),
            ],
        },
    ),
    (
        "wall_time_inside_the_dst_gap_moves_forward",
        {
            "date": "2026-03-07",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", None, due_at="2026-03-06T07:30", due_tz="America/New_York")],
        },
    ),
    (
        "wall_time_inside_the_dst_overlap_is_the_first_one",
        {
            "date": "2026-10-31",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", None, due_at="2026-10-30T05:30", due_tz="America/New_York")],
        },
    ),
    (
        "month_and_year_boundary",
        {
            "date": "2026-12-31",
            "decisions": [tomorrow("a"), tomorrow("b")],
            "tasks": [
                task("a", "2026-12-31"),
                task("b", None, due_at="2026-12-31T20:59", due_tz=MSK),
            ],
        },
    ),
    (
        "leap_day_is_tomorrow",
        {"date": "2028-02-28", "decisions": [tomorrow("a")], "tasks": [task("a", "2028-02-28")]},
    ),
    (
        "date_not_after_the_checkin_date_is_refused",
        {
            "date": "2026-10-04",
            "decisions": [on_date("a", "2026-10-04"), on_date("b", "2026-10-01")],
            "tasks": [task("a", "2026-10-04"), task("b", "2026-10-04")],
        },
    ),
    (
        "done_and_cancelled_tasks_are_closed",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a"), tomorrow("b")],
            "tasks": [task("a", "2026-10-04", "done"), task("b", "2026-10-04", "cancelled")],
        },
    ),
    (
        "recurring_task_is_not_moved",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a")],
            "tasks": [task("a", "2026-10-04", rrule="FREQ=DAILY")],
        },
    ),
    (
        "unknown_task",
        {"date": "2026-10-04", "decisions": [tomorrow("ghost")], "tasks": []},
    ),
    (
        "same_task_twice",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a"), on_date("a", "2026-10-09")],
            "tasks": [task("a", "2026-10-04")],
        },
    ),
    (
        "already_on_that_date_is_unchanged",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("a"), tomorrow("b")],
            "tasks": [
                task("a", "2026-10-05"),
                task("b", None, due_at="2026-10-05T10:00", due_tz=MSK),
            ],
        },
    ),
    (
        "mixed_batch_keeps_the_order_of_decisions",
        {
            "date": "2026-10-04",
            "decisions": [tomorrow("c"), tomorrow("a"), on_date("b", "2026-10-20")],
            "tasks": [
                task("a", "2026-10-04"),
                task("b", None, "inbox"),
                task("c", "2026-10-04", "done"),
            ],
        },
    ),
    ("no_decisions", {"date": "2026-10-04", "decisions": [], "tasks": [task("a", "2026-10-04")]}),
]


def run_carry(given: dict[str, Any]) -> Any:
    return ref.plan_carry_over(given["date"], given["decisions"], given["tasks"])


FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "duration": (
        "entry_view(row): the length in whole minutes, the date of the sleep and the wall-clock "
        "times of bed and wake; {error: true} for an invalid row",
        DURATION,
        run_duration,
    ),
    "averages": (
        "average_sleep(entries, through, days): the average night, days without an entry skipped",
        AVERAGES,
        run_average,
    ),
    "link": (
        "sleep_task_link(entries, tasks, through): finished-task share after short and normal "
        "nights over the last 7 days",
        LINK,
        run_link,
    ),
    "streaks": (
        "ritual_streaks(morning, evening, through): current and best streak of the morning plan, "
        "the evening check-in and of days with both",
        STREAKS,
        run_streaks,
    ),
    "carry_over": (
        "plan_carry_over(date, decisions, tasks): what the evening check-in changes in tasks",
        CARRY,
        run_carry,
    ),
}


def build() -> dict[str, str]:
    """File name -> exact text of the file."""
    files = {}
    for name, (description, cases, run) in FILES.items():
        names = [case_name for case_name, _ in cases]
        assert len(names) == len(set(names)), f"duplicate case names in {name}"
        document = {
            "description": description,
            "cases": [{"name": n, "input": given, "expected": run(given)} for n, given in cases],
        }
        files[f"{name}.json"] = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    return files


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for file_name, text in build().items():
        (OUT / file_name).write_text(text, encoding="utf-8")
    print(f"wrote {len(FILES)} files to {OUT}")  # noqa: T201


if __name__ == "__main__":
    main()
