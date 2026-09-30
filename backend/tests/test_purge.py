import uuid
from datetime import timedelta
from typing import Any

import pytest

from tasker.sync.modules import build_registry
from tasker.sync.purge import cleanup_records, purge_tombstones
from tasker.sync.user_settings import settings_id
from tests.api_support import DeviceClient, Env
from tests.sync_sim.client import SimClient
from tests.sync_sim.server import FlakyServer, ResyncRequiredError
from tests.sync_tables import build_test_registry
from tests.test_auth_api import error_code
from tests.test_sync_merge import project
from tests.test_sync_push import create_setting


async def purge(env: Env) -> int:
    return await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())


async def count(env: Env, table: str = "user_settings") -> int:
    return int(await env.scalar(f"SELECT count(*) FROM {table}"))  # noqa: S608


async def delete_setting(dc: DeviceClient, key: str, base: int) -> dict[str, Any]:
    (result,) = await dc.push_ok([dc.op("user_settings", settings_id(key), "delete", base=base)])
    return result


async def wake(env: Env, *devices: DeviceClient, **advance: float) -> None:
    """Move the fake clock and re-authenticate the devices that keep working."""
    env.clock.advance(**advance)
    for device in devices:
        await device.refresh()


async def caught_up(dc: DeviceClient) -> None:
    await dc.pull_ok(0)
    page = await dc.pull_ok(0)
    await dc.pull_ok(page["head_version"])


async def test_young_tombstones_are_kept(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    await delete_setting(phone, "ui.theme", 1)
    await caught_up(phone)
    await wake(env, phone, days=29, hours=23)
    assert await purge(env) == 0
    assert await count(env) == 1


async def test_old_tombstone_is_purged_once_every_active_device_passed_it(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone, "keep"), create_setting(phone, "gone")])
    await delete_setting(phone, "gone", 2)  # version 3
    await caught_up(phone)
    await wake(env, phone, days=30, seconds=1)
    await phone.pull_ok(3)  # stay active
    assert await purge(env) == 1
    assert await count(env) == 1
    assert await env.scalar("SELECT key FROM user_settings") == "keep"
    assert await env.scalar("SELECT purge_watermark FROM sync_state") == 3
    assert await purge(env) == 0  # nothing left to do


async def test_a_lagging_active_device_blocks_the_purge(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    await phone.push_ok([create_setting(phone)])
    await delete_setting(phone, "ui.theme", 1)  # version 2
    await phone.pull_ok(2)
    await pc.pull_ok(1)  # PC has not seen the deletion yet
    await wake(env, phone, pc, days=31)
    await phone.pull_ok(2)
    await pc.pull_ok(1)  # still lagging, but active
    assert await purge(env) == 0
    await pc.pull_ok(2)
    assert await purge(env) == 1
    assert await env.scalar("SELECT purge_watermark FROM sync_state") == 2


async def test_silent_and_revoked_devices_do_not_block(env: Env) -> None:
    phone = await env.login("Phone")
    silent = await env.login("Silent")
    revoked = await env.login("Revoked")
    await phone.push_ok([create_setting(phone)])
    await delete_setting(phone, "ui.theme", 1)
    await wake(env, phone, revoked, days=20)
    await phone.pull_ok(2)  # keeps the phone active; the other two stay at cursor 0
    await revoked.post("/auth/logout")
    await wake(env, phone, days=11)
    await phone.pull_ok(2)
    assert await purge(env) == 1  # silent: last seen 31 days ago; revoked: logged out
    del silent


async def test_purge_with_no_devices_at_all(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    await delete_setting(phone, "ui.theme", 1)
    await env.execute("DELETE FROM devices")
    env.clock.advance(days=31)
    assert await purge(env) == 1


async def test_a_lagging_device_gets_the_full_resync_signal_after_a_purge(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    await phone.push_ok([create_setting(phone, "a"), create_setting(phone, "b")])
    await pc.pull_ok(0)
    await pc.pull_ok(2)
    await delete_setting(phone, "a", 1)  # version 3
    await phone.pull_ok(3)
    await wake(env, phone, days=31)  # the PC never came back: it is inactive now
    await phone.pull_ok(3)
    assert await purge(env) == 1

    await pc.refresh()
    response = await pc.pull(2)
    assert (response.status_code, error_code(response)) == (410, "resync_required")
    details = response.json()["error"]["details"]
    assert (details["purge_watermark"], details["reason"]) == (3, "purged")
    fresh = await pc.pull_ok(0)  # the full resync
    assert [c["row"]["key"] for c in fresh["changes"]] == ["b"]
    assert fresh["purge_watermark"] == 3
    assert (await pc.pull(fresh["next_since"])).status_code == 200
    # The device that kept up is never asked to resync.
    assert (await phone.pull(3)).status_code == 200


async def test_purge_removes_children_before_parents(tree_env: Env) -> None:
    env = tree_env
    a = await env.login("A")
    pid, create = project(a)
    tid = uuid.uuid4()
    task = a.op(
        "test_tasks", tid, fields={"project_id": str(pid), "title": "t", "created_at": a.created()}
    )
    task["id"] = str(_uuid7())
    await a.push_ok([create, task])  # versions 1, 2
    await a.push_ok([a.op("test_projects", pid, "delete", base=1)])  # project 3, task 4
    await a.pull_ok(4)
    await wake(env, a, days=31)
    await a.pull_ok(4)
    assert await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now()) == 2
    assert await count(env, "test_tasks") == await count(env, "test_projects") == 0
    assert await env.scalar("SELECT purge_watermark FROM sync_state") == 4


async def test_parent_survives_while_a_child_is_still_needed(tree_env: Env) -> None:
    env = tree_env
    a = await env.login("A")
    pid, create = project(a)
    task = a.op(
        "test_tasks",
        _uuid7(),
        fields={"project_id": str(pid), "title": "t", "created_at": a.created()},
    )
    await a.push_ok([create, task])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1)])  # project 3, task 4
    await a.pull_ok(3)  # the device has passed the parent's tombstone but not the child's
    await wake(env, a, days=31)
    await a.pull_ok(3)
    assert await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now()) == 0
    assert await count(env, "test_projects") == 1
    await a.pull_ok(4)
    assert await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now()) == 2


def _uuid7() -> uuid.UUID:
    from tasker.ids import uuid7  # noqa: PLC0415

    return uuid7()


async def test_cleanup_trims_old_journal_conflicts_and_login_failures(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    await env.execute(
        "INSERT INTO sync_conflicts (id, created_at, table_name, row_id, field, kind)"
        " VALUES (gen_random_uuid(), :t, 'x', gen_random_uuid(), 'f', 'field')",
        t=env.clock.now(),
    )
    await env.execute(
        "INSERT INTO login_failures (scope, key, failures, last_failure_at)"
        " VALUES ('ip', 'k', 1, :t)",
        t=env.clock.now(),
    )
    env.clock.advance(days=59)
    await cleanup_records(env.sessionmaker, env.clock.now())
    assert (await count(env, "sync_ops"), await count(env, "sync_conflicts")) == (1, 1)
    env.clock.advance(days=2)  # 61 days: the journal goes
    await cleanup_records(env.sessionmaker, env.clock.now())
    assert (await count(env, "sync_ops"), await count(env, "sync_conflicts")) == (0, 1)
    assert await count(env, "login_failures") == 0
    env.clock.advance(days=120)  # 181 days: the conflict log goes
    await cleanup_records(env.sessionmaker, env.clock.now())
    assert await count(env, "sync_conflicts") == 0


@pytest.mark.parametrize("rejected", [True, False])
async def test_returning_device_resyncs_and_keeps_its_unsent_work(
    tree_env: Env, rejected: bool
) -> None:
    """Spec 5.3: pull from 0, replace the store, lay the outbox back on top."""
    env = tree_env
    await env.login("Phone")
    await env.login("PC")
    server = FlakyServer(env.sessionmaker, build_test_registry(), env.clock)
    phone = SimClient(
        uuid.UUID(str(await env.scalar("SELECT id FROM devices WHERE name='Phone'"))),
        lambda: env.clock.ms,
    )
    pc = SimClient(
        uuid.UUID(str(await env.scalar("SELECT id FROM devices WHERE name='PC'"))),
        lambda: env.clock.ms,
    )
    keep, gone = str(_uuid7()), str(_uuid7())
    pc.create("test_projects", keep, {"title": "keep"})
    pc.create("test_projects", gone, {"title": "gone"})
    await pc.sync(server)
    await phone.sync(server)
    assert {k[1] for k in phone.rows} == {keep, gone}

    env.clock.advance(days=1)
    pc.delete("test_projects", gone)  # the phone is offline from now on
    await pc.sync(server)
    env.clock.advance(days=31)
    await pc.sync(server)  # keeps the PC active
    await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert await count(env, "test_projects") == 1

    phone.edit("test_projects", keep, {"title": "phone edit"})
    if rejected:
        phone.edit("test_projects", gone, {"title": "edit of a purged row"})
    server.faults = ["drop_request"]
    with pytest.raises(Exception, match="request lost"):
        await phone.push(server)
    with pytest.raises(ResyncRequiredError):
        await phone.pull(server)
    await phone.full_resync(server)
    assert ("test_projects", gone) not in phone.rows
    assert phone.rows[("test_projects", keep)]["title"] == "phone edit"  # outbox laid on top
    await phone.sync(server)
    await pc.sync(server)
    assert pc.rows[("test_projects", keep)]["title"] == "phone edit"
    assert [code for _, code in phone.rejected] == (["missing_fields"] if rejected else [])
    assert ("test_projects", gone) not in phone.rows


def test_helper_types() -> None:
    assert timedelta(days=30).days == 30
    assert build_registry().get("user_settings") is not None
