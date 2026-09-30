"""Property test on the real Stage 2 registry: 2-3 simulated devices, edits, deletes, faults.

The generic sync properties are covered by ``test_sync_property.py`` on test tables; this one
drives the calendar/task tables (validators, deterministic ids, cascades) through the same
simulated clients and checks that all replicas converge without a single rejected operation.
"""

import asyncio
import contextlib
from typing import Any

import pytest
import sqlalchemy as sa
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.calendar import ids
from tasker.calendar.tables import CALENDAR_TABLES
from tasker.db import create_sessionmaker
from tasker.ids import uuid7
from tasker.sync.modules import build_registry
from tests.api_support import FakeClock
from tests.conftest import run_async
from tests.sync_sim.client import NetworkError, SimClient
from tests.sync_sim.server import FlakyServer, register_device, server_rows

FAULTS = st.sampled_from([None, None, None, "drop_request", "drop_response"])
ACTION = st.one_of(
    st.tuples(st.just("edit"), st.integers(0, 2), st.integers(0, 9), st.integers(0, 5)),
    st.tuples(st.just("edit"), st.integers(0, 2), st.integers(0, 9), st.integers(0, 5)),
    st.tuples(st.just("subtask"), st.integers(0, 2), st.integers(0, 9)),
    st.tuples(st.just("tag"), st.integers(0, 2), st.integers(0, 9), st.integers(0, 2)),
    st.tuples(st.just("delete"), st.integers(0, 2), st.integers(0, 15)),
    st.tuples(st.just("restore"), st.integers(0, 2), st.integers(0, 15)),
    st.tuples(st.just("sync"), st.integers(0, 2), st.lists(FAULTS, max_size=3)),
    st.tuples(st.just("push_only"), st.integers(0, 2), st.lists(FAULTS, max_size=2)),
    st.tuples(st.just("tick"), st.integers(1, 2_000)),
)
TAGS = ("работа", "дом", "срочно")
EDITS: list[dict[str, Any]] = [
    {"title": "a"},
    {"title": "b"},
    {"status": "done"},
    {"status": "in_progress"},
    {"priority": 3},
    {"priority": None},
]
TABLES = [spec.name for spec in reversed(CALENDAR_TABLES)]


class World:
    def __init__(self, url: str, skews: list[int]) -> None:
        self.engine = create_async_engine(url)
        self.sessionmaker = create_sessionmaker(self.engine)
        self.registry = build_registry()
        self.clock = FakeClock()
        self.server = FlakyServer(self.sessionmaker, self.registry, self.clock)
        self.clients = [
            SimClient(uuid7(), (lambda skew=skew: self.clock.ms + skew)) for skew in skews
        ]

    async def reset(self) -> None:
        async with self.sessionmaker() as session, session.begin():
            for table in [*TABLES, "user_settings", "sync_ops", "sync_conflicts", "devices"]:
                await session.execute(sa.text(f"DELETE FROM {table}"))  # noqa: S608
            await session.execute(
                sa.text("UPDATE sync_state SET head_version=0, purge_watermark=0")
            )
        for client in self.clients:
            await register_device(self.sessionmaker, client.device_id, self.clock.now())

    async def seed(self) -> None:
        first = self.clients[0]
        for tag in TAGS:
            first.create("tags", str(ids.tag_id(tag)), {"name": tag})
        for title in ("x", "y"):
            first.create(
                "tasks", str(uuid7()), {"title": title, "status": "todo", "source": "manual"}
            )
        await self.settle()

    def alive(self, client: SimClient, table: str, *, alive: bool = True) -> list[str]:
        return sorted(
            row["id"]
            for (name, _), row in client.rows.items()
            if name == table and (row["deleted_at"] is None) == alive
        )

    async def act(self, action: tuple[Any, ...]) -> None:
        kind = action[0]
        if kind == "tick":
            self.clock.advance(milliseconds=action[1])
            return
        client = self.clients[action[1] % len(self.clients)]
        if kind in ("sync", "push_only"):
            self.server.faults = list(action[2])
            with contextlib.suppress(NetworkError):
                await (client.sync if kind == "sync" else client.push)(self.server)
            self.server.faults = []
        elif kind == "edit":
            self._pick_and_edit(client, action[2], EDITS[action[3]])
        elif kind == "subtask":
            tasks = self.alive(client, "tasks")
            if tasks:
                task = tasks[action[2] % len(tasks)]
                client.create(
                    "subtasks",
                    str(uuid7()),
                    {"task_id": task, "title": "s", "done": False, "position": action[2]},
                )
        elif kind == "tag":
            tasks = self.alive(client, "tasks")
            if tasks:
                task = tasks[action[2] % len(tasks)]
                tag = str(ids.tag_id(TAGS[action[3]]))
                link = str(ids.task_tag_id(task, tag))
                if ("task_tags", link) not in client.rows:
                    client.create("task_tags", link, {"task_id": task, "tag_id": tag})
        else:
            self._toggle(client, kind, action[2])

    def _pick_and_edit(self, client: SimClient, pick: int, fields: dict[str, Any]) -> None:
        tasks = self.alive(client, "tasks")
        if tasks:
            client.edit("tasks", tasks[pick % len(tasks)], fields)

    def _toggle(self, client: SimClient, kind: str, pick: int) -> None:
        want_alive = kind == "delete"
        keys = sorted(
            key
            for key, row in client.rows.items()
            if (row["deleted_at"] is None) == want_alive
            and key[0] in ("tasks", "subtasks", "task_tags")
        )
        if keys:
            table, row_id = keys[pick % len(keys)]
            (client.delete if kind == "delete" else client.restore)(table, row_id)

    async def settle(self) -> None:
        for _ in range(8):
            for client in self.clients:
                await client.sync(self.server)
            async with self.sessionmaker() as session:
                head = (
                    await session.execute(sa.text("SELECT head_version FROM sync_state"))
                ).scalar()
            if all(not c.outbox and c.cursor == head for c in self.clients):
                return
        raise AssertionError("clients did not settle")

    async def check(self) -> None:
        server = await server_rows(self.sessionmaker, self.registry)
        for index, client in enumerate(self.clients):
            assert client.rejected == [], f"client {index}: {client.rejected}"
            assert client.rows == server, f"client {index} diverged from the server"
        for (table, _), row in server.items():
            if row["deleted_at"] is not None:
                continue
            parent = {"subtasks": "task_id", "task_tags": "task_id"}.get(table)
            if parent is not None:
                assert server[("tasks", row[parent])]["deleted_at"] is None, row
            if table == "task_tags":
                assert server[("tags", row["tag_id"])]["deleted_at"] is None, row


@pytest.mark.usefixtures("migrated_db_url")
@settings(
    max_examples=25,
    deadline=None,
    database=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture, HealthCheck.too_slow],
)
@given(
    skews=st.lists(st.integers(-3_600_000, 300_000), min_size=2, max_size=3),
    actions=st.lists(ACTION, min_size=6, max_size=40),
)
def test_calendar_replicas_converge(
    migrated_db_url: str, skews: list[int], actions: list[tuple[Any, ...]]
) -> None:
    async def scenario() -> None:
        world = World(migrated_db_url, skews)
        try:
            await world.reset()
            await world.seed()
            for action in actions:
                await world.act(action)
            await world.settle()
            await world.check()
        finally:
            await world.engine.dispose()
            await asyncio.sleep(0)

    run_async(scenario())
