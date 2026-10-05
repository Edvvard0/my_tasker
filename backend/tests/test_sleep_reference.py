"""Units and properties of the Sleep reference rules beyond the shared vectors."""

from datetime import date, timedelta

import pytest
from hypothesis import given
from hypothesis import strategies as st

from tasker.sleep import reference as ref
from tests.sleep_vectors_gen import night, task

DAY = st.dates(min_value=date(2020, 1, 1), max_value=date(2030, 12, 31))


@given(st.integers(1, 1440))
def test_a_night_of_n_minutes_lasts_n_minutes(minutes: int) -> None:
    row = night("2026-10-05", minutes)
    assert ref.duration_minutes(row["bed_at"], row["wake_at"]) == minutes


@given(st.lists(st.tuples(DAY, st.integers(1, 1440)), max_size=40, unique_by=lambda x: x[0]), DAY)
def test_the_average_lies_between_the_shortest_and_the_longest_night(
    nights: list[tuple[date, int]], through: date
) -> None:
    entries = [night(d.isoformat(), m) for d, m in nights]
    result = ref.average_sleep(entries, through.isoformat(), 30)
    inside = [m for d, m in nights if through - timedelta(days=29) <= d <= through]
    assert result["days_with_data"] == len(inside)
    if inside:
        assert min(inside) <= result["average_minutes"] <= max(inside)
    else:
        assert result["average_minutes"] is None


@given(st.sets(DAY, max_size=60), DAY)
def test_streak_invariants(dates: set[date], through: date) -> None:
    result = ref.streak([d.isoformat() for d in dates], through.isoformat())
    assert 0 <= result["current"] <= result["best"] <= len(dates)
    up_to = [d for d in dates if d <= through]
    assert (result["last"] is None) == (not up_to)
    if result["current"]:
        # a living streak ends today or yesterday and every day of it is done
        end = through if through in dates else through - timedelta(days=1)
        assert all(end - timedelta(days=i) in dates for i in range(result["current"]))
        assert end - timedelta(days=result["current"]) not in dates


@given(st.sets(DAY, max_size=30), st.sets(DAY, max_size=30), DAY)
def test_the_joint_streak_never_beats_either_one(a: set[date], b: set[date], through: date) -> None:
    both = ref.ritual_streaks(
        [d.isoformat() for d in a], [d.isoformat() for d in b], through.isoformat()
    )
    assert both["both"]["current"] <= min(both["morning"]["current"], both["evening"]["current"])
    assert both["both"]["best"] <= min(both["morning"]["best"], both["evening"]["best"])


@given(st.dates(min_value=date(2021, 1, 1), max_value=date(2029, 12, 31)), st.integers(1, 400))
def test_carry_over_to_a_date_sets_exactly_that_date(day: date, ahead: int) -> None:
    target = day + timedelta(days=ahead)
    plan = ref.plan_carry_over(
        day.isoformat(),
        [{"task_id": "a", "to": "date", "date": target.isoformat()}],
        [task("a", day.isoformat())],
    )
    assert plan == [
        {"task_id": "a", "action": "set_due_date", "due_date": target.isoformat(), "status": None}
    ]


@given(st.dates(min_value=date(2021, 1, 1), max_value=date(2029, 12, 31)), st.integers(0, 23))
def test_a_timed_task_keeps_its_local_time_in_a_zone_without_gaps(day: date, hour: int) -> None:
    due = f"{day.isoformat()}T{hour:02d}:00:00Z"
    local_day = ref.task_day({"due_at": due, "due_tz": "Asia/Kolkata"})
    assert local_day is not None
    (change,) = ref.plan_carry_over(
        local_day,
        [{"task_id": "a", "to": "tomorrow"}],
        [task("a", None, due_at=due, due_tz="Asia/Kolkata")],
    )
    # a fixed offset: tomorrow at the same wall-clock time is exactly 24 hours later
    expected = (day + timedelta(days=1)).isoformat() + due[10:]
    assert change["action"] == "set_due_at"
    assert change["due_at"] == expected


def test_window_rejects_nonsense() -> None:
    with pytest.raises(ValueError, match="window"):
        ref.window("2026-13-01", 7)
    with pytest.raises(ValueError, match="window"):
        ref.window("2026-10-01", 0)
    with pytest.raises(ValueError, match="through"):
        ref.streak([], "nope")
    with pytest.raises(ValueError, match="checkin_date"):
        ref.plan_carry_over("nope", [], [])


def test_helpers_survive_malformed_input() -> None:
    assert ref.sleep_date("nope", "Europe/Moscow") is None
    assert ref.local_clock("nope", "Europe/Moscow") is None
    assert ref.entry_view({"bed_at": "x", "wake_at": "y", "wake_tz": "Europe/Moscow"}) is None
    assert ref.task_day({"due_at": "garbage", "due_tz": "Europe/Moscow"}) is None
    assert ref.task_day({}) is None
    assert ref.task_day({"due_at": "2026-10-01T10:00:00Z"}) is None  # no zone: not a local date


def test_the_highest_id_wins_when_a_date_has_two_rows() -> None:
    a = {**night("2026-10-05", 400), "id": "a"}
    b = {**night("2026-10-05", 500), "id": "b"}
    assert ref.average_sleep([b, a], "2026-10-07", 7)["total_minutes"] == 500
