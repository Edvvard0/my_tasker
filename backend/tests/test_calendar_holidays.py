"""Consistency of the bundled RF holidays file (spec stage2 section 7)."""

import json
from datetime import date, timedelta
from typing import Any

import pytest

from tasker.calendar.holidays import DATA_PATH, TYPES, day_info, load


@pytest.fixture(scope="module")
def data() -> dict[str, Any]:
    return load()


def test_file_shape(data: dict[str, Any]) -> None:
    assert data["version"] == 1
    assert {"2026", "2027"} <= set(data["years"])
    for year, block in data["years"].items():
        assert block["status"] in ("official", "provisional"), year
        assert block["source"], year


def test_entries_are_consistent(data: dict[str, Any]) -> None:
    for year, block in data["years"].items():
        seen: set[str] = set()
        for entry in block["days"]:
            day = date.fromisoformat(entry["date"])
            assert str(day.year) == year, entry
            assert entry["date"] not in seen, f"duplicate {entry['date']}"
            seen.add(entry["date"])
            assert entry["type"] in TYPES, entry
            assert entry["name"], entry
            if entry["type"] == "transfer_off":
                assert day.weekday() < 5, f"a transfer must land on a weekday: {entry}"
            if entry["type"] == "working_weekend":
                assert day.weekday() >= 5, entry
        assert block["days"] == sorted(block["days"], key=lambda e: e["date"])


@pytest.mark.parametrize(("year", "minimum", "maximum"), [(2026, 247, 247), (2027, 244, 250)])
def test_working_day_counts(data: dict[str, Any], year: int, minimum: int, maximum: int) -> None:
    day, working = date(year, 1, 1), 0
    while day.year == year:
        working += not day_info(data, day).is_day_off
        day += timedelta(days=1)
    assert minimum <= working <= maximum


def test_unlisted_dates_follow_the_weekend_rule(data: dict[str, Any]) -> None:
    assert day_info(data, date(2026, 10, 3)).is_day_off  # Saturday
    assert not day_info(data, date(2026, 10, 5)).is_day_off  # Monday
    assert not day_info(data, date(2031, 1, 6)).is_day_off  # a year outside the file: Monday
    assert day_info(data, date(2031, 1, 5)).is_day_off  # ... and its Sunday


def test_working_weekend_entry_overrides_the_weekend() -> None:
    data = {
        "years": {
            "2030": {"days": [{"date": "2030-03-02", "type": "working_weekend", "name": "x"}]}
        }
    }
    info = day_info(data, date(2030, 3, 2))  # a Saturday
    assert (info.is_day_off, info.name) == (False, "x")


def test_file_is_valid_utf8_json_with_cyrillic() -> None:
    text = DATA_PATH.read_text(encoding="utf-8")
    assert "Новогодние каникулы" in text
    assert json.loads(text)["updated"]
