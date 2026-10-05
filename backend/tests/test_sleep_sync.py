"""Stage 8 tables through the real sync engine: round trip, trash, offline merges, the purge."""

from typing import Any

from tasker.sleep import reference as ref
from tasker.sleep.tables import SLEEP_TABLES
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env
from tests.sleep_support import (
    checkin_fields,
    checkin_row_id,
    plan_fields,
    plan_row_id,
    sleep_fields,
    sleep_row_id,
)
from tests.test_calendar_sync import deleted, pull_rows

NAMES = ("sleep_entries", "daily_plans", "evening_checkins")


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def test_registry_has_the_sleep_tables_without_parents() -> None:
    assert [spec.name for spec in SLEEP_TABLES] == list(NAMES)
    registry = build_registry()
    assert all(registry.get(name) is not None for name in NAMES)
    assert all(not spec.parents() for spec in SLEEP_TABLES)


async def seed(dc: DeviceClient) -> dict[str, Any]:
    night, plan, checkin = sleep_fields(dc), plan_fields(dc), checkin_fields(dc, rating=4)
    results = await dc.push_ok(
        [
            dc.op("sleep_entries", sleep_row_id(night), fields=night),
            dc.op("daily_plans", plan_row_id(plan), fields=plan),
            dc.op("evening_checkins", checkin_row_id(checkin), fields=checkin),
        ]
    )
    assert [r["status"] for r in results] == ["applied"] * 3
    return {"night": night, "plan": plan, "checkin": checkin}


async def test_rows_round_trip_to_a_second_device(env: Env) -> None:
    phone = await env.login()
    rows = await seed(phone)
    pc = await env.login("PC")
    pulled = await pull_rows(pc)
    night = pulled["sleep_entries"][str(sleep_row_id(rows["night"]))]
    assert night["date"] == "2026-10-02"
    assert night["wake_tz"] == "Europe/Moscow"
    assert night["bed_tz"] is None
    # the pulled row feeds the reference rules: a 7 h 30 min night, bed at 23:30 on the wall clock
    view = ref.entry_view({k: night[k] for k in ("bed_at", "wake_at", "bed_tz", "wake_tz")})
    assert view == {
        "date": "2026-10-02",
        "minutes": 450,
        "bed_local": "23:30",
        "wake_local": "07:00",
    }
    assert pulled["evening_checkins"][str(checkin_row_id(rows["checkin"]))]["rating"] == 4
    assert pulled["daily_plans"][str(plan_row_id(rows["plan"]))]["task_ids"] == []


async def test_two_devices_writing_the_same_night_make_one_row(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    first = sleep_fields(phone, source="morning_notification", quality=3)
    row = sleep_row_id(first)
    await phone.push_ok([phone.op("sleep_entries", row, fields=first)])
    second = sleep_fields(pc, minutes=470)
    (result,) = await pc.push_ok([pc.op("sleep_entries", row, fields=second)])
    assert result["status"] == "applied"
    assert await env.scalar("SELECT count(*) FROM sleep_entries") == 1


async def test_note_and_quality_edited_on_two_devices_merge_field_by_field(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    night = sleep_fields(phone)
    row = sleep_row_id(night)
    await phone.push_ok([phone.op("sleep_entries", row, fields=night)])
    seen = await head(phone)
    await phone.push_ok([phone.op("sleep_entries", row, fields={"note": "поздно лёг"}, base=seen)])
    await pc.push_ok([pc.op("sleep_entries", row, fields={"quality": 2}, base=seen)])
    merged = (await pull_rows(phone))["sleep_entries"][str(row)]
    assert (merged["note"], merged["quality"]) == ("поздно лёг", 2)


async def test_delete_restore_and_purge_of_a_day(env: Env) -> None:
    phone = await env.login()
    rows = await seed(phone)
    plan = plan_row_id(rows["plan"])
    await phone.push_ok([phone.op("daily_plans", plan, "delete", base=await head(phone))])
    assert await deleted(env, "daily_plans") == 1
    await phone.push_ok(
        [phone.op("daily_plans", plan, fields={"deleted_at": None}, base=await head(phone))]
    )
    assert await deleted(env, "daily_plans") == 0
    for name, row in (
        ("sleep_entries", sleep_row_id(rows["night"])),
        ("evening_checkins", checkin_row_id(rows["checkin"])),
    ):
        await phone.push_ok([phone.op(name, row, "delete", base=await head(phone))])
    top = await head(phone)
    env.clock.advance(days=31)
    await phone.refresh()
    await phone.pull_ok(top)
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged == 2
    assert await env.scalar("SELECT count(*) FROM sleep_entries") == 0
    assert await env.scalar("SELECT count(*) FROM daily_plans") == 1  # a restored row stays


async def test_a_deleted_day_can_be_written_again_with_the_same_id(env: Env) -> None:
    phone = await env.login()
    rows = await seed(phone)
    row = sleep_row_id(rows["night"])
    await phone.push_ok([phone.op("sleep_entries", row, "delete", base=await head(phone))])
    again = sleep_fields(phone, minutes=400)
    (result,) = await phone.push_ok([phone.op("sleep_entries", row, fields=again)])
    assert result["status"] == "applied"
