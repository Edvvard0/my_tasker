"""In-process "network" between simulated clients and the real server code + PostgreSQL."""

import json
import uuid
from datetime import datetime
from typing import Any

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tasker.errors import ApiError
from tasker.sync.engine import apply_push
from tasker.sync.pull import pull_changes, serialize_row
from tasker.sync.registry import SyncRegistry
from tests.api_support import FakeClock
from tests.sync_sim.client import NetworkError, Op


class ResyncRequiredError(Exception):
    """The server answered 410 resync_required."""


class FlakyServer:
    """Calls the server code directly; each call may lose its request or its response."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        registry: SyncRegistry,
        clock: FakeClock,
    ) -> None:
        self.sessionmaker = sessionmaker
        self.registry = registry
        self.clock = clock
        self.faults: list[str | None] = []
        self.processed: dict[str, Op] = {}  # op_id -> the op as first received

    def _fault(self) -> str | None:
        return self.faults.pop(0) if self.faults else None

    async def push(self, device_id: uuid.UUID, ops: list[Op]) -> list[dict[str, Any]]:
        fault = self._fault()
        if fault == "drop_request":
            raise NetworkError("request lost")
        wire = json.loads(json.dumps(ops))
        async with self.sessionmaker() as session:
            result = await apply_push(session, self.registry, device_id, wire, self.clock.now())
        for op in wire:
            self.processed.setdefault(op["op_id"], op)
        if fault == "drop_response":
            raise NetworkError("response lost")
        return json.loads(json.dumps(result.results))  # type: ignore[no-any-return]

    async def pull(self, device_id: uuid.UUID, since: int, limit: int) -> dict[str, Any]:
        fault = self._fault()
        if fault == "drop_request":
            raise NetworkError("request lost")
        async with self.sessionmaker() as session:
            try:
                page = await pull_changes(
                    session,
                    self.registry,
                    device_id,
                    since=since,
                    limit=limit,
                    now=self.clock.now(),
                )
            except ApiError as exc:
                if exc.code == "resync_required":
                    raise ResyncRequiredError from exc
                raise
        if fault == "drop_response":
            raise NetworkError("response lost")
        return json.loads(json.dumps(page))  # type: ignore[no-any-return]


async def register_device(
    sessionmaker: async_sessionmaker[AsyncSession], device_id: uuid.UUID, now: datetime
) -> None:
    async with sessionmaker() as session, session.begin():
        await session.execute(
            sa.text(
                "INSERT INTO devices (id, name, platform, created_at, last_seen_at,"
                " last_pulled_version, refresh_token_hash, refresh_expires_at)"
                " VALUES (:id, 'sim', 'other', :now, :now, 0, 'x', :now)"
            ),
            {"id": device_id, "now": now},
        )


async def server_rows(
    sessionmaker: async_sessionmaker[AsyncSession], registry: SyncRegistry
) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    async with sessionmaker() as session:
        for spec in registry.tables():
            rows = await session.execute(sa.select(spec.table))
            for row in rows.mappings():
                result[(spec.name, str(row["id"]))] = serialize_row(spec, row)
    return result
