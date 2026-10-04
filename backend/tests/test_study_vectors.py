"""Shared Study vectors: every case of every file must pass (the Dart side does the same)."""

from datetime import date, timedelta
from typing import Any

import pytest

from tasker.datafiles import load_json
from tasker.study import reference as ref
from tests import study_vectors_gen as gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = tuple(gen.FILES)


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("study", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    assert gen.FILES[file][2](case["input"]) == case["expected"]


def test_at_least_60_cases_and_unique_names() -> None:
    total = 0
    for name in FILES:
        names = [case["name"] for case in load_cases("study", name)]
        assert len(names) == len(set(names))
        total += len(names)
    assert total >= 60


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in gen.build().items():
        assert (VECTORS_DIR / "study" / file_name).read_text(encoding="utf-8") == text, file_name


def test_the_required_situations_are_covered() -> None:
    names = {case["name"] for case in load_cases("study", "expand")}
    assert {
        "thursday_is_olympiad_preparation",
        "cancelled_lesson_stays_in_the_list_marked_cancelled",
        "move_to_another_date_with_its_own_time",
        "bells_changed_for_all_lessons",
        "bells_changed_for_one_date_only",
        "monday_of_an_odd_week_has_the_lecture_and_the_lab",
        "monday_of_an_even_week_has_no_lab",
        "holiday_removes_the_lessons",
        "a_rule_for_the_date_beats_the_weekday_rule",
    } <= names
    rooms = {case["name"] for case in load_cases("study", "rooms")}
    assert "parse_k1_28" in rooms


def test_no_vector_contains_a_float() -> None:
    def walk(value: Any) -> None:
        assert not isinstance(value, float)
        if isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    for name in FILES:
        for case in load_cases("study", name):
            walk(case["input"])
            walk(case["expected"])


def test_the_thursday_of_the_customer_by_hand() -> None:
    """No regular classes on Thursday: three olympiad-preparation lessons by the bells of 1-3."""
    case = {c["name"]: c for c in load_cases("study", "expand")}["thursday_is_olympiad_preparation"]
    for day in case["expected"]:
        assert day["weekday"] == 4
        assert day["day"] == {
            "kind": "special",
            "name": "Подготовка к олимпиаде",
            "rule_id": "r-thu",
        }
        assert [(x["number"], x["start"], x["end"]) for x in day["lessons"]] == [
            (1, "08:30", "10:00"),
            (2, "10:10", "11:40"),
            (3, "12:10", "13:40"),
        ]
        assert {x["source"] for x in day["lessons"]} == {"rule"}
        assert not any(x["trackable"] for x in day["lessons"])


def test_the_input_is_not_changed_by_the_expansion() -> None:
    for case in load_cases("study", "expand"):
        given = case["input"]
        before = repr(given)
        assert gen.run_expand(given) == case["expected"]
        assert repr(given) == before


def test_holidays_come_from_the_stage_2_file() -> None:
    data = load_json("calendar/holidays_ru.json")
    found = ref.holidays_between(data, "2026-01-01", "2026-12-31")
    assert "2026-01-01" in found
    assert "2026-11-04" in found  # Unity Day
    # plain weekends are teaching days, transferred working weekends do not change that
    assert "2026-09-05" not in found
    wd = [e["date"] for e in data["years"]["2026"]["days"] if e["type"] == "working_weekend"]
    assert all(day not in found for day in wd)
    assert ref.holidays_between(data, "2026-02-01", "2026-02-10").keys() <= found.keys()
    assert ref.holidays_between(data, "2999-01-01", "2999-01-31") == {}
    assert ref.holidays_between(data, "2026-12-30", "2027-01-02") != {}


def test_real_holidays_feed_the_expansion() -> None:
    data = load_json("calendar/holidays_ru.json")
    holidays = ref.holidays_between(data, "2026-11-01", "2026-11-07")
    given = gen.scene(["2026-11-04"], holidays=holidays)
    (day,) = gen.run_expand(given)
    assert day["day"]["kind"] == "holiday"
    assert day["lessons"] == []


def test_every_date_of_the_semester_expands_without_error() -> None:
    given = gen.scene([])
    first = date(2026, 8, 25)
    for offset in range(0, 140):
        day = (first + timedelta(days=offset)).isoformat()
        result = ref.expand_day(
            day,
            given["semesters"],
            given["subjects"],
            given["bells"],
            given["slots"],
            given["day_rules"],
            given["overrides"],
            {},
        )
        assert result["date"] == day
        orders = [ref._order(x) for x in result["lessons"]]
        assert orders == sorted(orders)
