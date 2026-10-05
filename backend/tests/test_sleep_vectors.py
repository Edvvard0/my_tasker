"""Shared Sleep vectors: every case of every file must pass (the Dart side does the same)."""

from typing import Any

import pytest

from tests import sleep_vectors_gen as gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = tuple(gen.FILES)


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("sleep", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    assert gen.FILES[file][2](case["input"]) == case["expected"]


def test_at_least_40_cases_and_unique_names() -> None:
    total = 0
    for name in FILES:
        names = [case["name"] for case in load_cases("sleep", name)]
        assert len(names) == len(set(names))
        total += len(names)
    assert total >= 40


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in gen.build().items():
        assert (VECTORS_DIR / "sleep" / file_name).read_text(encoding="utf-8") == text, file_name


def test_the_required_situations_are_covered() -> None:
    durations = {c["name"] for c in load_cases("sleep", "duration")}
    assert {
        "night_over_midnight",
        "flight_east_moscow_to_vladivostok",
        "spring_forward_berlin_the_night_is_one_hour_shorter",
    } <= durations
    averages = {c["name"] for c in load_cases("sleep", "averages")}
    assert "missing_days_are_skipped_not_zeros" in averages
    carry = {c["name"] for c in load_cases("sleep", "carry_over")}
    assert {"dated_task_to_tomorrow", "dated_task_to_a_date"} <= carry


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
        for case in load_cases("sleep", name):
            walk(case["input"])
            walk(case["expected"])
