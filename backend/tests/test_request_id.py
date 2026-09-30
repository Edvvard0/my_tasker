import json

import pytest
import structlog
from starlette.types import Message, Receive, Scope, Send

from tasker.middleware import RequestIdMiddleware
from tests.support import app_client, make_settings

URL = "postgresql://x:y@127.0.0.1:1/z"


async def test_generates_request_id() -> None:
    async with app_client(make_settings(URL)) as client:
        first = await client.get("/health/live")
        second = await client.get("/health/live")
    assert len(first.headers["X-Request-ID"]) == 32
    assert first.headers["X-Request-ID"] != second.headers["X-Request-ID"]


async def test_echoes_valid_incoming_request_id() -> None:
    async with app_client(make_settings(URL)) as client:
        response = await client.get("/health/live", headers={"X-Request-ID": "abc-123.X_y"})
    assert response.headers["X-Request-ID"] == "abc-123.X_y"


async def test_replaces_invalid_incoming_request_id() -> None:
    async with app_client(make_settings(URL)) as client:
        response = await client.get("/health/live", headers={"X-Request-ID": "bad id\twith junk"})
    assert response.headers["X-Request-ID"] != "bad id\twith junk"
    assert len(response.headers["X-Request-ID"]) == 32


async def test_access_log_has_request_id_and_never_the_body(
    capsys: pytest.CaptureFixture[str],
) -> None:
    settings = make_settings(URL).model_copy(update={"log_level": "INFO"})
    async with app_client(settings) as client:
        response = await client.post(
            "/health/live?token=query-secret",
            content=b"super-secret-body",
            headers={"X-Request-ID": "rid-1", "Authorization": "Bearer header-secret"},
        )
    assert response.status_code == 405
    output = capsys.readouterr().out
    entries = [json.loads(line) for line in output.splitlines()]
    (entry,) = [e for e in entries if e["event"] == "request"]
    assert (entry["method"], entry["path"], entry["status"]) == ("POST", "/health/live", 405)
    assert entry["request_id"] == "rid-1"
    assert entry["level"] == "info"
    assert "timestamp" in entry
    for secret in ("super-secret-body", "query-secret", "header-secret"):
        assert secret not in output


async def test_context_is_cleared_after_request() -> None:
    async with app_client(make_settings(URL)) as client:
        await client.get("/health/live", headers={"X-Request-ID": "rid-2"})
    assert "request_id" not in structlog.contextvars.get_contextvars()


async def test_non_http_scopes_pass_through() -> None:
    seen: list[str] = []

    async def inner(scope: Scope, receive: Receive, send: Send) -> None:
        seen.append(scope["type"])

    async def receive() -> Message:
        return {"type": "lifespan.startup"}

    async def send(message: Message) -> None: ...

    await RequestIdMiddleware(inner)({"type": "lifespan"}, receive, send)
    assert seen == ["lifespan"]
