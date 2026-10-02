"""Shared Work vectors: every case of every file must pass (the Dart side does the same)."""

from typing import Any

import pytest

from tasker.work import reference as ref
from tests import work_vectors_gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = ("scalars", "project_summary", "receivables", "income", "monthly", "integrity")


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("work", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    given = case["input"]
    if file == "scalars":
        got = work_vectors_gen.run_scalar(given)
    elif file == "project_summary":
        got = ref.project_summary(given["project"], given["change_requests"], given["allocations"])
    elif file == "receivables":
        got = ref.receivables(given["projects"], given["change_requests"], given["allocations"])
    elif file == "income":
        got = ref.income(
            given["projects"],
            given["change_requests"],
            given["payments"],
            given["allocations"],
            given["time_entries"],
            given["period"],
            given["project_id"],
        )
    elif file == "monthly":
        got = ref.monthly_received(given["payments"], given["allocations"], given["project_id"])
    else:
        got = ref.integrity_problems(
            given["change_requests"], given["payments"], given["allocations"]
        )
    assert got == case["expected"]


def test_at_least_60_cases_and_unique_names() -> None:
    total = 0
    for name in FILES:
        names = [case["name"] for case in load_cases("work", name)]
        assert len(names) == len(set(names))
        total += len(names)
    assert total >= 60


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in work_vectors_gen.build().items():
        assert (VECTORS_DIR / "work" / file_name).read_text(encoding="utf-8") == text, file_name


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
        for case in load_cases("work", name):
            walk(case["input"])
            walk(case["expected"])


def test_spec_worked_examples() -> None:
    """Section 4 of docs/specs/stage4_work.md, computed by hand."""
    project = {"id": "p", "base_amount": 10_000_000, "status": "active", "client_id": "roma"}
    crs = [
        {"id": "cart", "project_id": "p", "amount": 3_000_000, "status": "closed"},
        {"id": "fil", "project_id": "p", "amount": 2_000_000, "status": "in_progress"},
        {"id": "chat", "project_id": "p", "amount": 1_500_000, "status": "cancelled"},
    ]
    allocs: list[dict[str, Any]] = [
        {
            "id": "a",
            "payment_id": "x",
            "project_id": "p",
            "change_request_id": None,
            "amount": 6_000_000,
        },
        {
            "id": "b",
            "payment_id": "x",
            "project_id": "p",
            "change_request_id": "cart",
            "amount": 1_000_000,
        },
        {
            "id": "c",
            "payment_id": "y",
            "project_id": "p",
            "change_request_id": "cart",
            "amount": 2_000_000,
        },
    ]
    summary = ref.project_summary(project, crs, allocs)
    assert (summary["total"], summary["received"], summary["remaining"]) == (
        15_000_000,
        9_000_000,
        6_000_000,
    )
    assert summary["paid_bp"] == 6000
    assert (summary["base_received"], summary["base_remaining"]) == (6_000_000, 4_000_000)
    assert [r["remaining"] for r in summary["change_requests"]] == [0, 2_000_000, 0]
    assert ref.per_hour(100_000, 3 * 3600) == 33_333
    assert ref.per_hour(9_000_000, 3 * 3600) == 3_000_000
    debt = ref.receivables(
        [
            {"id": "A", "base_amount": 7_000_000, "client_id": "roma"},
            {"id": "B", "base_amount": 4_000_000, "client_id": "roma"},
            {"id": "C", "base_amount": 20_000_000, "client_id": "elena"},
            {"id": "D", "base_amount": 5_000_000, "client_id": "roma", "status": "cancelled"},
        ],
        [],
        [],
    )
    assert debt["total"] == 31_000_000
    assert [(c["client_id"], c["remaining"]) for c in debt["clients"]] == [
        ("elena", 20_000_000),
        ("roma", 11_000_000),
    ]
