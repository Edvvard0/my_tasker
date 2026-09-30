"""Unit tests of the calendar domain code: RRULE subset, expansion, quick input, time helpers."""

from datetime import UTC, date, datetime
from typing import Any
from zoneinfo import ZoneInfo

import pytest

from tasker.calendar import ids
from tasker.calendar.reference_expand import expand, local_to_utc
from tasker.calendar.reference_quick_input import parse_quick_input
from tasker.calendar.rrule_subset import RRuleError, parse_rrule, rrule_problem
from tasker.calendar.timefmt import format_utc, parse_date, parse_utc
from tasker.calendar.week_cycle import Cycle, cycle_week, first_date, monday_of

# ------------------------------------------------------------------ timefmt


@pytest.mark.parametrize(
    "text",
    [
        "2026-02-29",
        "2026-13-01",
        "26-01-01",
        "2026-1-1",
        "1969-12-31",
        "2201-01-01",
        " 2026-01-01",
        "٢٠٢٦-٠١-٠١",
    ],
)
def test_parse_date_rejects(text: str) -> None:
    assert parse_date(text) is None


def test_parse_date_accepts_real_dates() -> None:
    assert parse_date("2028-02-29") == date(2028, 2, 29)


@pytest.mark.parametrize(
    "text",
    [
        "2026-10-05T07:00:00",
        "2026-10-05T07:00:00+00:00",
        "2026-10-05 07:00:00Z",
        "2026-10-05T25:00:00Z",
        "2026-10-05T07:00:00.5Z",
        "1960-01-01T00:00:00Z",
    ],
)
def test_parse_utc_rejects(text: str) -> None:
    assert parse_utc(text) is None


def test_utc_round_trip() -> None:
    moment = parse_utc("2026-10-05T07:00:00Z")
    assert moment == datetime(2026, 10, 5, 7, tzinfo=UTC)
    assert moment is not None
    assert format_utc(moment) == "2026-10-05T07:00:00Z"


# ------------------------------------------------------------------ rrule subset


def test_parse_rrule_fields() -> None:
    rule = parse_rrule("FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR,2TU;COUNT=9", all_day=False)
    assert (rule.freq, rule.interval, rule.count) == ("MONTHLY", 2, 9)
    assert rule.byday == ((-1, 4), (2, 1))
    weekly = parse_rrule("FREQ=WEEKLY;BYDAY=MO,SU", all_day=False)
    assert weekly.byday == ((None, 0), (None, 6))
    monthday = parse_rrule("FREQ=MONTHLY;BYMONTHDAY=-1,15", all_day=True)
    assert monthday.bymonthday == (-1, 15)


def test_parse_rrule_until_forms() -> None:
    timed = parse_rrule("FREQ=DAILY;UNTIL=20261231T210000Z", all_day=False)
    assert timed.until_utc == datetime(2026, 12, 31, 21, tzinfo=UTC)
    assert timed.until_date is None
    dated = parse_rrule("FREQ=DAILY;UNTIL=20261231", all_day=True)
    assert dated.until_date == date(2026, 12, 31)
    assert dated.until_utc is None


def test_parse_rrule_error_messages_name_the_problem() -> None:
    with pytest.raises(RRuleError, match="unsupported part"):
        parse_rrule("FREQ=DAILY;BYSETPOS=1", all_day=False)
    assert rrule_problem("FREQ=DAILY", all_day=False) is None
    assert "FREQ" in (rrule_problem("INTERVAL=2", all_day=False) or "")
    assert "too long" in (rrule_problem("FREQ=DAILY;" + "X" * 300, all_day=False) or "")


# ------------------------------------------------------------------ expansion


def _timed(rrule: str | None, **extra: Any) -> dict[str, Any]:
    return {
        "all_day": False,
        "tz": "Europe/Moscow",
        "start": "2026-10-05T07:00:00Z",
        "end": "2026-10-05T08:00:00Z",
        "rrule": rrule,
        "title": "T",
        "window": {"from": "2026-10-01T00:00:00Z", "to": "2026-11-01T00:00:00Z"},
        **extra,
    }


def test_expand_defaults_missing_optional_inputs() -> None:
    instances = expand(_timed("FREQ=WEEKLY;COUNT=2"))
    assert [i["start"] for i in instances] == ["2026-10-05T07:00:00Z", "2026-10-12T07:00:00Z"]


def test_expand_is_stable_for_a_window_before_the_series() -> None:
    inp = _timed(
        "FREQ=DAILY", window={"from": "2026-01-01T00:00:00Z", "to": "2026-02-01T00:00:00Z"}
    )
    assert expand(inp) == []


def test_expand_override_without_title_keeps_the_event_title() -> None:
    inp = _timed(
        "FREQ=DAILY;COUNT=2",
        overrides=[
            {
                "original_start": "2026-10-06T07:00:00Z",
                "start": "2026-10-06T09:00:00Z",
                "end": "2026-10-06T10:00:00Z",
                "title": None,
            }
        ],
    )
    assert [(i["start"], i["title"]) for i in expand(inp)] == [
        ("2026-10-05T07:00:00Z", "T"),
        ("2026-10-06T09:00:00Z", "T"),
    ]


def test_expansion_guard_against_runaway_rules(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("tasker.calendar.reference_expand._MAX_ITERATIONS", 5)
    inp = _timed(
        "FREQ=DAILY", window={"from": "2027-01-01T00:00:00Z", "to": "2027-01-02T00:00:00Z"}
    )
    with pytest.raises(RuntimeError, match="window"):
        expand(inp)


def test_expand_rejects_garbage_instants() -> None:
    with pytest.raises(ValueError, match="UTC instant"):
        expand(_timed(None, start="tomorrow"))
    with pytest.raises(ValueError, match="not a date"):
        expand({"all_day": True, "start": "x", "end": "y", "window": {"from": "a", "to": "b"}})


def test_local_to_utc_uses_the_offset_before_the_transition() -> None:
    berlin = ZoneInfo("Europe/Berlin")
    assert local_to_utc(datetime(2026, 3, 29, 2, 30), berlin) == datetime(
        2026, 3, 29, 1, 30, tzinfo=UTC
    )
    assert local_to_utc(datetime(2026, 10, 25, 2, 30), berlin) == datetime(
        2026, 10, 25, 0, 30, tzinfo=UTC
    )
    assert local_to_utc(datetime(2026, 7, 1, 12, 0), berlin) == datetime(
        2026, 7, 1, 10, 0, tzinfo=UTC
    )


# ------------------------------------------------------------------ week cycle


def test_cycle_week_normalises_the_anchor_and_negative_weeks() -> None:
    anchor = date(2026, 9, 1)  # a Tuesday: week 1 starts Monday 2026-08-31
    assert monday_of(anchor) == date(2026, 8, 31)
    assert cycle_week(date(2026, 8, 31), anchor, 2) == 1
    assert cycle_week(date(2026, 8, 30), anchor, 2) == 2
    assert cycle_week(date(2026, 8, 30), anchor, 3) == 3
    assert cycle_week(date(2026, 9, 14), anchor, 1) == 1


def test_first_date_finds_the_requested_cycle_week() -> None:
    cycle = Cycle(date(2026, 8, 31), 2)
    assert first_date(date(2026, 9, 1), 1, 2, cycle) == date(2026, 9, 8)
    shifted = Cycle(date(2026, 8, 31), 2, ((date(2026, 11, 2), 1),))
    assert first_date(date(2026, 11, 2), 1, 1, shifted) == date(2026, 11, 3)


# ------------------------------------------------------------------ quick input


NOW = datetime(2026, 9, 30, 14, 5)


def _parse(text: str, now: datetime = NOW) -> dict[str, object]:
    return parse_quick_input(text, now).as_json()


def test_quick_input_reports_all_fields() -> None:
    result = _parse("завтра 15:00 позвонить Роме !1 #работа @Рома +звонок на полчаса")
    assert result == {
        "title": "позвонить Роме",
        "priority": 1,
        "project": "работа",
        "people": ["Рома"],
        "tags": ["звонок"],
        "date": "2026-10-01",
        "time": "15:00",
        "duration_minutes": 30,
    }


def test_quick_input_never_fails_on_odd_input() -> None:
    for text in [
        "",
        " ",
        "!",
        "#",
        "@",
        "+",
        "через",
        "на",
        "в",
        "с 10:00 до",
        "1.",
        "15 ",
        "через 2",
        "в следующий",
    ]:
        assert parse_quick_input(text, NOW).date is None or text
    assert _parse("через")["title"] == "через"
    assert _parse("с 10:00 до")["time"] == "10:00"


def test_quick_input_relative_moment_crosses_midnight() -> None:
    result = _parse("через 3 часа", datetime(2026, 12, 31, 22, 30))
    assert (result["date"], result["time"]) == ("2027-01-01", "01:30")


def test_quick_input_month_clamps_to_the_end_of_the_month() -> None:
    assert _parse("через месяц", datetime(2026, 12, 31, 9, 0))["date"] == "2027-01-31"
    assert _parse("через 2 месяца", datetime(2026, 12, 31, 9, 0))["date"] == "2027-02-28"


def test_quick_input_unicode_variants() -> None:
    assert _parse("ДНЁМ")["time"] == "13:00"
    assert _parse("Пятницу")["date"] == "2026-10-02"
    assert _parse("завтра в 9 утра")["time"] == "09:00"


def test_quick_input_second_component_stays_in_the_title() -> None:
    assert _parse("завтра 10:00 и 11:00 встреча")["title"] == "и 11:00 встреча"


# ------------------------------------------------------------------ ids


def test_deterministic_ids_are_stable_and_distinct() -> None:
    assert ids.tag_id("Работа") == ids.tag_id("работа")
    assert ids.tag_id("работа") != ids.tag_id("дом")
    event = "0195f2a0-7b1c-7a3e-8f10-0123456789ab"
    assert ids.override_id(event, "2026-10-05") != ids.override_id(event, "2026-10-06")
    assert ids.system_calendar_id("personal") != ids.system_calendar_id("work")
    assert ids.task_tag_id(event, event) != ids.completion_id(event, "2026-10-05")
