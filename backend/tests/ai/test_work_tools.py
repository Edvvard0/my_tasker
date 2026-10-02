"""The Work read tools on seeded data: projects with remainders, receivables, hours and income."""

import json
from typing import Any
from zoneinfo import ZoneInfo

import pytest

import tasker.ai.builtin  # noqa: F401 - registers the tools
from tasker.ai.tools import TOOLS, ToolArgumentError, ToolContext
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.work_support import (
    WorkSeed,
    entry_fields,
    person_fields,
    project_fields,
    work_seed,
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


async def seeded(env: Env) -> tuple[DeviceClient, WorkSeed, dict[str, Any]]:
    phone = await env.login()
    seed = await work_seed(phone)
    elena, elena_project, old, gone = uuid7(), uuid7(), uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op("people", elena, fields=person_fields(phone, name="Елена", role="client")),
            phone.op(
                "projects",
                elena_project,
                fields=project_fields(
                    phone, title="Лендинг Елены", client_id=str(elena), base_amount=5_000_000
                ),
            ),
            phone.op(
                "projects",
                old,
                fields=project_fields(
                    phone,
                    title="Старый заказ",
                    client_id=str(seed.roma),
                    status="cancelled",
                    archived=True,
                    base_amount=900_000,
                ),
            ),
            phone.op("projects", gone, fields=project_fields(phone, title="Удалён", base_amount=1)),
        ]
    )
    await phone.push_ok([phone.op("projects", gone, "delete", base=await head(phone))])
    return phone, seed, {"elena": elena, "elena_project": elena_project, "old": old}


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


async def test_tools_are_registered_as_read_tools() -> None:
    for name in ("get_projects", "get_receivables", "get_work_hours"):
        spec = TOOLS.get(name)
        assert spec is not None
        assert spec.kind == "read"


async def test_get_projects_lists_live_unarchived_projects_by_remainder(env: Env) -> None:
    _, seed, extra = await seeded(env)
    result = await call(env, "get_projects", {})
    assert result["count"] == 2 and result["truncated"] is False
    roma, elena = result["projects"]
    assert (roma["title"], roma["client"], roma["status"]) == ("Сайт Ромы", "Рома", "active")
    assert roma["total_kopecks"] == 15_000_000
    assert roma["received_kopecks"] == 9_000_000
    assert roma["remaining_kopecks"] == 6_000_000
    assert roma["remaining_text"] == "60 000 ₽"
    assert roma["paid_percent"] == 60.0
    assert roma["id"] == str(seed.project)
    assert (elena["title"], elena["status"], elena["remaining_kopecks"]) == (
        "Лендинг Елены",
        "active",  # a project without status counts as active
        5_000_000,
    )
    assert elena["id"] == str(extra["elena_project"])


async def test_get_projects_filters_and_one_project_detail(env: Env) -> None:
    _, seed, extra = await seeded(env)
    archived = await call(env, "get_projects", {"include_archived": True, "status": ["cancelled"]})
    assert [p["title"] for p in archived["projects"]] == ["Старый заказ"]
    assert (await call(env, "get_projects", {"query": "ЛЕНДИНГ"}))["count"] == 1
    assert (await call(env, "get_projects", {"limit": 1}))["truncated"] is True

    one = (await call(env, "get_projects", {"project_id": str(seed.project)}))["projects"][0]
    assert one["base_received_kopecks"] == 6_000_000
    assert one["base_remaining_kopecks"] == 4_000_000
    rows = {r["title"]: r for r in one["change_requests"]}
    assert rows["Корзина"]["received_kopecks"] == 3_000_000
    assert rows["Корзина"]["remaining_kopecks"] == 0
    assert rows["Фильтры"]["remaining_kopecks"] == 2_000_000
    assert rows["Чат"]["status"] == "cancelled"
    assert rows["Чат"]["remaining_kopecks"] == 0
    # an archived project is found by its id even without include_archived
    old = await call(env, "get_projects", {"project_id": str(extra["old"])})
    assert old["count"] == 1


async def test_get_projects_shows_the_hourly_rate(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok(
        [
            phone.op(
                "projects",
                uuid7(),
                fields=project_fields(phone, pay_type="hourly", hourly_rate=150_000),
            )
        ]
    )
    (project,) = (await call(env, "get_projects", {}))["projects"]
    assert project["pay_type"] == "hourly"
    assert project["hourly_rate_kopecks"] == 150_000
    assert project["total_kopecks"] == 0
    assert project["paid_percent"] == 0.0


async def test_get_receivables_per_customer_and_total(env: Env) -> None:
    _, seed, extra = await seeded(env)
    result = await call(env, "get_receivables", {})
    assert result["currency"] == "RUB"
    assert result["total_kopecks"] == 11_000_000  # the cancelled project is not a debt
    roma, elena = result["clients"]  # the bigger debt first
    assert (roma["client"], roma["remaining_kopecks"], roma["client_id"]) == (
        "Рома",
        6_000_000,
        str(seed.roma),
    )
    assert roma["projects"][0]["title"] == "Сайт Ромы"
    assert (elena["client"], elena["remaining_kopecks"]) == ("Елена", 5_000_000)
    assert elena["client_id"] == str(extra["elena"])

    only = await call(env, "get_receivables", {"client": "рОм"})
    assert [c["client"] for c in only["clients"]] == ["Рома"]
    assert only["total_kopecks"] == 11_000_000  # the overall total ignores the filter
    assert (await call(env, "get_receivables", {"client": "никто"}))["clients"] == []


async def test_get_receivables_is_empty_without_projects(env: Env) -> None:
    await env.login()
    result = await call(env, "get_receivables", {})
    assert result["total_kopecks"] == 0
    assert result["clients"] == []


async def test_get_work_hours_by_fact_and_by_accrual(env: Env) -> None:
    phone, seed, _ = await seeded(env)
    await phone.push_ok(
        [
            phone.op(
                "time_entries",
                uuid7(),
                fields=entry_fields(
                    phone,
                    seed.project,
                    source="timer",
                    ended_at=None,
                    started_at="2026-10-07T07:00:00Z",
                ),
            )
        ]
    )
    october = await call(
        env, "get_work_hours", {"from_date": "2026-10-01", "to_date": "2026-10-31"}
    )
    assert october["period"] == {"from": "2026-10-01", "to": "2026-10-31"}
    assert october["billable_seconds"] == 7200  # the 3 h entry is not billable, the timer runs
    assert october["billable_hours_text"] == "2 ч 00 мин"
    assert october["received_kopecks"] == 7_000_000
    assert october["per_hour_fact_kopecks"] == 3_500_000
    assert october["accrued_kopecks"] == 3_000_000
    assert october["per_hour_accrued_kopecks"] == 1_500_000
    assert october["per_hour_fact_text"] == "35 000 ₽"
    assert october["running_timers"] == 1
    assert [p["title"] for p in october["projects"]] == ["Сайт Ромы"]

    november = await call(
        env,
        "get_work_hours",
        {"from_date": "2026-11-01", "to_date": "2026-11-30", "project": "сайт"},
    )
    assert november["received_kopecks"] == 2_000_000
    assert november["billable_seconds"] == 0
    assert november["per_hour_fact_kopecks"] is None  # no hours, no rate
    assert november["per_hour_fact_text"] is None

    nothing = await call(
        env,
        "get_work_hours",
        {"from_date": "2026-10-01", "to_date": "2026-10-31", "project": str(uuid7())},
    )
    assert nothing["projects"] == []
    assert nothing["billable_seconds"] == 0


async def test_get_work_hours_validates_the_period(env: Env) -> None:
    spec = TOOLS.get("get_work_hours")
    assert spec is not None
    for args in (
        {"from_date": "2026-10-05", "to_date": "2026-10-01"},
        {"from_date": "2026-02-30", "to_date": "2026-03-01"},
        {"from_date": "2025-01-01", "to_date": "2026-01-02"},
        {"from_date": "2026-10-01"},
        {"from_date": "1.10.2026", "to_date": "2026-10-31"},
    ):
        with pytest.raises(ToolArgumentError):
            spec.parse(args)
    spec.parse({"from_date": "2025-01-01", "to_date": "2026-01-01"})  # 366 days inclusive


async def test_a_huge_result_is_cut_to_fit(env: Env) -> None:
    phone = await env.login()
    ops = [
        phone.op(
            "projects", uuid7(), fields=project_fields(phone, title=f"Проект {i} " + "я" * 150)
        )
        for i in range(100)
    ]
    for start in range(0, 100, 50):
        await phone.push_ok(ops[start : start + 50])
    result = await call(env, "get_projects", {"limit": 100})
    assert result["truncated"] is True
    assert 0 < result["count"] < 100
