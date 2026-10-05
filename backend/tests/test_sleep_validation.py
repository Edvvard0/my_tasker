"""Server-side validation of the Stage 8 tables, driven through the real push endpoint."""

from typing import Any

import pytest

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.sleep_support import (
    checkin_fields,
    checkin_row_id,
    plan_fields,
    plan_row_id,
    sleep_fields,
    sleep_row_id,
)
from tests.test_work_validation import Case, run_cases

A, B = str(uuid7()), str(uuid7())


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


async def test_sleep_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, date: str = "2026-10-02", **over: Any) -> Case:
        fields = sleep_fields(phone, date, **over)
        return (label, "sleep_entries", sleep_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("plain night", None),
            case(
                "with bed zone, quality and note",
                None,
                "2026-10-03",
                bed_tz="Asia/Tokyo",
                quality=4,
                note="ок",
            ),
            case("morning notification", None, "2026-10-04", source="morning_notification"),
            case("exactly 24 hours", None, "2026-10-05", minutes=1440),
            case("over 24 hours", "validation_failed", "2026-10-06", minutes=1441),
            case(
                "wake equals bed",
                "validation_failed",
                "2026-10-07",
                wake_at="2026-10-07T04:00:00Z",
                bed_at="2026-10-07T04:00:00Z",
            ),
            case(
                "wake before bed",
                "validation_failed",
                "2026-10-08",
                bed_at="2026-10-08T05:00:00Z",
                wake_at="2026-10-08T04:00:00Z",
            ),
            case(
                "date is not the wake date",
                "validation_failed",
                "2026-10-09",
                wake_at="2026-10-10T04:00:00Z",
                bed_at="2026-10-09T20:00:00Z",
            ),
            case(
                "date follows the wake zone",
                None,
                "2026-10-12",
                wake_at="2026-10-11T21:30:00Z",
                bed_at="2026-10-11T14:00:00Z",
            ),
            case("unknown wake zone", "validation_failed", "2026-10-13", wake_tz="Mars/Base"),
            case("unknown bed zone", "validation_failed", "2026-10-14", bed_tz="Nowhere"),
            case("empty wake zone", "invalid_field", "2026-10-15", wake_tz=""),
            case("quality 0", "invalid_field", "2026-10-16", quality=0),
            case("quality 6", "invalid_field", "2026-10-17", quality=6),
            case("float quality", "invalid_field", "2026-10-18", quality=3.5),
            case("unknown source", "invalid_field", "2026-10-19", source="watch"),
            case("long note", "invalid_field", "2026-10-20", note="x" * 2001),
            case("date not a date", "invalid_field", "2.10.2026"),
            case("february 30", "validation_failed", "2026-02-30"),
            case("naive moment", "invalid_field", "2026-10-21", bed_at="2026-10-20T23:00:00"),
            case("bed_at missing", "invalid_field", "2026-10-22", bed_at=None),
        ],
    )


async def test_sleep_ids_are_the_date(phone: DeviceClient, env: Env) -> None:
    fields = sleep_fields(phone, "2026-10-02")
    (wrong,) = await phone.push_ok([phone.op("sleep_entries", uuid7(), fields=fields)])
    assert (wrong["status"], wrong["code"]) == ("rejected", "invalid_id")
    (good,) = await phone.push_ok([phone.op("sleep_entries", sleep_row_id(fields), fields=fields)])
    assert good["status"] == "applied"
    other = sleep_fields(phone, "2026-10-03")
    (mismatch,) = await phone.push_ok(
        [phone.op("sleep_entries", sleep_row_id(fields), fields=other)]
    )
    assert mismatch["code"] == "immutable_field"  # the date of a row never changes
    assert await env.scalar("SELECT count(*) FROM sleep_entries") == 1


async def test_plan_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, date: str = "2026-10-02", **over: Any) -> Case:
        fields = plan_fields(phone, date, **over)
        return (label, "daily_plans", plan_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("empty plan", None),
            case(
                "plan with tasks and a main one",
                None,
                "2026-10-03",
                task_ids=[A, B],
                main_task_id=A,
                note="день",
            ),
            case("main task outside the list", None, "2026-10-04", task_ids=[A], main_task_id=B),
            case("ten tasks", None, "2026-10-05", task_ids=[str(uuid7()) for _ in range(10)]),
            case(
                "eleven tasks",
                "validation_failed",
                "2026-10-06",
                task_ids=[str(uuid7()) for _ in range(11)],
            ),
            case("task twice", "validation_failed", "2026-10-07", task_ids=[A, A]),
            case("not a uuid", "validation_failed", "2026-10-08", task_ids=["abc"]),
            case("upper-case uuid", "validation_failed", "2026-10-09", task_ids=[A.upper()]),
            case("not a list", "validation_failed", "2026-10-10", task_ids={"a": 1}),
            case("a number in the list", "validation_failed", "2026-10-11", task_ids=[1]),
            case("bad main task", "invalid_field", "2026-10-12", main_task_id="nope"),
            case("long note", "invalid_field", "2026-10-13", note="x" * 2001),
            case("february 30", "validation_failed", "2026-02-30"),
            case("task_ids missing", "invalid_field", "2026-10-14", task_ids=None),
        ],
    )
    fields = plan_fields(phone, "2026-11-01")
    (wrong,) = await phone.push_ok([phone.op("daily_plans", uuid7(), fields=fields)])
    assert wrong["code"] == "invalid_id"


async def test_checkin_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, date: str = "2026-10-02", **over: Any) -> Case:
        fields = checkin_fields(phone, date, **over)
        return (label, "evening_checkins", checkin_row_id(fields), fields, expected)

    tomorrow = {"task_id": A, "to": "tomorrow"}
    on_date = {"task_id": B, "to": "date", "date": "2026-10-20"}
    await run_cases(
        phone,
        [
            case("empty check-in", None),
            case(
                "full check-in",
                None,
                "2026-10-03",
                rating=4,
                done_task_ids=[A],
                carry_over=[on_date],
                note="ок",
            ),
            case("both kinds of decision", None, "2026-10-04", carry_over=[tomorrow, on_date]),
            case("rating 1 and 5", None, "2026-10-05", rating=5),
            case("rating 0", "invalid_field", "2026-10-06", rating=0),
            case("rating 6", "invalid_field", "2026-10-07", rating=6),
            case("done twice", "validation_failed", "2026-10-08", done_task_ids=[A, A]),
            case("done not a uuid", "validation_failed", "2026-10-09", done_task_ids=["x"]),
            case("carry not a list", "validation_failed", "2026-10-10", carry_over={"a": 1}),
            case("carry item not an object", "validation_failed", "2026-10-11", carry_over=[1]),
            case(
                "carry with an extra key",
                "validation_failed",
                "2026-10-12",
                carry_over=[{**tomorrow, "x": 1}],
            ),
            case(
                "carry unknown target",
                "validation_failed",
                "2026-10-13",
                carry_over=[{"task_id": A, "to": "friday"}],
            ),
            case(
                "carry to a date without a date",
                "validation_failed",
                "2026-10-14",
                carry_over=[{"task_id": A, "to": "date"}],
            ),
            case(
                "carry to a bad date",
                "validation_failed",
                "2026-10-15",
                carry_over=[{"task_id": A, "to": "date", "date": "2026-02-30"}],
            ),
            case(
                "carry to a malformed date",
                "validation_failed",
                "2026-10-16",
                carry_over=[{"task_id": A, "to": "date", "date": "20.10"}],
            ),
            case(
                "tomorrow with a date",
                "validation_failed",
                "2026-10-17",
                carry_over=[{**tomorrow, "date": "2026-10-20"}],
            ),
            case(
                "carry a task twice",
                "validation_failed",
                "2026-10-18",
                carry_over=[tomorrow, on_date | {"task_id": A}],
            ),
            case(
                "carry bad task id",
                "validation_failed",
                "2026-10-19",
                carry_over=[{"task_id": "x", "to": "tomorrow"}],
            ),
            case(
                "fifty decisions",
                None,
                "2026-10-20",
                carry_over=[{"task_id": str(uuid7()), "to": "tomorrow"} for _ in range(50)],
            ),
            case(
                "fifty-one decisions",
                "validation_failed",
                "2026-10-21",
                carry_over=[{"task_id": str(uuid7()), "to": "tomorrow"} for _ in range(51)],
            ),
            case("february 30", "validation_failed", "2026-02-30"),
        ],
    )
    fields = checkin_fields(phone, "2026-11-01")
    (wrong,) = await phone.push_ok([phone.op("evening_checkins", uuid7(), fields=fields)])
    assert wrong["code"] == "invalid_id"


async def test_the_date_cannot_be_changed(phone: DeviceClient) -> None:
    fields = sleep_fields(phone)
    row = sleep_row_id(fields)
    await phone.push_ok([phone.op("sleep_entries", row, fields=fields)])
    (result,) = await phone.push_ok(
        [phone.op("sleep_entries", row, fields={"date": "2026-10-03"}, base=1)]
    )
    assert result["code"] == "immutable_field"
    plan = plan_fields(phone)
    await phone.push_ok([phone.op("daily_plans", plan_row_id(plan), fields=plan)])
    (result,) = await phone.push_ok(
        [phone.op("daily_plans", plan_row_id(plan), fields={"date": "2026-10-03"}, base=1)]
    )
    assert result["code"] == "immutable_field"
    (edited,) = await phone.push_ok(
        [phone.op("sleep_entries", row, fields={"quality": 5, "note": "лучше"}, base=1)]
    )
    assert edited["status"] == "applied"
