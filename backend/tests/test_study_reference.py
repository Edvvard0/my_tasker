"""Units of the Study reference rules beyond the shared vectors."""

from typing import Any

import pytest
from hypothesis import given
from hypothesis import strategies as st

from tasker.study import reference as ref
from tests.study_vectors_gen import (
    OVERLAP_SEMESTERS,
    att,
    base,
    override,
    scene,
    slot,
    subject,
)

ROOM = st.from_regex(r"[0-9]{1,3}[а-я]?", fullmatch=True)


@given(st.integers(1, 99), ROOM)
def test_a_formatted_room_parses_back(building: int, room: str) -> None:
    text = ref.format_room(str(building), room)
    assert ref.parse_room(text) == {"building": str(building), "room": room}


@given(st.text(max_size=30))
def test_parse_room_never_fails(text: str) -> None:
    found = ref.parse_room(text)
    assert found is None or found["room"]


def test_attendance_state_boundaries() -> None:
    assert ref.attendance_state(0, None) == "no_limit"
    assert ref.attendance_state(99, None) == "no_limit"
    # limit 4: 3 of 4 is the first "near"; 4 is "reached"; 5 is "over"
    assert [ref.attendance_state(n, 4) for n in range(6)] == [
        "ok",
        "ok",
        "ok",
        "near",
        "reached",
        "over",
    ]
    assert [ref.attendance_state(n, 1) for n in range(3)] == ["ok", "reached", "over"]
    assert ref.attendance_state(7, 10) == "ok"
    assert ref.attendance_state(8, 10) == "near"  # 8/10 >= 3/4


def test_minutes_round_trip() -> None:
    for text in ("00:00", "08:30", "23:59"):
        assert ref.from_minutes(ref.to_minutes(text)) == text


def test_semester_for_prefers_the_latest_start_and_skips_archived() -> None:
    a = {"id": "a", "start_date": "2026-09-01", "end_date": "2026-12-31", "archived": False}
    b = {"id": "b", "start_date": "2026-10-01", "end_date": "2026-12-31", "archived": False}
    c = {"id": "c", "start_date": "2026-10-01", "end_date": "2026-12-31", "archived": False}
    assert ref.semester_for("2026-09-15", [a, b]) == a
    assert ref.semester_for("2026-10-15", [a, b]) == b
    assert ref.semester_for("2026-10-15", [b, c]) == c  # the larger id breaks a tie
    assert ref.semester_for("2026-10-15", [{**b, "archived": True}, a]) == a
    assert ref.semester_for("2027-06-01", [a, b]) is None


def test_expand_range_is_expand_day_for_every_date() -> None:
    given_ = scene([])
    args: tuple[Any, ...] = (
        given_["semesters"],
        given_["subjects"],
        given_["bells"],
        given_["slots"],
        given_["day_rules"],
        given_["overrides"],
        {},
    )
    days = ref.expand_range("2026-09-07", "2026-09-13", *args)
    assert [d["date"] for d in days] == [f"2026-09-{n:02d}" for n in range(7, 14)]
    assert days[0] == ref.expand_day("2026-09-07", *args)
    assert ref.expand_range("2026-09-13", "2026-09-07", *args) == []


def test_two_overrides_for_one_lesson_resolve_by_the_larger_id() -> None:
    data = base()
    first = {
        "id": "o-1",
        "slot_id": "s-mon-1",
        "date": "2026-09-07",
        "action": "cancel",
        "new_date": None,
        "start_time": None,
        "end_time": None,
        "building": None,
        "room": None,
        "subject_id": None,
        "title": None,
        "lesson_kind": None,
    }
    second = {**first, "id": "o-2", "action": "change", "room": "9"}
    args = (data["semesters"], data["subjects"], data["bells"], data["slots"], data["day_rules"])
    for order in ([first, second], [second, first]):
        day = ref.expand_day("2026-09-07", *args, order, {})
        (lesson,) = day["lessons"]
        assert (lesson["cancelled"], lesson["room"]) == (False, "9")


@pytest.mark.parametrize("first_start", ["8:30", "24:00", "", "08:60"])
def test_generate_bells_rejects_bad_start_times(first_start: str) -> None:
    assert ref.generate_bells(first_start, 90, 10, 2) is None


def test_week_number_with_a_shift_object() -> None:
    semester = {
        "week1_start": "2026-08-31",
        "cycle_length": 2,
        "week_shifts": [{"from": "2026-10-05", "weeks": 1}],
    }
    assert [ref.week_number(d, semester) for d in ("2026-10-04", "2026-10-05")] == [1, 1]
    assert ref.week_number("2026-10-12", {**semester, "week_shifts": None}) == 1


def test_a_lesson_without_a_number_or_time_has_no_time() -> None:
    """The validators forbid it, but a row that slipped through must not break the expansion."""
    data = base()
    odd = {**data["slots"][0], "id": "s-odd", "number": None}
    day = ref.expand_day(
        "2026-09-07",
        data["semesters"],
        data["subjects"],
        data["bells"],
        [odd],
        [],
        [],
        {},
    )
    (lesson,) = day["lessons"]
    assert (lesson["start"], lesson["end"], lesson["number"]) == (None, None, None)


def test_archived_semesters_do_not_count_in_attendance() -> None:
    data = base()
    archived = {**data["semesters"][0], "archived": True}
    summary = ref.attendance_summary(
        "2026-12-31",
        [archived],
        data["subjects"],
        data["bells"],
        data["slots"],
        data["day_rules"],
        [],
        {},
        [],
    )
    assert all(row["unmarked"] == 0 for row in summary)


def _expand(data: dict[str, Any], day: str) -> dict[str, Any]:
    day_ = ref.expand_day(
        day,
        data["semesters"],
        data["subjects"],
        data["bells"],
        data["slots"],
        data["day_rules"],
        data["overrides"],
        data["holidays"],
    )
    assert isinstance(day_, dict)
    return day_


@pytest.mark.parametrize(
    ("slot_id", "original"),
    [
        ("s-mon-2", "2026-09-07"),  # a lab of odd weeks, asked for on an even Monday
        ("s-wed-1", "2026-09-08"),  # a Wednesday lesson, asked for on a Tuesday
        ("s-wed-1", "2026-08-26"),  # before the semester
        ("s-wed-1", "2027-01-06"),  # after the semester
    ],
)
def test_a_move_of_a_lesson_that_does_not_occur_never_shows_up(slot_id: str, original: str) -> None:
    data = scene([])
    data["overrides"] = [override("o-1", slot_id, original, "move", new_date="2026-09-11")]
    friday = _expand(data, "2026-09-11")
    assert [lesson["key"] for lesson in friday["lessons"]] == ["slot:s-fri-x@2026-09-11"]
    assert all(lesson["moved_from"] is None for lesson in _expand(data, original)["lessons"])


def test_a_real_move_still_arrives() -> None:
    data = scene([])
    data["overrides"] = [override("o-1", "s-wed-1", "2026-09-09", "move", new_date="2026-09-11")]
    keys = [(x["key"], x["moved_from"]) for x in _expand(data, "2026-09-11")["lessons"]]
    assert ("slot:s-wed-1@2026-09-09", "2026-09-09") in keys
    assert _expand(data, "2026-09-09")["lessons"][0]["moved_to"] == "2026-09-11"


def test_a_move_out_of_the_semester_leaves_the_lesson_where_it_is() -> None:
    data = scene([])
    data["overrides"] = [override("o-1", "s-wed-1", "2026-12-30", "move", new_date="2027-01-02")]
    (lesson,) = _expand(data, "2026-12-30")["lessons"]
    assert (lesson["moved_to"], lesson["trackable"], lesson["override_id"]) == (None, True, None)
    assert _expand(data, "2027-01-02")["lessons"] == []


def test_overlapping_semesters_are_counted_once() -> None:
    data = scene([])
    data["semesters"] = OVERLAP_SEMESTERS
    data["subjects"] = [
        *data["subjects"],
        {**subject("hist", "История", None, None), "semester_id": "sem2"},
    ]
    data["slots"] = [*data["slots"], {**slot("s-new", 1, 1, "hist"), "semester_id": "sem2"}]
    args = (
        data["semesters"],
        data["subjects"],
        data["bells"],
        data["slots"],
        data["day_rules"],
        data["overrides"],
        data["holidays"],
    )
    through = "2026-10-12"
    summary = {c["subject_id"]: c for c in ref.attendance_summary(through, *args, [])}
    # Mondays 5 and 12 October and Wednesdays 7 and 14 October belong to the later semester
    assert (summary["math"]["unmarked"], summary["hist"]["unmarked"]) == (9, 2)
    marked = ref.attendance_summary(
        through,
        *args,
        [att("s-mon-1", "2026-10-05", "absent"), att("s-new", "2026-10-05", "absent")],
    )
    assert [(c["subject_id"], c["absent"]) for c in marked if c["absent"]] == [("hist", 1)]
