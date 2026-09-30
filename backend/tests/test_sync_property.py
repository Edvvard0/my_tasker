"""Property-based convergence tests: 2-3 simulated clients, random edits, network faults."""

import asyncio
import contextlib
import os
from typing import Any

import pytest
import sqlalchemy as sa
from hypothesis import HealthCheck, Phase, event, given, settings
from hypothesis import strategies as st
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db import create_sessionmaker
from tasker.ids import uuid7
from tests.api_support import FakeClock
from tests.conftest import run_async
from tests.sync_sim.client import NetworkError, SimClient
from tests.sync_sim.server import FlakyServer, register_device, server_rows
from tests.sync_tables import build_test_registry

settings.register_profile(
    "ci", max_examples=40, deadline=None, database=None, print_blob=True,
    suppress_health_check=[HealthCheck.function_scoped_fixture, HealthCheck.too_slow],
)  # fmt: skip
settings.register_profile("thorough", parent=settings.get_profile("ci"), max_examples=400)
# Fast failure detection without shrinking (used to check that mutations of the server are caught).
settings.register_profile(
    "explore",
    parent=settings.get_profile("ci"),
    max_examples=300,
    phases=[Phase.explicit, Phase.generate],
)
settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "ci"))

FAULTS = st.sampled_from([None, None, None, "drop_request", "drop_response"])
TITLES = st.sampled_from(["a", "b", "c", "d"])
EDIT = st.tuples(st.just("edit"), st.integers(0, 2), st.integers(0, 1), st.integers(0, 2), TITLES)
DELETE = st.tuples(st.just("delete"), st.integers(0, 2), st.integers(0, 3))
RESTORE = st.tuples(st.just("restore"), st.integers(0, 2), st.integers(0, 1))
SYNC = st.tuples(st.just("sync"), st.integers(0, 2), st.lists(FAULTS, max_size=4))
# Push without the following pull (the pull "failed"): later edits then use a stale base_version.
PUSH_ONLY = st.tuples(st.just("push_only"), st.integers(0, 2), st.lists(FAULTS, max_size=2))
# Edits and syncs are repeated so that they dominate: conflicts need concurrent work on the
# few rows every device starts with.
ACTION = st.one_of(
    EDIT, EDIT, EDIT, EDIT, EDIT, EDIT, DELETE, DELETE, RESTORE, RESTORE,
    SYNC, SYNC, PUSH_ONLY, PUSH_ONLY,
    st.tuples(st.just("create_project"), st.integers(0, 2), TITLES, st.integers(0, 3)),
    st.tuples(st.just("create_task"), st.integers(0, 2), st.integers(0, 9), TITLES),
    st.tuples(st.just("tick"), st.integers(1, 3_000)),
)  # fmt: skip
SKEW = st.integers(-3_600_000, 300_000)  # within the server's 10 minute future tolerance
TABLES = ("test_tasks", "test_projects", "sync_ops", "sync_conflicts", "devices")


class World:
    def __init__(self, url: str, skews: list[int]) -> None:
        self.engine = create_async_engine(url)
        self.sessionmaker = create_sessionmaker(self.engine)
        self.registry = build_test_registry()
        self.clock = FakeClock()
        self.server = FlakyServer(self.sessionmaker, self.registry, self.clock)
        self.conflict_kinds: list[str] = []
        self.conflict_count = 0
        self.clients = [
            SimClient(uuid7(), (lambda skew=skew: self.clock.ms + skew)) for skew in skews
        ]

    async def seed(self) -> None:
        """Every device starts with the same two projects and two tasks."""
        first = self.clients[0]
        for title in ("a", "b"):
            project = str(uuid7())
            first.create("test_projects", project, {"title": title, "budget": 0})
            first.create("test_tasks", str(uuid7()), {"project_id": project, "title": title})
        await self.settle()

    async def reset(self) -> None:
        async with self.sessionmaker() as session, session.begin():
            for table in TABLES:
                await session.execute(sa.text(f"DELETE FROM {table}"))  # noqa: S608
            await session.execute(
                sa.text("UPDATE sync_state SET head_version=0, purge_watermark=0")
            )
        for client in self.clients:
            await register_device(self.sessionmaker, client.device_id, self.clock.now())

    async def close(self) -> None:
        await self.engine.dispose()
        await asyncio.sleep(0)

    def rows_of(self, client: SimClient, table: str, *, alive: bool) -> list[str]:
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
        if kind == "sync":
            self.server.faults = list(action[2])
            with contextlib.suppress(NetworkError):
                await client.sync(self.server)
            self.server.faults = []
        elif kind == "push_only":
            self.server.faults = list(action[2])
            with contextlib.suppress(NetworkError):
                await client.push(self.server)
            self.server.faults = []
        elif kind == "create_project":
            client.create("test_projects", str(uuid7()), {"title": action[2], "budget": action[3]})
        elif kind == "create_task":
            parents = self.rows_of(client, "test_projects", alive=True)
            if parents:
                parent = parents[action[2] % len(parents)]
                client.create(
                    "test_tasks", str(uuid7()), {"project_id": parent, "title": action[3]}
                )
        elif kind == "edit":
            self._edit(client, action[2], action[3], action[4])
        else:
            self._toggle(client, kind, action[2])

    def _edit(self, client: SimClient, pick: int, which: int, value: str) -> None:
        keys = sorted(k for k, r in client.rows.items() if r["deleted_at"] is None)
        if not keys:
            return
        table, row_id = keys[pick % len(keys)]
        if table == "test_projects":
            options: list[dict[str, Any]] = [
                {"title": value},
                {"budget": ord(value) % 4},
                {"archived": ord(value) % 2 == 0},
            ]
        else:
            options = [{"title": value}, {"note": value}, {"title": value + value}]
        fields = options[which]
        client.edit(table, row_id, fields)

    def _toggle(self, client: SimClient, kind: str, pick: int) -> None:
        want_alive = kind == "delete"
        keys = sorted(k for k, r in client.rows.items() if (r["deleted_at"] is None) == want_alive)
        if not keys:
            return
        table, row_id = keys[pick % len(keys)]
        (client.delete if kind == "delete" else client.restore)(table, row_id)

    async def settle(self) -> None:
        """Every device syncs without faults until nothing moves any more."""
        for _ in range(8):
            for client in self.clients:
                await client.sync(self.server)
            head = await self._scalar("SELECT head_version FROM sync_state")
            if all(not c.outbox and c.cursor == head for c in self.clients):
                return
        raise AssertionError("clients did not settle")

    async def _scalar(self, query: str) -> Any:
        async with self.sessionmaker() as session:
            return (await session.execute(sa.text(query))).scalar()

    async def check(self) -> None:
        server = await server_rows(self.sessionmaker, self.registry)
        for index, client in enumerate(self.clients):
            assert client.rejected == [], f"client {index} had rejected ops: {client.rejected}"
            assert client.rows == server, f"client {index} diverged from the server"
        # Cascade invariant: nothing alive under a deleted parent.
        for (table, _), row in server.items():
            if table == "test_tasks" and row["deleted_at"] is None:
                parent = server[("test_projects", row["project_id"])]
                assert parent["deleted_at"] is None, f"live task under deleted project: {row}"
        await self.check_no_silent_loss(server)
        journal = await self._scalar("SELECT count(*) FROM sync_ops")
        assert journal == len(self.server.processed)

    async def check_no_silent_loss(self, server: dict[tuple[str, str], dict[str, Any]]) -> None:
        async with self.sessionmaker() as session:
            results = {
                str(r.op_id): r.result
                for r in await session.execute(sa.text("SELECT op_id, result FROM sync_ops"))
            }
            conflicts = list(
                await session.execute(
                    sa.text(
                        "SELECT table_name, row_id, field, kind, losing_value,"
                        " losing_device_id, winning_device_id FROM sync_conflicts"
                    )
                )
            )
        self.conflict_kinds = sorted({c.kind for c in conflicts})
        self.conflict_count = len(conflicts)
        self._logged = {
            (c.table_name, str(c.row_id), c.field, repr(c.losing_value)) for c in conflicts
        }
        self._applied = [
            (op, results[op_id]) for op_id, op in self.server.processed.items()
            if results[op_id]["status"] == "applied" and op["type"] == "upsert"
        ]  # fmt: skip
        self._check_last_writer_wins(server)
        self._check_conflicts_are_between_devices(conflicts)
        self._check_untouched_rows_are_alive(server)
        self._check_cascade_restored(server)
        for op, result in self._applied:
            key = (op["table"], op["id"])
            for name, value in op["fields"].items():
                if name in ("created_at", "deleted_at") or server[key][name] == value:
                    continue
                assert self._justified(op, result, name, value), (
                    f"value {value!r} of {key}.{name} was overwritten silently"
                )

    def _check_last_writer_wins(self, server: dict[tuple[str, str], dict[str, Any]]) -> None:
        """Each field ends with the value of the write that carries the greatest HLC."""
        newest: dict[tuple[str, str, str], tuple[str, Any]] = {}
        for op, _ in self._applied:
            for name, value in op["fields"].items():
                if name in ("created_at", "deleted_at"):
                    continue
                key = (op["table"], op["id"], name)
                if key not in newest or op["hlc"] > newest[key][0]:
                    newest[key] = (op["hlc"], value)
        for (table, row_id, name), (_, value) in newest.items():
            assert server[(table, row_id)][name] == value, (
                f"{table}.{name} of {row_id} does not hold the newest write {value!r}"
            )

    @staticmethod
    def _check_conflicts_are_between_devices(conflicts: list[Any]) -> None:
        for conflict in conflicts:
            if conflict.kind == "field":
                assert conflict.losing_device_id != conflict.winning_device_id, (
                    "a device conflicted with itself"
                )

    def _check_untouched_rows_are_alive(
        self, server: dict[tuple[str, str], dict[str, Any]]
    ) -> None:
        deleted = {
            (op["table"], op["id"])
            for op in self.server.processed.values()
            if op["type"] == "delete"
        }
        for (table, row_id), row in server.items():
            parent_deleted = (
                table == "test_tasks" and ("test_projects", row["project_id"]) in deleted
            )
            if (table, row_id) not in deleted and not parent_deleted:
                assert row["deleted_at"] is None, f"{table} {row_id} is deleted, nobody deleted it"

    def _check_cascade_restored(self, server: dict[tuple[str, str], dict[str, Any]]) -> None:
        """A task nobody deleted is alive whenever its project is (cascades are undone)."""
        deleted = {op["id"] for op in self.server.processed.values() if op["type"] == "delete"}
        for (table, row_id), row in server.items():
            if table == "test_tasks" and row_id not in deleted:
                project = server[("test_projects", row["project_id"])]
                if project["deleted_at"] is None:
                    assert row["deleted_at"] is None, f"task {row_id} stayed deleted: {row}"

    def _justified(self, op: dict[str, Any], result: dict[str, Any], name: str, value: Any) -> bool:
        if (op["table"], op["id"], name, repr(value)) in self._logged:
            return True
        device = op["hlc"][-36:]
        for other, _ in self._applied:
            if (other["table"], other["id"]) != (op["table"], op["id"]):
                continue
            if name not in other.get("fields", {}) or other["hlc"] <= op["hlc"]:
                continue
            if other["hlc"][-36:] == device or other["base_version"] >= (
                result["server_version"] or 0
            ):
                return True  # the same device overwrote itself, or the other saw this value
        return False


@pytest.mark.usefixtures("_tables")
@given(
    skews=st.lists(SKEW, min_size=2, max_size=3),
    actions=st.lists(ACTION, min_size=8, max_size=50),
)
def test_replicas_converge_and_losses_are_logged(
    migrated_db_url: str, skews: list[int], actions: list[tuple[Any, ...]]
) -> None:
    stats: dict[str, Any] = {}

    async def scenario() -> None:
        world = World(migrated_db_url, skews)
        try:
            await world.reset()
            await world.seed()
            for action in actions:
                await world.act(action)
            await world.settle()
            await world.check()
            stats["kinds"], stats["count"] = world.conflict_kinds, world.conflict_count
        finally:
            await world.close()

    run_async(scenario())
    event(f"conflicts logged: {min(stats['count'], 6)}")
    event(f"conflict kinds: {stats['kinds']}")
