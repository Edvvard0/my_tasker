import random
from typing import Any

import pytest

from tasker.money import AmountError, format_amount, parse_amount
from tests.vectors import load_cases

PARSE_CASES = load_cases("money", "parse_amount")
FORMAT_CASES = load_cases("money", "format_amount")


def test_vectors_are_substantial() -> None:
    assert len(PARSE_CASES) >= 25
    assert len(FORMAT_CASES) >= 15


@pytest.mark.parametrize("case", PARSE_CASES, ids=[c["name"] for c in PARSE_CASES])
def test_parse_amount_vectors(case: dict[str, Any]) -> None:
    if case["expected"] == {"error": True}:
        with pytest.raises(AmountError):
            parse_amount(case["input"])
    else:
        assert parse_amount(case["input"]) == case["expected"]


@pytest.mark.parametrize("case", FORMAT_CASES, ids=[c["name"] for c in FORMAT_CASES])
def test_format_amount_vectors(case: dict[str, Any]) -> None:
    assert format_amount(case["input"]) == case["expected"]


def test_round_trip() -> None:
    rng = random.Random(42)
    limit = 99_999_999_999_999
    values = [0, 1, -1, 99, 100, limit, -limit, *(rng.randint(-limit, limit) for _ in range(500))]
    for value in values:
        assert parse_amount(format_amount(value)) == value
