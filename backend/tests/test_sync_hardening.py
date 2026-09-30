"""Review fixes in the merge engine: cascade tombstones (3.5) and the trash window (3.8)."""

import uuid
from datetime import timedelta
from typing import Any

from asyncpg.pgproto.pgproto import UUID as PgUuid  # noqa: N811 - the driver's own type

from tasker.ids import uuid7
from tasker.sync.engine import _same
from tasker.sync.purge import purge_tombstones
from tasker.sync.user_settings import settings_id
from tests.api_support import DeviceClient, Env
from tests.test_purge import wake
from tests.test_sync_merge import project, two_devices
from tests.test_sync_push import create_setting

DAY_MS = 86_400_000


async def parent_and_child(a: DeviceClient) -> tuple[Any, Any]:
    pid, create = project(a)
    tid = uuid7()
    child = a.op(
        "test_tasks",
        tid,
        fields={"project_id": str(pid), "title": "t", "created_at": a.created()},
    )
    await a.push_ok([create, child])  # versions 1, 2
    return pid, tid


async def deleted_at(dc: DeviceClient, table: str, row_id: Any) -> str | None:
    found = {c["id"]: c["row"] for c in (await dc.pull_ok())["changes"] if c["table"] == table}
    value: str | None = found[str(row_id)]["deleted_at"]
    return value


# ------------------------------------------------------------------ MINOR-3


async def test_explicit_child_delete_over_a_cascade_tombstone_survives_parent_restore(
    tree_env: Env,
) -> None:
    a, b = await two_devices(tree_env)
    pid, tid = await parent_and_child(a)
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(10))])  # v3, cascade v4
    assert await deleted_at(a, "test_tasks", tid) is not None
    # A had not seen the deletion and deletes the task itself, later than the cascade.
    (explicit,) = await a.push_ok([a.op("test_tasks", tid, "delete", base=2, hlc=a.at(20))])
    assert explicit["status"] == "applied"
    (restored,) = await b.push_ok(
        [b.op("test_projects", pid, fields={"deleted_at": None}, base=3, hlc=b.at(30))]
    )
    assert restored["status"] == "applied"
    assert await deleted_at(a, "test_projects", pid) is None  # the parent is back
    assert await deleted_at(a, "test_tasks", tid) is not None  # the task stays in the trash


async def test_explicit_delete_with_an_older_clock_still_detaches_the_child(
    tree_env: Env,
) -> None:
    a, b = await two_devices(tree_env)
    pid, tid = await parent_and_child(a)
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(50))])
    await a.push_ok([a.op("test_tasks", tid, "delete", base=2, hlc=a.at(20))])  # older than 50
    await b.push_ok([b.op("test_projects", pid, fields={"deleted_at": None}, base=3, hlc=b.at(60))])
    assert await deleted_at(a, "test_tasks", tid) is not None


async def test_child_deleted_by_cascade_only_is_still_restored_with_its_parent(
    tree_env: Env,
) -> None:
    a, b = await two_devices(tree_env)
    pid, tid = await parent_and_child(a)
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(10))])
    await b.push_ok([b.op("test_projects", pid, fields={"deleted_at": None}, base=3, hlc=b.at(30))])
    assert await deleted_at(a, "test_tasks", tid) is None


async def test_a_restored_explicitly_deleted_child_comes_back_on_its_own(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, tid = await parent_and_child(a)
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(10))])
    await a.push_ok([a.op("test_tasks", tid, "delete", base=2, hlc=a.at(20))])
    await b.push_ok([b.op("test_projects", pid, fields={"deleted_at": None}, base=3, hlc=b.at(30))])
    (result,) = await a.push_ok(
        [a.op("test_tasks", tid, fields={"deleted_at": None}, base=5, hlc=a.at(40))]
    )
    assert result["status"] == "applied"
    assert await deleted_at(a, "test_tasks", tid) is None


# ------------------------------------------------------------------ MINOR-8


async def purge(env: Env) -> int:
    return await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())


async def test_delete_made_offline_for_35_days_stays_in_the_trash_30_days_from_arrival(
    env: Env,
) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    offline_hlc = phone.at(-35 * DAY_MS)
    (result,) = await phone.push_ok(
        [phone.op("user_settings", settings_id("ui.theme"), "delete", base=1, hlc=offline_hlc)]
    )
    assert result["status"] == "applied"
    arrived = env.clock.now()
    (change,) = (await phone.pull_ok())["changes"]
    assert change["row"]["deleted_at"] == arrived.isoformat().replace("+00:00", "Z")
    await phone.pull_ok(2)
    await wake(env, phone, days=29, hours=23)
    await phone.pull_ok(2)
    assert await purge(env) == 0  # still inside the 30 days that count from arrival
    await wake(env, phone, hours=1, seconds=1)
    await phone.pull_ok(2)
    assert await purge(env) == 1


async def test_cascaded_children_share_the_arrival_time_of_the_parent_delete(
    tree_env: Env,
) -> None:
    a, b = await two_devices(tree_env)
    pid, tid = await parent_and_child(a)
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(-40 * DAY_MS))])
    parent = await deleted_at(a, "test_projects", pid)
    assert parent == tree_env.clock.now().isoformat().replace("+00:00", "Z")
    assert await deleted_at(a, "test_tasks", tid) == parent


async def test_a_deletion_stamped_in_the_near_future_keeps_its_own_time(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    ahead = phone.at(5 * 60 * 1000)  # a clock 5 minutes fast, within MAX_FUTURE_DRIFT
    await phone.push_ok(
        [phone.op("user_settings", settings_id("ui.theme"), "delete", base=1, hlc=ahead)]
    )
    (change,) = (await phone.pull_ok())["changes"]
    expected = env.clock.now() + timedelta(minutes=5)
    assert change["row"]["deleted_at"] == expected.isoformat().replace("+00:00", "Z")


# ------------------------------------------------------------------ value-based equality


def link(dc: DeviceClient, owner: Any, **fields: Any) -> tuple[Any, dict[str, Any]]:
    row_id = uuid7()
    body = {"owner_id": str(owner), "created_at": dc.created(), **fields}
    return row_id, dc.op("test_links", row_id, fields=body)


async def test_resent_unchanged_immutable_uuid_is_not_a_change(tree_env: Env) -> None:
    """The driver returns its own UUID class; equality must still be by value."""
    a, _ = await two_devices(tree_env)
    pid, create = project(a)
    fixed = uuid7()
    row_id, made = link(a, pid, fixed_ref=str(fixed))
    await a.push_ok([create, made])
    (again,) = await a.push_ok(
        [
            a.op(
                "test_links",
                row_id,
                fields={"owner_id": str(pid), "fixed_ref": str(fixed)},
                base=2,
                hlc=a.at(10),
            )
        ]
    )
    assert (again["status"], again["conflicts"]) == ("applied", 0)
    other = uuid7()
    (changed,) = await a.push_ok(
        [a.op("test_links", row_id, fields={"fixed_ref": str(other)}, base=3, hlc=a.at(20))]
    )
    assert (changed["status"], changed["code"]) == ("rejected", "immutable_field")
    moved = await a.push_ok(
        [a.op("test_links", row_id, fields={"owner_id": str(uuid7())}, base=3, hlc=a.at(30))]
    )
    assert moved[0]["code"] == "immutable_field"


async def test_same_uuid_written_concurrently_is_not_a_conflict(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    shared = uuid7()
    row_id, made = link(a, pid)
    await a.push_ok([create, made])
    (first,) = await a.push_ok(
        [a.op("test_links", row_id, fields={"ref": str(shared)}, base=2, hlc=a.at(10))]
    )
    (second,) = await b.push_ok(  # B never saw A's write (base 2) and writes the same value
        [b.op("test_links", row_id, fields={"ref": str(shared)}, base=2, hlc=b.at(20))]
    )
    assert (first["conflicts"], second["conflicts"]) == (0, 0)
    assert await tree_env.scalar("SELECT count(*) FROM sync_conflicts") == 0


async def test_same_instant_in_another_offset_is_not_a_change(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    row_id, made = link(a, pid, at="2026-10-01T12:00:00+03:00")
    await a.push_ok([create, made])
    (result,) = await b.push_ok(
        [b.op("test_links", row_id, fields={"at": "2026-10-01T09:00:00Z"}, base=0, hlc=b.at(10))]
    )
    assert result["conflicts"] == 0


def test_same_is_by_value_but_keeps_types_apart() -> None:
    plain = uuid.uuid4()
    assert _same(plain, PgUuid(str(plain)))
    assert _same(PgUuid(str(plain)), plain)
    assert not _same(plain, uuid.uuid4())
    assert not _same(True, 1)
    assert not _same("1", 1)
    assert _same({"b": 1, "a": [1, 2]}, {"a": [1, 2], "b": 1})
    assert not _same({"a": 1}, {"a": True})
    assert _same(None, None)
    assert not _same(None, "x")


# ------------------------------------------------------------------ touch carries its clock


async def test_touch_raises_the_rows_updated_at_so_pull_shows_the_newest_clock(env: Env) -> None:
    """Same value, newer HLC: the field's clock moves, so the row's ``updated_at`` must too."""
    a, b = await env.login("A"), await env.login("B")
    await a.push_ok([create_setting(a, value="dark", hlc=a.at(0))])
    newer = b.at(500)
    (result,) = await b.push_ok(
        [
            b.op(
                "user_settings",
                settings_id("ui.theme"),
                fields={"value": "dark"},
                base=1,
                hlc=newer,
            )
        ]
    )
    assert (result["status"], result["server_version"], result["conflicts"]) == ("applied", 2, 0)
    (change,) = (await a.pull_ok(1))["changes"]
    assert change["row"]["updated_at"] == newer
    assert change["row"]["origin_device_id"] == str(b.device_id)
    assert change["row"]["value"] == "dark"
    # Nothing else changed: the value and the creation time are as before.
    assert change["row"]["created_at"].endswith("Z")


async def test_a_touch_with_an_older_clock_leaves_updated_at_alone(env: Env) -> None:
    a, b = await env.login("A"), await env.login("B")
    first = a.at(500)
    await a.push_ok([create_setting(a, value="dark", hlc=first)])
    (result,) = await b.push_ok(
        [
            b.op(
                "user_settings",
                settings_id("ui.theme"),
                fields={"value": "dark"},
                base=1,
                hlc=b.at(100),
            )
        ]
    )
    assert result["status"] == "applied"
    (change,) = (await a.pull_ok(1))["changes"]
    assert change["row"]["updated_at"] == first  # the older clock changed nothing to carry


async def test_writes_after_seeing_a_touched_row_beat_its_field_clock(env: Env) -> None:
    """The HLC a device gets by receiving the pulled row is above the field's own clock."""
    a, b = await env.login("A"), await env.login("B")
    await a.push_ok([create_setting(a, value="dark", hlc=a.at(0))])
    await b.push_ok(
        [
            b.op(
                "user_settings",
                settings_id("ui.theme"),
                fields={"value": "dark"},
                base=1,
                hlc=b.at(5000),
            )
        ]
    )
    (change,) = (await a.pull_ok(1))["changes"]
    a.hlc.receive(change["row"]["updated_at"], env.clock.ms)  # what the client algorithm does
    stamp = a.hlc.send(env.clock.ms)
    assert stamp > b.at(5000)
    (result,) = await a.push_ok(
        [
            a.op(
                "user_settings",
                settings_id("ui.theme"),
                fields={"value": "light"},
                base=2,
                hlc=stamp,
            )
        ]
    )
    assert result["conflicts"] == 0  # A's edit is newest and not concurrent with anything unseen
    (final,) = (await b.pull_ok(2))["changes"]
    assert final["row"]["value"] == "light"


async def test_repeated_delete_with_a_newer_clock_moves_updated_at(env: Env) -> None:
    a, b = await env.login("A"), await env.login("B")
    await a.push_ok([create_setting(a)])
    await a.push_ok(
        [a.op("user_settings", settings_id("ui.theme"), "delete", base=1, hlc=a.at(10))]
    )
    newer = b.at(900)
    await b.push_ok([b.op("user_settings", settings_id("ui.theme"), "delete", base=2, hlc=newer)])
    (change,) = (await a.pull_ok(2))["changes"]
    assert change["row"]["updated_at"] == newer
    assert change["row"]["deleted_at"] is not None
