import asyncio
import json
import re
import socket
import threading
import uuid
from collections.abc import AsyncIterator, Iterator
from typing import Any

import httpx
import pytest
import sqlalchemy as sa
import uvicorn
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.auth import totp
from tasker.auth.service import upsert_owner
from tasker.db import create_sessionmaker
from tasker.ids import uuid7
from tasker.main import create_app
from tasker.runtime import build_runtime
from tasker.sync.events import event_stream
from tasker.sync.modules import build_registry
from tasker.sync.notify import ChangeHub, Subscription
from tasker.sync.user_settings import settings_id
from tests.api_support import PASSWORD, DeviceClient, Env, FakeClock, build_settings
from tests.test_auth_api import error_code
from tests.test_sync_push import create_setting


def parse(frame: bytes) -> tuple[str, dict[str, Any]]:
    text = frame.decode()
    event = next(line[7:] for line in text.splitlines() if line.startswith("event: "))
    data = next(line[6:] for line in text.splitlines() if line.startswith("data: "))
    return event, json.loads(data)


async def next_event(stream: AsyncIterator[bytes], wait: float = 5) -> tuple[str, dict[str, Any]]:
    frame = await asyncio.wait_for(anext(stream), wait)
    return parse(frame)


async def open_stream(env: Env, device: DeviceClient) -> AsyncIterator[bytes]:
    stream = event_stream(env.rt, device.device_id)
    assert await asyncio.wait_for(anext(stream), 5) == b"retry: 3000\n\n"
    return stream


async def test_hello_then_changes_from_another_device(env: Env) -> None:
    env.rt.sse_ping_seconds = 30
    phone, pc = await env.login("Phone"), await env.login("PC")
    stream = await open_stream(env, phone)
    assert await next_event(stream) == ("hello", {"head_version": 0})
    await pc.push_ok([create_setting(pc, "a"), create_setting(pc, "b")])
    assert await next_event(stream) == ("changes", {"head_version": 2})
    await stream.aclose()  # type: ignore[attr-defined]


async def test_own_commits_are_not_announced(env: Env) -> None:
    env.rt.sse_ping_seconds = 0.3
    phone = await env.login("Phone")
    stream = await open_stream(env, phone)
    await next_event(stream)
    await phone.push_ok([create_setting(phone)])
    event, _ = await next_event(stream)
    assert event == "ping"  # nothing but the heartbeat arrives
    await stream.aclose()  # type: ignore[attr-defined]


async def test_rolled_back_pushes_are_not_announced(env: Env) -> None:
    env.rt.sse_ping_seconds = 0.3
    phone, pc = await env.login("Phone"), await env.login("PC")
    stream = await open_stream(env, phone)
    await next_event(stream)
    await pc.push_ok([{"op_id": "nope"}])  # rejected: nothing committed, no version used
    assert (await next_event(stream))[0] == "ping"
    await stream.aclose()  # type: ignore[attr-defined]


async def test_heartbeat_and_revocation(env: Env) -> None:
    env.rt.sse_ping_seconds = 0.1
    phone, pc = await env.login("Phone"), await env.login("PC")
    stream = await open_stream(env, phone)
    await next_event(stream)
    assert (await next_event(stream))[0] == "ping"
    await env.client.delete(f"/auth/devices/{phone.device_id}", headers=pc.headers)
    events = [await next_event(stream)]
    if events[0][0] == "ping":
        events.append(await next_event(stream))
    assert events[-1] == ("revoked", {})
    with pytest.raises(StopAsyncIteration):
        await asyncio.wait_for(anext(stream), 5)


async def test_revoked_between_changes_ends_the_stream(env: Env) -> None:
    env.rt.sse_ping_seconds = 30
    phone, pc = await env.login("Phone"), await env.login("PC")
    stream = await open_stream(env, phone)
    await next_event(stream)
    await env.client.delete(f"/auth/devices/{phone.device_id}", headers=pc.headers)
    await pc.push_ok([create_setting(pc)])
    assert await next_event(stream) == ("revoked", {})


async def test_closing_the_hub_ends_streams(env: Env) -> None:
    env.rt.sse_ping_seconds = 30
    phone = await env.login()
    stream = await open_stream(env, phone)
    await next_event(stream)
    pending = asyncio.ensure_future(anext(stream))
    await asyncio.sleep(0.05)
    await env.rt.hub.close()
    with pytest.raises(StopAsyncIteration):
        await asyncio.wait_for(pending, 5)


async def test_listener_reconnects_after_the_connection_dies(env: Env) -> None:
    env.rt.hub._retry_delay = 0.05
    env.rt.sse_ping_seconds = 30
    phone, pc = await env.login("Phone"), await env.login("PC")
    stream = await open_stream(env, phone)
    await next_event(stream)
    async with env.sessionmaker() as session:
        await session.execute(
            sa.text(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity"
                " WHERE query LIKE 'LISTEN%' AND pid <> pg_backend_pid()"
            )
        )
    assert (await next_event(stream))[0] == "changes"  # woken up: something may have been missed
    await asyncio.sleep(0.3)
    await pc.push_ok([create_setting(pc)])
    assert (await next_event(stream, wait=10))[0] == "changes"
    await stream.aclose()  # type: ignore[attr-defined]


async def test_hub_survives_an_unreachable_database() -> None:
    hub = ChangeHub(
        "postgresql+asyncpg://u:p@127.0.0.1:1/none", retry_delay=0.05, ready_timeout=0.2
    )

    async def use() -> None:
        async with hub.subscribe(uuid.uuid4()):
            await asyncio.sleep(0.2)

    await asyncio.wait_for(use(), 20)
    await hub.close()


def test_hub_ignores_malformed_notifications() -> None:
    hub = ChangeHub("postgresql://u:p@h/d")
    subscription = Subscription(uuid.uuid4())
    hub._subscriptions.add(subscription)
    hub._on_notify(None, 0, "sync_changes", "not json")
    assert subscription.event.is_set()


@pytest.fixture
def live_server(migrated_db_url: str) -> Iterator[tuple[str, FakeClock]]:
    """A real uvicorn server, to verify headers and incremental delivery over HTTP."""
    clock = FakeClock()
    settings = build_settings(migrated_db_url)
    app = create_app(settings, clock=clock)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(100):
        if server.started:
            break
        threading.Event().wait(0.1)
    yield f"http://127.0.0.1:{port}", clock
    server.should_exit = True
    thread.join(timeout=10)


async def test_events_over_real_http(
    live_server: tuple[str, FakeClock], migrated_db_url: str
) -> None:
    base, clock = live_server
    engine = create_async_engine(migrated_db_url)
    sessionmaker = create_sessionmaker(engine)
    rt = build_runtime(build_settings(migrated_db_url), sessionmaker, build_registry(), clock)
    async with sessionmaker() as session:
        enrollment = await upsert_owner(rt, session, password=PASSWORD, replace=False)
    match = re.search(r"secret=([A-Z2-7]+)", enrollment.otpauth_uri)
    assert match
    schema = {"X-Client-Schema-Version": "1"}

    async with httpx.AsyncClient(base_url=base, timeout=10) as http:
        devices: list[dict[str, Any]] = []
        for offset, name in enumerate(("Phone", "PC")):
            step = totp.current_step(clock.current.timestamp()) - 1 + offset
            body = {
                "password": PASSWORD,
                "totp_code": totp.code_for_step(match.group(1), step),
                "device": {"name": name, "platform": "other"},
            }
            response = await http.post("/auth/login", json=body, headers=schema)
            assert response.status_code == 200, response.text
            devices.append(response.json())
        phone, pc = ({"Authorization": f"Bearer {d['access_token']}", **schema} for d in devices)

        async with http.stream("GET", "/events", headers=phone) as stream:
            assert stream.status_code == 200
            assert stream.headers["content-type"].startswith("text/event-stream")
            assert stream.headers["cache-control"] == "no-cache"
            assert stream.headers["x-accel-buffering"] == "no"
            lines = stream.aiter_lines()

            async def read_until(event: str) -> list[str]:
                seen: list[str] = []
                while True:
                    line = await asyncio.wait_for(anext(lines), 10)
                    if line.startswith("event: "):
                        seen.append(line[7:])
                        if line[7:] == event:
                            return seen

            assert await read_until("hello") == ["hello"]
            op = {
                "op_id": str(uuid7()),
                "table": "user_settings",
                "id": str(settings_id("a")),
                "type": "upsert",
                "base_version": 0,
                "hlc": f"{clock.ms:015d}-00000-{devices[1]['device_id']}",
                "fields": {"key": "a", "value": 1, "created_at": "2026-10-01T00:00:00Z"},
            }
            pushed = await http.post("/sync/push", json={"ops": [op]}, headers=pc)
            assert pushed.json()["results"][0]["status"] == "applied"
            assert await read_until("changes") == ["changes"]
    await engine.dispose()


async def test_events_requires_authentication_and_version(env: Env) -> None:
    response = await env.client.get("/events", headers={"X-Client-Schema-Version": "1"})
    assert (response.status_code, error_code(response)) == (401, "not_authenticated")
