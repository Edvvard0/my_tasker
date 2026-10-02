"""Environment for the AI tests: the real app on a live HTTP port + the fake provider."""

import asyncio
import contextlib
import io
import json
import logging
import re
import socket
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

import httpx
import uvicorn
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.ai.runtime import AiRuntime
from tasker.auth.service import upsert_owner
from tasker.db import create_sessionmaker
from tasker.ids import uuid7
from tasker.main import create_app
from tasker.runtime import build_runtime
from tasker.sync.modules import build_registry
from tests.ai.fake_upstream import FakeUpstream
from tests.api_support import PASSWORD, DeviceClient, Env, FakeClock, build_settings

KEY = "sk-polza-TESTKEY-0123456789abcdef-SECRET"  # gitleaks:allow


class QuietServer(uvicorn.Server):
    """uvicorn inside the test's event loop, without touching the process signal handlers."""

    @contextlib.contextmanager
    def capture_signals(self) -> Iterator[None]:
        yield


@dataclass
class AiEnv:
    env: Env
    fake: FakeUpstream
    ai: AiRuntime
    logs: io.StringIO

    @property
    def client(self) -> httpx.AsyncClient:
        return self.env.client

    async def device(self, name: str = "Phone") -> DeviceClient:
        return await self.env.login(name)

    async def settle(self) -> None:
        """Wait until every chat run and its writes finished."""
        await self.ai.wait_idle(10)


@asynccontextmanager
async def make_ai_env(url: str, fake: FakeUpstream, **overrides: Any) -> AsyncIterator[AiEnv]:
    values: dict[str, Any] = {
        "polza_base_url": fake.base_url,
        "polza_api_key": KEY,
        "polza_max_retries": 0,
        "polza_retry_backoff": 0.01,
        "polza_first_byte_timeout": 5.0,
        "polza_idle_timeout": 5.0,
        "ai_sse_ping_seconds": 30.0,
        "log_level": "DEBUG",
    }
    values.update(overrides)
    settings = build_settings(url, **values)
    clock = FakeClock()
    engine = create_async_engine(url)
    sessionmaker = create_sessionmaker(engine)
    rt0 = build_runtime(settings, sessionmaker, build_registry(), clock)
    async with sessionmaker() as session:
        enrollment = await upsert_owner(rt0, session, password=PASSWORD, replace=False)
    match = re.search(r"secret=([A-Z2-7]+)", enrollment.otpauth_uri)
    assert match
    app = create_app(settings, clock=clock)
    logs = io.StringIO()
    handler = logging.StreamHandler(logs)
    handler.setFormatter(logging.getLogger().handlers[0].formatter)
    logging.getLogger().addHandler(handler)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = QuietServer(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    serving = asyncio.create_task(server.serve())
    for _ in range(500):
        if server.started:
            break
        await asyncio.sleep(0.02)
    assert server.started, "the test server did not start"
    client = httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}", timeout=20)
    env = Env(client, clock, url, settings, match.group(1), sessionmaker, app.state.rt)
    try:
        yield AiEnv(env, fake, app.state.ai, logs)
    finally:
        await client.aclose()
        server.should_exit = True
        await serving
        logging.getLogger().removeHandler(handler)
        await engine.dispose()


# ---------------------------------------------------------------- request helpers


def new_conversation_op(
    device: DeviceClient, conversation_id: uuid.UUID, **fields: Any
) -> dict[str, Any]:
    body = {
        "title": "",
        "topic": "general",
        "pinned": False,
        "archived": False,
        "mode": "cloud",
        "created_at": device.created(),
        **fields,
    }
    return device.op("ai_conversations", conversation_id, fields=body)


async def make_conversation(device: DeviceClient, **fields: Any) -> uuid.UUID:
    conversation_id = uuid7()
    results = await device.push_ok([new_conversation_op(device, conversation_id, **fields)])
    assert results[0]["status"] == "applied", results
    return conversation_id


def chat_body(conversation_id: uuid.UUID, **overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "conversation_id": str(conversation_id),
        "assistant_message_id": str(uuid7()),
        "model": "openai/gpt-4o",
        "messages": [{"role": "user", "content": "Привет"}],
        "timezone": "Europe/Moscow",
    }
    body.update(overrides)
    return body


@dataclass
class Sse:
    status: int
    events: list[tuple[str, dict[str, Any]]]
    text: str

    def names(self) -> list[str]:
        return [name for name, _ in self.events]

    def of(self, name: str) -> list[dict[str, Any]]:
        return [data for event, data in self.events if event == name]

    @property
    def last(self) -> tuple[str, dict[str, Any]]:
        return self.events[-1]


def parse_sse(text: str) -> list[tuple[str, dict[str, Any]]]:
    events: list[tuple[str, dict[str, Any]]] = []
    for frame in text.split("\n\n"):
        if not frame.strip():
            continue
        lines = frame.splitlines()
        name = next(line[7:] for line in lines if line.startswith("event: "))
        data = next(line[6:] for line in lines if line.startswith("data: "))
        events.append((name, json.loads(data)))
    return events


async def run_chat(device: DeviceClient, body: dict[str, Any]) -> Sse:
    """POST the request and read the whole stream (``status != 200`` -> no events)."""
    async with device.env.client.stream(
        "POST", "/ai/chat/completions", json=body, headers=device.headers
    ) as response:
        text = (await response.aread()).decode()
        if response.status_code != 200:
            return Sse(response.status_code, [], text)
        return Sse(200, parse_sse(text), text)
