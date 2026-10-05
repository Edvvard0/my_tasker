"""The Sleep read tools on seeded data: sleep stats and daily rituals."""

import json
from typing import Any
from zoneinfo import ZoneInfo

import pytest

import tasker.ai.builtin  # noqa: F401 - registers the tools
from tasker.ai.agents import SEED_BY_KEY, SLEEP_TOOLS, builtin_tools
from tasker.ai.tools import TOOLS, ToolArgumentError, ToolContext
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.calendar_support import task_fields
from tests.sleep_support import (
    checkin_fields,
    checkin_row_id,
    plan_fields,
    plan_row_id,
    sleep_fields,
    sleep_row_id,
)


async def call(env: Env, name: str, args: dict[str, Any]) -> dict[str, Any]:
    spec = TOOLS.get(name)
    assert spec is not None
    assert spec.handler is not None
    ctx = ToolContext(env.sessionmaker, ZoneInfo("Europe/Moscow"))
    text = await spec.handler(ctx, spec.parse(args))
    assert len(text) <= 20_000
    result: dict[str, Any] = json.loads(text)
    return result


async def nights(dc: DeviceClient, spec: dict[str, int | None]) -> None:
    # a night is written after it happened: the server refuses moments more than a day ahead
    dc.env.clock.advance(days=30)
    await dc.refresh()
    ops = []
    for day, minutes in spec.items():
        if minutes is None:
            continue
        fields = sleep_fields(dc, f"2026-10-{int(day):02d}", minutes, note="заметка", quality=3)
        ops.append(dc.op("sleep_entries", sleep_row_id(fields), fields=fields))
    results = await dc.push_ok(ops)
    assert all(r["status"] == "applied" for r in results), results


def test_the_tools_are_read_tools_of_the_sleep_profile() -> None:
    for name in SLEEP_TOOLS:
        spec = TOOLS.get(name)
        assert spec is not None
        assert spec.kind == "read"
    assert builtin_tools("sleep")[-2:] == SLEEP_TOOLS
    assert "get_sleep_stats" not in builtin_tools("study")
    assert "get_sleep_stats" in SEED_BY_KEY["sleep"].prompt


async def test_stats_show_nights_averages_and_the_task_link(env: Env) -> None:
    phone = await env.login()
    await nights(phone, {"1": 300, "2": 480, "3": None, "4": 450, "5": 330, "6": 420, "7": 500})
    ops = []
    for day, done in (("2026-10-01", "done"), ("2026-10-01", "todo"), ("2026-10-02", "done")):
        ops.append(phone.op("tasks", uuid7(), fields=task_fields(phone, status=done, due_date=day)))
    ops.append(
        phone.op(
            "tasks",
            uuid7(),
            fields=task_fields(
                phone, status="done", due_at="2026-10-02T21:30:00Z", due_tz="Europe/Moscow"
            ),
        )  # 2026-10-03 on the wall clock: a day without a night in the list
    )
    ops.append(
        phone.op(
            "tasks",
            uuid7(),
            fields=task_fields(
                phone,
                status="done",
                due_date="2026-10-04",
                rrule="FREQ=DAILY",
                recurrence_mode="schedule",
            ),
        )
    )
    await phone.push_ok(ops)
    result = await call(env, "get_sleep_stats", {"through_date": "2026-10-07"})
    assert result["through"] == "2026-10-07"
    assert [e["date"] for e in result["entries"]] == [
        "2026-10-01",
        "2026-10-02",
        "2026-10-04",
        "2026-10-05",
        "2026-10-06",
        "2026-10-07",
    ]
    first = result["entries"][0]
    assert first == {
        "date": "2026-10-01",
        "bed": "02:00",
        "wake": "07:00",
        "minutes": 300,
        "quality": 3,
        "note": "заметка",
    }
    week = result["average_7_days"]
    assert (week["days_with_data"], week["average_minutes"]) == (6, 413)  # 2480 // 6
    assert result["average_30_days"]["days_with_data"] == 6
    link = result["tasks_vs_sleep_last_7_days"]
    assert link["short"] == {"days": 1, "tasks": 2, "done": 1, "share_bp": 5000}
    assert link["normal"] == {"days": 1, "tasks": 1, "done": 1, "share_bp": 10000}
    assert link["days_without_sleep"] == 1
    assert link["enough_data"] is False


async def test_stats_limit_the_list_but_not_the_averages(env: Env) -> None:
    phone = await env.login()
    await nights(phone, {"1": 300, "6": 420, "7": 480})
    result = await call(env, "get_sleep_stats", {"through_date": "2026-10-07", "days": 2})
    assert [e["date"] for e in result["entries"]] == ["2026-10-06", "2026-10-07"]
    assert result["average_7_days"]["days_with_data"] == 3


async def test_stats_without_data_and_default_date(env: Env) -> None:
    result = await call(env, "get_sleep_stats", {})
    assert result["entries"] == []
    assert result["average_7_days"]["average_minutes"] is None
    assert result["through"] >= "2026-01-01"


async def test_a_long_history_is_clipped_to_the_newest_nights(env: Env) -> None:
    phone = await env.login()
    ops = []
    for day in range(1, 29):
        fields = sleep_fields(phone, f"2026-09-{day:02d}", 420, note="я" * 600, quality=3)
        ops.append(phone.op("sleep_entries", sleep_row_id(fields), fields=fields))
    for day in range(1, 29):
        fields = sleep_fields(phone, f"2026-08-{day:02d}", 420, note="ы" * 600, quality=3)
        ops.append(phone.op("sleep_entries", sleep_row_id(fields), fields=fields))
    await phone.push_ok(ops[:28])
    await phone.push_ok(ops[28:])
    result = await call(env, "get_sleep_stats", {"through_date": "2026-09-28", "days": 60})
    assert result["truncated"] is True
    assert result["count"] == len(result["entries"]) < 56
    assert result["entries"][-1]["date"] == "2026-09-28"  # the newest nights are kept
    assert all(len(e["note"]) == 300 for e in result["entries"])


async def test_stats_argument_errors(env: Env) -> None:
    for bad in (
        {"days": 0},
        {"days": 61},
        {"days": "7"},
        {"through_date": "2026-02-30"},
        {"through_date": "1.10.2026"},
    ):
        with pytest.raises(ToolArgumentError):
            await call(env, "get_sleep_stats", bad)


async def test_rituals_show_plans_checkins_and_streaks(env: Env) -> None:
    phone = await env.login()
    main, other = str(uuid7()), str(uuid7())
    ops = []
    for day in (3, 4, 5, 6, 7):
        plan = plan_fields(
            phone, f"2026-10-{day:02d}", task_ids=[main, other], main_task_id=main, note="н" * 400
        )
        ops.append(phone.op("daily_plans", plan_row_id(plan), fields=plan))
    for day in (6, 7):
        checkin = checkin_fields(
            phone,
            f"2026-10-{day:02d}",
            rating=day - 2,
            done_task_ids=[main],
            carry_over=[{"task_id": other, "to": "tomorrow"}],
        )
        ops.append(phone.op("evening_checkins", checkin_row_id(checkin), fields=checkin))
    old = plan_fields(phone, "2026-09-01")
    ops.append(phone.op("daily_plans", plan_row_id(old), fields=old))
    await phone.push_ok(ops)
    result = await call(env, "get_daily_rituals", {"through_date": "2026-10-07", "days": 3})
    assert [p["date"] for p in result["plans"]] == ["2026-10-05", "2026-10-06", "2026-10-07"]
    assert result["plans"][0]["main_task_id"] == main
    assert len(result["plans"][0]["note"]) == 300
    assert result["checkins"] == [
        {"date": "2026-10-06", "rating": 4, "done_tasks": 1, "carried_tasks": 1, "note": None},
        {"date": "2026-10-07", "rating": 5, "done_tasks": 1, "carried_tasks": 1, "note": None},
    ]
    streaks = result["streaks"]
    assert streaks["morning"] == {"current": 5, "best": 5, "last": "2026-10-07"}
    assert streaks["evening"]["current"] == 2
    assert streaks["both"]["current"] == 2
    assert result["count"] == 5


async def test_rituals_without_data_and_argument_errors(env: Env) -> None:
    result = await call(env, "get_daily_rituals", {})
    assert result["plans"] == [] and result["checkins"] == []
    assert result["streaks"]["both"]["current"] == 0
    for bad in ({"days": 31}, {"days": 0}, {"through_date": "nope"}):
        with pytest.raises(ToolArgumentError):
            await call(env, "get_daily_rituals", bad)


async def test_rituals_are_clipped_when_the_answer_is_too_long(env: Env) -> None:
    phone = await env.login()
    tasks = [str(uuid7()) for _ in range(10)]
    ops = []
    for day in range(1, 31):
        plan = plan_fields(
            phone, f"2026-09-{day:02d}", task_ids=tasks, main_task_id=tasks[0], note="я" * 2000
        )
        ops.append(phone.op("daily_plans", plan_row_id(plan), fields=plan))
    await phone.push_ok(ops)
    result = await call(env, "get_daily_rituals", {"through_date": "2026-09-30", "days": 30})
    assert result["truncated"] is True
    assert result["plans"][-1]["date"] == "2026-09-30"
    assert len(result["plans"]) < 30


async def test_a_damaged_row_is_left_out_of_the_stats(env: Env) -> None:
    phone = await env.login()
    await nights(phone, {"6": 420, "7": 480})
    await env.execute(
        "UPDATE sleep_entries SET wake_at = bed_at - interval '1 hour' WHERE date = '2026-10-06'"
    )  # cannot happen through the API; the tool must still not break
    result = await call(env, "get_sleep_stats", {"through_date": "2026-10-07"})
    assert [e["date"] for e in result["entries"]] == ["2026-10-07"]
    assert result["average_7_days"]["days_with_data"] == 1
