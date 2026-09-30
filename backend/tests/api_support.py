"""Test environment: app + real PostgreSQL + fake clock + a logged-in owner."""

import asyncio
import re
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from tasker.auth import totp
from tasker.auth.service import upsert_owner
from tasker.clock import to_ms
from tasker.config import Settings
from tasker.db import create_sessionmaker
from tasker.hlc import HlcClock, format_hlc
from tasker.ids import uuid7
from tasker.main import create_app
from tasker.runtime import Runtime, build_runtime
from tasker.sync.modules import build_registry
from tasker.sync.registry import SyncRegistry

PASSWORD = "correct horse battery"
START = datetime(2026, 10, 1, 12, 0, 0, tzinfo=UTC)
SCHEMA = {"X-Client-Schema-Version": "1"}


class FakeClock:
    def __init__(self, start: datetime = START) -> None:
        self.current = start

    def now(self) -> datetime:
        return self.current

    def advance(self, **kwargs: float) -> None:
        self.current += timedelta(**kwargs)

    @property
    def ms(self) -> int:
        return to_ms(self.current)


def build_settings(url: str, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "database_url": url,
        "app_env": "test",
        "log_level": "WARNING",
        "app_secret_key": "k" * 48,
        "argon2_memory_kib": 8,
        "argon2_time_cost": 1,
        "argon2_parallelism": 1,
    }
    values.update(overrides)
    return Settings(**values)


@dataclass
class DeviceClient:
    """A logged-in device: token plus a protocol clock; talks to the API over HTTP."""

    env: "Env"
    device_id: uuid.UUID
    access_token: str
    refresh_token: str
    hlc: HlcClock = field(init=False)

    def __post_init__(self) -> None:
        self.hlc = HlcClock(self.device_id)

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.access_token}", **SCHEMA}

    def op(
        self,
        table: str,
        row_id: uuid.UUID,
        op_type: str = "upsert",
        fields: dict[str, Any] | None = None,
        *,
        base: int = 0,
        hlc: str | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "op_id": str(uuid7()),
            "table": table,
            "id": str(row_id),
            "type": op_type,
            "base_version": base,
            "hlc": hlc or self.hlc.send(self.env.clock.ms),
        }
        if op_type == "upsert":
            body["fields"] = fields or {}
        return body

    def at(self, offset_ms: int = 0, counter: int = 0) -> str:
        """An HLC at ``clock + offset_ms`` (deterministic cross-device ordering in tests)."""
        return format_hlc(self.env.clock.ms + offset_ms, counter, str(self.device_id))

    def created(self) -> str:
        return self.env.clock.current.isoformat().replace("+00:00", "Z")

    async def refresh(self) -> None:
        """Rotate the tokens (needed after the fake clock jumped past the access TTL)."""
        response = await self.env.client.post(
            "/auth/refresh", json={"refresh_token": self.refresh_token}, headers=SCHEMA
        )
        assert response.status_code == 200, response.text
        body = response.json()
        self.access_token, self.refresh_token = body["access_token"], body["refresh_token"]

    async def push(self, ops: list[dict[str, Any]]) -> httpx.Response:
        return await self.env.client.post("/sync/push", json={"ops": ops}, headers=self.headers)

    async def push_ok(self, ops: list[dict[str, Any]]) -> list[dict[str, Any]]:
        response = await self.push(ops)
        assert response.status_code == 200, response.text
        results: list[dict[str, Any]] = response.json()["results"]
        return results

    async def pull(self, since: int = 0, limit: int = 500) -> httpx.Response:
        return await self.env.client.get(
            "/sync/pull", params={"since": since, "limit": limit}, headers=self.headers
        )

    async def pull_ok(self, since: int = 0, limit: int = 500) -> dict[str, Any]:
        response = await self.pull(since, limit)
        assert response.status_code == 200, response.text
        body: dict[str, Any] = response.json()
        return body

    async def pull_all(self, since: int = 0) -> list[dict[str, Any]]:
        changes: list[dict[str, Any]] = []
        while True:
            page = await self.pull_ok(since, 3)
            changes.extend(page["changes"])
            since = page["next_since"]
            if not page["has_more"]:
                return changes

    async def get(self, path: str, **params: Any) -> httpx.Response:
        return await self.env.client.get(path, params=params, headers=self.headers)

    async def post(self, path: str, body: Any = None) -> httpx.Response:
        return await self.env.client.post(path, json=body, headers=self.headers)


@dataclass
class Env:
    client: httpx.AsyncClient
    clock: FakeClock
    url: str
    settings: Settings
    totp_secret: str
    sessionmaker: async_sessionmaker[AsyncSession]
    rt: Runtime
    last_step: int = 0

    def next_code(self) -> str:
        """A valid, never-yet-used TOTP code.

        The server accepts steps current-1..current+1, so up to three logins fit in one window;
        beyond that the fake clock is moved forward.
        """
        current = totp.current_step(self.clock.current.timestamp())
        step = max(current - 1, self.last_step + 1)
        if step > current + 1:
            self.clock.advance(seconds=(step - 1 - current) * totp.STEP_SECONDS)
        self.last_step = step
        return totp.code_for_step(self.totp_secret, step)

    def login_body(self, name: str = "Phone", *, code: str | None = None) -> dict[str, Any]:
        return {
            "password": PASSWORD,
            "totp_code": code or self.next_code(),
            "device": {"name": name, "platform": "android", "app_version": "0.1.0"},
        }

    async def login(self, name: str = "Phone") -> DeviceClient:
        self.clock.advance(seconds=1)  # distinct created_at, so device order is deterministic
        response = await self.client.post("/auth/login", json=self.login_body(name), headers=SCHEMA)
        assert response.status_code == 200, response.text
        body = response.json()
        return DeviceClient(
            self, uuid.UUID(body["device_id"]), body["access_token"], body["refresh_token"]
        )

    async def scalar(self, query: str, **params: Any) -> Any:
        async with self.sessionmaker() as session:
            return (await session.execute(sa.text(query), params)).scalar()

    async def execute(self, query: str, **params: Any) -> None:
        async with self.sessionmaker() as session, session.begin():
            await session.execute(sa.text(query), params)


@asynccontextmanager
async def make_env(
    url: str,
    *,
    registry: SyncRegistry | None = None,
    extra_setup: Callable[[str], Any] | None = None,
    **overrides: Any,
) -> AsyncIterator[Env]:
    settings = build_settings(url, **overrides)
    clock = FakeClock()
    if extra_setup is not None:
        await extra_setup(url)
    engine = create_async_engine(url)
    sessionmaker = create_sessionmaker(engine)
    rt = build_runtime(settings, sessionmaker, registry or build_registry(), clock)
    async with sessionmaker() as session:
        enrollment = await upsert_owner(rt, session, password=PASSWORD, replace=False)
    match = re.search(r"secret=([A-Z2-7]+)", enrollment.otpauth_uri)
    assert match
    app = create_app(settings, registry=registry, clock=clock)
    try:
        async with (
            app.router.lifespan_context(app),
            httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as client,
        ):
            yield Env(client, clock, url, settings, match.group(1), sessionmaker, app.state.rt)
    finally:
        await engine.dispose()
        await asyncio.sleep(0)
