"""Shared Banks vectors: every case of every file must pass (the Dart side does the same)."""

import hashlib
from typing import Any

import pytest

from tasker.banks import reference as ref
from tests import banks_vectors_gen as gen
from tests.vectors import VECTORS_DIR, load_cases

FILES = tuple(gen.FILES)


def _params() -> list[Any]:
    return [
        pytest.param(name, case, id=f"{name}:{case['name']}")
        for name in FILES
        for case in load_cases("banks", name)
    ]


@pytest.mark.parametrize(("file", "case"), _params())
def test_vector(file: str, case: dict[str, Any]) -> None:
    assert gen.FILES[file][2](case["input"]) == case["expected"]


def test_at_least_50_cases_and_unique_names() -> None:
    total = 0
    for name in FILES:
        names = [case["name"] for case in load_cases("banks", name)]
        assert len(names) == len(set(names))
        total += len(names)
    assert total >= 50


def test_vectors_on_disk_are_what_the_generator_builds() -> None:
    for file_name, text in gen.build().items():
        assert (VECTORS_DIR / "banks" / file_name).read_text(encoding="utf-8") == text, file_name


def test_the_required_situations_are_covered() -> None:
    names = {case["name"] for case in load_cases("banks", "matching")}
    transfers = {case["name"] for case in load_cases("banks", "transfers")}
    assert {
        "notification_draft_refined_by_a_dated_statement_line",
        "near_amount_is_not_a_match",
        "two_equal_purchases_one_existing_draft",
        "refund_is_not_the_purchase",
        "foreign_currency_is_needs_review_and_never_fuzzy_matched",
    } <= names
    assert {"basic_pair", "same_account_is_a_refund_not_a_transfer"} <= transfers


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
        for case in load_cases("banks", name):
            walk(case["input"])
            walk(case["expected"])


def test_the_hash_by_hand() -> None:
    """Spec 3.2: sha256 of ``account|kind|amount|minute|merchant_norm``, first 32 hex digits."""
    given: dict[str, Any] = {
        "account_id": "acc",
        "kind": "expense",
        "amount": 123_456,
        "occurred_at": "2026-10-03T11:30:59Z",
        "merchant": "ООО «Пятёрочка» 1234 Москва",
    }
    text = "acc|expense|123456|2026-10-03T11:30|пятерочка"
    assert ref.dedup_hash(**given) == hashlib.sha256(text.encode()).hexdigest()[:32]
    assert len(ref.dedup_hash(**given)) == 32
    again = ref.dedup_hash(**{**given, "ordinal": 1})
    assert again == hashlib.sha256((text + "|1").encode()).hexdigest()[:32]
    assert again != ref.dedup_hash(**given)


def test_classification_is_deterministic_and_does_not_touch_its_input() -> None:
    cases = load_cases("banks", "matching")
    for case in cases:
        given = case["input"]
        before = repr(given)
        first = ref.classify_candidates(given["account_id"], given["candidates"], given["existing"])
        second = ref.classify_candidates(
            given["account_id"], given["candidates"], given["existing"]
        )
        assert first == second
        assert repr(given) == before
