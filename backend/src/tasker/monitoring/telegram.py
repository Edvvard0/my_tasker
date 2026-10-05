"""Telegram behind an interface. The token and the chat id are secrets of the server environment:
they are never logged, never returned by the API and never put into an error text (an
``httpx`` exception carries the request URL, which contains the token, so exceptions are mapped to
codes and dropped).
"""

from dataclasses import dataclass
from typing import Protocol

import httpx

SEND_TIMEOUT = 10.0
MAX_TEXT = 4096
MIN_RETRY_AFTER, MAX_RETRY_AFTER = 1, 3600  # a 429 asks for a wait; the wait is kept sane


@dataclass(frozen=True, slots=True)
class SendResult:
    ok: bool
    error: str | None = None  # a code: see ``ERROR_CODES``
    retry_after: int | None = None  # seconds, from a 429
    permanent: bool = False  # the message will never be accepted as it is


ERROR_CODES = (
    "not_configured",
    "network",
    "rate_limited",
    "server_error",
    "unauthorized",
    "chat_not_found",
    "bad_request",
    "bad_response",
)


class Notifier(Protocol):
    @property
    def configured(self) -> bool: ...

    async def send(self, text: str) -> SendResult: ...


class NullNotifier:
    """Nothing configured: messages stay in the queue."""

    configured = False

    async def send(self, text: str) -> SendResult:
        return SendResult(False, "not_configured")


class TelegramNotifier:
    def __init__(
        self,
        token: str,
        chat_id: str,
        http: httpx.AsyncClient,
        *,
        api_base: str = "https://api.telegram.org",
    ) -> None:
        self._url = f"{api_base.rstrip('/')}/bot{token}/sendMessage"
        self._chat_id = chat_id
        self._http = http

    @property
    def configured(self) -> bool:
        return True

    async def send(self, text: str) -> SendResult:
        body = {
            "chat_id": self._chat_id,
            "text": text[:MAX_TEXT],
            "disable_web_page_preview": True,
        }
        try:
            response = await self._http.post(self._url, json=body, timeout=SEND_TIMEOUT)
        except httpx.HTTPError:
            return SendResult(False, "network")
        return interpret(response.status_code, _json(response))


def _json(response: httpx.Response) -> dict[str, object]:
    try:
        payload = response.json()
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def interpret(status: int, payload: dict[str, object]) -> SendResult:
    """Telegram's answer -> result. ``{"ok": true}`` is success; ``parameters.retry_after`` of a 429
    says how long to wait (kept within 1..3600 s); 401/403 mean a wrong token or a bot that may
    not write; 400 with ``chat not found`` a wrong chat id."""
    if status == 200 and payload.get("ok") is True:
        return SendResult(True)
    description = str(payload.get("description", "")).lower()
    parameters = payload.get("parameters")
    if status == 429:
        wait = parameters.get("retry_after") if isinstance(parameters, dict) else None
        seconds = 30
        if isinstance(wait, int) and not isinstance(wait, bool):
            seconds = min(max(wait, MIN_RETRY_AFTER), MAX_RETRY_AFTER)
        return SendResult(False, "rate_limited", retry_after=seconds)
    if status in (401, 403):
        return SendResult(False, "unauthorized", permanent=True)
    if status == 400 and "chat not found" in description:
        return SendResult(False, "chat_not_found", permanent=True)
    if status == 400:
        return SendResult(False, "bad_request", permanent=True)
    if status >= 500:
        return SendResult(False, "server_error")
    return SendResult(False, "bad_response")
