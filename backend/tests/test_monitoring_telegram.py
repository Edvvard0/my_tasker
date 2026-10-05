"""Telegram behind its interface: recorded answers, and the token that must never leak."""

import json
import logging
from pathlib import Path
from typing import Any

import httpx
import pytest

from tasker.logging import configure_logging
from tasker.monitoring.telegram import NullNotifier, TelegramNotifier, interpret

TOKEN = "123456:TEST-token-not-real"  # gitleaks:allow
CHAT = "-1009999999999"
RECORDED = json.loads(
    (Path(__file__).parent / "data" / "monitoring" / "telegram_responses.json").read_text()
)["responses"]


def notifier(handler: Any, **kwargs: Any) -> TelegramNotifier:
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return TelegramNotifier(TOKEN, CHAT, http, **kwargs)


def answer(name: str) -> Any:
    recorded = RECORDED[name]

    def handler(request: httpx.Request) -> httpx.Response:
        if recorded["body"] is None:
            return httpx.Response(recorded["status"], content=b"<html>bad gateway</html>")
        return httpx.Response(recorded["status"], json=recorded["body"])

    return handler


@pytest.mark.parametrize(
    ("name", "ok", "error", "retry", "permanent"),
    [
        ("ok", True, None, None, False),
        ("too_many_requests", False, "rate_limited", 17, False),
        ("too_many_requests_without_parameters", False, "rate_limited", 30, False),
        ("wrong_token", False, "unauthorized", None, True),
        ("bot_blocked", False, "unauthorized", None, True),
        ("chat_not_found", False, "chat_not_found", None, True),
        ("message_too_long", False, "bad_request", None, True),
        ("bad_gateway", False, "server_error", None, False),
        ("html_error_page", False, "server_error", None, False),
        ("ok_false_with_200", False, "bad_response", None, False),
    ],
)
async def test_recorded_answers_become_results(
    name: str, ok: bool, error: str | None, retry: int | None, permanent: bool
) -> None:
    result = await notifier(answer(name)).send("hello")
    assert (result.ok, result.error, result.retry_after, result.permanent) == (
        ok,
        error,
        retry,
        permanent,
    )


async def test_the_request_carries_the_chat_and_the_text_and_no_preview() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=RECORDED["ok"]["body"])

    await notifier(handler, api_base="https://tg.example/").send("x" * 5000)
    (request,) = seen
    assert request.url == f"https://tg.example/bot{TOKEN}/sendMessage"
    body = json.loads(request.content)
    assert body["chat_id"] == CHAT
    assert len(body["text"]) == 4096
    assert body["disable_web_page_preview"] is True


async def test_a_network_error_is_a_code_and_never_carries_the_token() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"cannot reach {request.url}", request=request)

    result = await notifier(handler).send("x")
    assert (result.ok, result.error) == (False, "network")
    assert TOKEN not in repr(result) and CHAT not in repr(result)


async def test_the_null_notifier_reports_not_configured() -> None:
    null = NullNotifier()
    assert null.configured is False
    assert (await null.send("x")).error == "not_configured"
    assert notifier(answer("ok")).configured is True


def test_interpret_ignores_odd_payloads() -> None:
    assert interpret(200, {"ok": "true"}).error == "bad_response"
    assert interpret(429, {"parameters": {"retry_after": "soon"}}).retry_after == 30
    assert interpret(404, {}).error == "bad_response"


def test_the_redactor_removes_the_token_and_the_chat_id_from_log_lines(
    capfd: pytest.CaptureFixture[str],
) -> None:
    configure_logging("INFO", redact=[TOKEN, CHAT])
    log = logging.getLogger("t")
    log.info("request to https://api.telegram.org/bot%s/sendMessage chat %s", TOKEN, CHAT)
    try:
        raise RuntimeError(f"boom {TOKEN} {CHAT}")
    except RuntimeError:
        log.exception("failed")
    out = capfd.readouterr().out
    assert TOKEN not in out and CHAT not in out
    assert "[redacted]" in out
