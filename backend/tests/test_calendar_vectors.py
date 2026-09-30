"""Shared calendar vectors: every case of every file must pass (the Dart side does the same)."""

import uuid
from datetime import date, datetime
from typing import Any

import pytest

from tasker.calendar import ids
from tasker.calendar.holidays import day_info, load
from tasker.calendar.reference_expand import expand
from tasker.calendar.reference_quick_input import parse_quick_input
from tasker.calendar.rrule_subset import rrule_problem
from tasker.calendar.week_cycle import Cycle, cycle_week, first_date, monday_of
from tests import calendar_vectors_gen
from tests.vectors import VECTORS_DIR, load_cases


def _cases(name: str) -> list[Any]:
    return [pytest.param(case, id=case["name"]) for case in load_cases("calendar", name)]


@pytest.mark.parametrize("case", _cases("quick_input"))
def test_quick_input(case: dict[str, Any]) -> None:
    given = case["input"]
    parsed = parse_quick_input(given["text"], datetime.fromisoformat(given["now"]))
    assert parsed.as_json() == case["expected"]


def test_quick_input_has_at_least_100_cases() -> None:
    assert len(load_cases("calendar", "quick_input")) >= 100


@pytest.mark.parametrize("case", _cases("rrule_expand"))
def test_rrule_expand(case: dict[str, Any]) -> None:
    assert expand(case["input"]) == case["expected"]


@pytest.mark.parametrize("case", _cases("rrule_validate"))
def test_rrule_validate(case: dict[str, Any]) -> None:
    given = case["input"]
    problem = rrule_problem(given["rrule"], all_day=given["all_day"])
    assert (problem is None) == case["expected"]["valid"], problem


@pytest.mark.parametrize("case", _cases("week_cycle"))
def test_week_cycle(case: dict[str, Any]) -> None:
    given = case["input"]
    cycle = Cycle(
        date.fromisoformat(given["week1_start"]),
        given["length"],
        tuple((date.fromisoformat(s["from"]), s["weeks"]) for s in given.get("shifts", [])),
    )
    if given["op"] == "week_number":
        day = date.fromisoformat(given["date"])
        assert case["expected"] == {
            "monday": monday_of(day).isoformat(),
            "week_number": cycle_week(day, cycle.week1_start, cycle.length, cycle.shifts),
        }
    else:
        found = first_date(
            date.fromisoformat(given["after"]), given["weekday"], given["week"], cycle
        )
        assert found.isoformat() == case["expected"]


@pytest.mark.parametrize("case", _cases("holidays"))
def test_holidays(case: dict[str, Any]) -> None:
    info = day_info(load(), date.fromisoformat(case["input"]))
    assert {"is_day_off": info.is_day_off, "name": info.name} == case["expected"]


_IDS = {
    "system_calendar": lambda i: ids.system_calendar_id(i["system_key"]),
    "tag": lambda i: ids.tag_id(i["name"]),
    "event_override": lambda i: ids.override_id(i["event_id"], i["original_start"]),
    "task_completion": lambda i: ids.completion_id(i["task_id"], i["instance_date"]),
    "task_tag": lambda i: ids.task_tag_id(i["task_id"], i["tag_id"]),
}


@pytest.mark.parametrize("case", _cases("ids"))
def test_ids(case: dict[str, Any]) -> None:
    given = case["input"]
    assert str(_IDS[given["kind"]](given)) == case["expected"]
    assert uuid.UUID(case["expected"]).version == 5


def test_vector_files_are_what_the_generator_produces() -> None:
    """The files on disk are exactly the reference output for the inputs in the generator."""
    for name, text in calendar_vectors_gen.generate().items():
        path = VECTORS_DIR / "calendar" / f"{name}.json"
        assert path.read_text(encoding="utf-8") == text, f"{path.name} is stale"


def test_vector_files_escape_exotic_spaces() -> None:
    text = (VECTORS_DIR / "calendar" / "quick_input.json").read_text(encoding="utf-8")
    for char in (" ", " ", " "):
        assert char not in text
    assert "\\u00a0" in text
