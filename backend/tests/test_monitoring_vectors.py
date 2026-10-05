"""Shared Monitoring vectors: every case of every file must pass (the Dart side does the same for
``targets`` and ``availability``; ``alerts`` and ``quiet`` document the server rules)."""

from typing import Any

import pytest

from tests import monitoring_vectors_gen as gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = tuple(gen.FILES)


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("monitoring", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    assert gen.FILES[file][2](case["input"]) == case["expected"]


def test_enough_cases_and_unique_names() -> None:
    for name in FILES:
        names = [case["name"] for case in load_cases("monitoring", name)]
        assert len(names) == len(set(names))
    assert len(load_cases("monitoring", "alerts")) >= 30
    assert len(load_cases("monitoring", "targets")) >= 60
    assert len(load_cases("monitoring", "quiet")) >= 10
    assert len(load_cases("monitoring", "availability")) >= 10


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in gen.build().items():
        assert (VECTORS_DIR / "monitoring" / file_name).read_text(encoding="utf-8") == text


def test_the_required_alert_situations_are_covered() -> None:
    names = {c["name"] for c in load_cases("monitoring", "alerts")}
    assert {
        "fall_alert_once_then_recovery",
        "flapping_one_message_then_silence_then_stable",
        "outages_far_apart_are_separate_incidents",
        "two_services_down_together_make_one_group_message",
        "three_services_down_together_suspect_the_monitor",
        "quiet_hours_hold_the_alert_of_a_normal_service",
    } <= names


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
        for case in load_cases("monitoring", name):
            walk(case["input"])
            walk(case["expected"])


def test_every_alert_vector_sends_each_kind_at_most_once_per_incident() -> None:
    """The headline rule, checked on the recorded expectations themselves."""
    for case in load_cases("monitoring", "alerts"):
        seen: set[tuple[str, str]] = set()
        for cycle in case["expected"]["cycles"]:
            for message in cycle["messages"]:
                if message["kind"] in ("down", "down_group", "recovered", "recovered_group"):
                    for ref in message["refs"]:
                        key = (message["kind"].removesuffix("_group"), ref)
                        assert key not in seen, (case["name"], key)
                        seen.add(key)
