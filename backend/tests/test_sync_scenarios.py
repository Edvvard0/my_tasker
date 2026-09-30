"""Scenario: the phone is offline for three days while the PC keeps working, then they meet."""

import contextlib
import uuid
from typing import Any

import sqlalchemy as sa

from tasker.ids import uuid7
from tests.api_support import Env
from tests.sync_sim.client import SimClient
from tests.sync_sim.server import FlakyServer, register_device, server_rows
from tests.sync_tables import build_test_registry


async def device(env: Env) -> SimClient:
    client = SimClient(uuid7(), lambda: env.clock.ms)
    await register_device(env.sessionmaker, client.device_id, env.clock.now())
    return client


async def conflicts(env: Env) -> list[Any]:
    async with env.sessionmaker() as session:
        rows = await session.execute(
            sa.text("SELECT table_name, row_id, field, kind, losing_value FROM sync_conflicts")
        )
        return list(rows)


async def test_phone_offline_three_days_then_meeting(tree_env: Env) -> None:
    env = tree_env
    server = FlakyServer(env.sessionmaker, build_test_registry(), env.clock)
    phone, pc = await device(env), await device(env)
    project, t1, t2, t3 = (str(uuid7()) for _ in range(4))

    # Day 0: both devices know the same plan.
    pc.create("test_projects", project, {"title": "Plan", "budget": 10})
    for task, title in ((t1, "one"), (t2, "two"), (t3, "three")):
        pc.create("test_tasks", task, {"project_id": project, "title": title})
    await pc.sync(server)
    await phone.sync(server)
    assert len(phone.rows) == 4

    # Day 1: the phone loses connectivity and keeps working.
    env.clock.advance(days=1)
    phone.edit("test_projects", project, {"title": "Phone plan"})
    phone.edit("test_tasks", t1, {"title": "Phone one"})
    phone.delete("test_tasks", t2)
    phone.create("test_tasks", t4 := str(uuid7()), {"project_id": project, "title": "four"})
    server.faults = ["drop_request"] * 3
    for _ in range(3):
        with contextlib.suppress(Exception):  # the network is down
            await phone.sync(server)
    assert phone.outbox

    # Day 2: the PC edits the same things and syncs several times.
    env.clock.advance(days=1)
    pc.edit("test_projects", project, {"budget": 20})
    pc.edit("test_tasks", t1, {"title": "PC one"})
    pc.edit("test_tasks", t2, {"title": "PC two"})
    pc.delete("test_tasks", t3)
    await pc.sync(server)
    await pc.sync(server)

    # Day 3: one more offline edit on the phone, then the devices meet.
    env.clock.advance(days=1)
    phone.edit("test_tasks", t3, {"note": "phone note"})
    server.faults = []
    await phone.sync(server)
    await pc.sync(server)
    await phone.sync(server)

    rows = await server_rows(env.sessionmaker, server.registry)
    assert phone.rows == pc.rows == rows
    assert not phone.outbox
    assert not phone.rejected
    by_id = {key[1]: row for key, row in rows.items()}
    # Disjoint fields of the project merge without a conflict.
    assert (by_id[project]["title"], by_id[project]["budget"]) == ("Phone plan", 20)
    # Same field: the PC edited later, so it wins and the phone's value is in the log.
    assert by_id[t1]["title"] == "PC one"
    # The phone deleted t2 on day 1, the PC edited it on day 2: the newer edit keeps it alive.
    assert by_id[t2]["deleted_at"] is None
    assert by_id[t2]["title"] == "PC two"
    # The PC deleted t3 on day 2, the phone edited it on day 3: the newer edit resurrects it.
    assert by_id[t3]["deleted_at"] is None
    assert by_id[t3]["note"] == "phone note"
    assert by_id[t4]["title"] == "four"

    logged = {(c.row_id, c.field, c.kind) for c in await conflicts(env)}
    assert logged == {
        (uuid.UUID(t1), "title", "field"),
        (uuid.UUID(t2), "deleted_at", "resurrected"),
        (uuid.UUID(t3), "deleted_at", "resurrected"),
    }
    values = {c.row_id: c.losing_value for c in await conflicts(env)}
    assert values[uuid.UUID(t1)] == "Phone one"
