"""Shared Finance vectors: every case of every file must pass (the Dart side does the same)."""

import uuid
from typing import Any

import pytest

from tasker.finance import reference as ref
from tasker.finance.presets import PRESETS, category_id
from tests import finance_vectors_gen as gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = tuple(gen.FILES)


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("finance", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    assert gen.FILES[file][2](case["input"]) == case["expected"]


def test_at_least_70_cases_and_unique_names() -> None:
    total = 0
    for name in FILES:
        names = [case["name"] for case in load_cases("finance", name)]
        assert len(names) == len(set(names))
        total += len(names)
    assert total >= 70


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in gen.build().items():
        assert (VECTORS_DIR / "finance" / file_name).read_text(encoding="utf-8") == text, file_name


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
        for case in load_cases("finance", name):
            walk(case["input"])
            walk(case["expected"])


def test_the_excel_case_by_hand() -> None:
    """Spec section 6.3: 54 000 + 174 000 + 8 000, debts to me 7 500 + 2 600 + 3 000, Roma
    20 000 + 60 500 -> have 329 600; plus the credit card 125 000 -> 454 600; target 400 000 ->
    missing -54 600."""
    case = {c["name"]: c for c in load_cases("finance", "goals")}
    without = case["excel_have_329600_without_the_credit_card"]["expected"]
    assert (without["have"], without["missing"]) == (329_600_00, 70_400_00)
    with_card = case["excel_default_formula_with_the_credit_card_have_454600_missing_minus_54600"][
        "expected"
    ]
    assert (with_card["have"], with_card["missing"], with_card["surplus"]) == (
        454_600_00,
        -54_600_00,
        54_600_00,
    )
    assert with_card["reached"] is True
    assert [t["value"] for t in with_card["terms"]] == [361_000_00, 13_100_00, 80_500_00]


def test_a_transfer_is_never_income_or_expense() -> None:
    both = [
        {
            "id": "t",
            "kind": "transfer",
            "account_id": "a",
            "to_account_id": "b",
            "amount": 5,
            "occurred_at": "2026-10-05T09:00:00Z",
            "status": "confirmed",
        }
    ]
    assert ref.monthly_totals(both) == []
    assert ref.category_breakdown(both, [], "expense")["total"] == 0
    assert ref.category_breakdown(both, [], "income")["total"] == 0
    assert ref.top_merchants(both) == []


def test_preset_categories() -> None:
    top = [p for p in PRESETS if p.parent is None]
    assert sum(p.kind == "expense" for p in top) == 15
    assert sum(p.kind == "income" for p in top) == 5
    keys = {p.key: p for p in PRESETS}
    assert len(keys) == len(PRESETS)
    for preset in PRESETS:
        if preset.parent is not None:
            assert keys[preset.parent].parent is None  # two levels
            assert keys[preset.parent].kind == preset.kind
    assert len({category_id(p.key) for p in PRESETS}) == len(PRESETS)
    assert category_id("expense.groceries") == uuid.uuid5(
        uuid.uuid5(uuid.NAMESPACE_URL, "urn:my-tasker:categories"), "expense.groceries"
    )
