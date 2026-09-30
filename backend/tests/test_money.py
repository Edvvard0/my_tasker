import random
from typing import Any

import pytest

from tasker.money import MAX_KOPECKS, AmountError, format_amount, parse_amount
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
    if case["expected"] == {"error": True}:
        with pytest.raises(AmountError):
            format_amount(case["input"])
    else:
        assert format_amount(case["input"]) == case["expected"]


@pytest.mark.parametrize("value", [MAX_KOPECKS + 1, -MAX_KOPECKS - 1, 10**30, -(10**30)])
def test_format_amount_out_of_range_raises(value: int) -> None:
    with pytest.raises(AmountError):
        format_amount(value)


@pytest.mark.parametrize("value", [1.0, "100", None, True, False, b"1", [1]])
def test_format_amount_invalid_type_raises(value: Any) -> None:
    with pytest.raises(TypeError):
        format_amount(value)


def test_format_amount_bounds_are_accepted() -> None:
    assert format_amount(MAX_KOPECKS).endswith(",99\u00a0₽")
    assert format_amount(-MAX_KOPECKS).startswith("-999")


def test_round_trip() -> None:
    rng = random.Random(42)
    limit = 99_999_999_999_999
    values = [0, 1, -1, 99, 100, limit, -limit, *(rng.randint(-limit, limit) for _ in range(500))]
    for value in values:
        assert parse_amount(format_amount(value)) == value
