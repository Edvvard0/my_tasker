"""Async client of the OpenAI-compatible provider (polza.ai): streaming chat and the model list.

Rules (spec stage3, 8 and 9): explicit timeouts (connect, first byte, idle, total), retries only
**before the first byte** of a stream, cancellation closes the provider connection, and nothing
that comes from the provider (body, headers, URL) or the key is ever put into an error.
"""

import asyncio
import json
import time
from collections.abc import AsyncIterator
from typing import Any

import httpx
import structlog

from tasker.config import Settings

log = structlog.get_logger("ai.upstream")

RETRY_STATUSES = frozenset({408, 429, 500, 502, 503, 504})
MAX_RETRY_AFTER = 10.0
MAX_MODELS_BYTES = 8_000_000


class UpstreamError(Exception):
    """A failed provider call; ``code``/``message`` are safe to show to the client."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        retryable: bool = False,
        status: int | None = None,
        retry_after: float | None = None,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.retryable = retryable
        self.status = status
        self.retry_after = retry_after


def error_for_status(status: int, retry_after: float | None = None) -> UpstreamError:
    if status == 402:
        return UpstreamError(
            "upstream_payment_required",
            "The provider account has no balance",
            status=status,
        )
    if status == 404:
        return UpstreamError(
            "model_not_found", "The provider does not know this model", status=status
        )
    if status == 429:
        return UpstreamError(
            "upstream_rate_limited",
            "The provider rate limit was hit",
            retryable=True,
            status=status,
            retry_after=retry_after,
        )
    if status in {408, 504}:
        return UpstreamError(
            "upstream_timeout",
            "The provider timed out",
            retryable=True,
            status=status,
            retry_after=retry_after,
        )
    if status >= 500:
        return UpstreamError(
            "upstream_error",
            "The provider failed",
            retryable=True,
            status=status,
            retry_after=retry_after,
        )
    return UpstreamError("upstream_rejected", "The provider rejected the request", status=status)


def _retry_after(response: httpx.Response) -> float | None:
    raw = response.headers.get("retry-after", "")
    try:
        return min(max(float(raw), 0.0), MAX_RETRY_AFTER)
    except ValueError:
        return None


def _timeout_error(what: str) -> UpstreamError:
    return UpstreamError(
        "upstream_timeout", f"The provider did not answer in time ({what})", retryable=True
    )


class UpstreamClient:
    def __init__(self, settings: Settings, http: httpx.AsyncClient | None = None) -> None:
        self._settings = settings
        self._key = settings.polza_api_key
        self._base = settings.polza_base_url.rstrip("/")
        self._http = http or httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=settings.polza_connect_timeout, read=None, write=10.0, pool=5.0
            ),
            follow_redirects=False,
        )

    @property
    def configured(self) -> bool:
        return self._key is not None

    async def aclose(self) -> None:
        await self._http.aclose()

    def _auth_headers(self) -> dict[str, str]:
        assert self._key is not None  # noqa: S101 - callers check ``configured``
        return {"Authorization": f"Bearer {self._key.get_secret_value()}"}

    async def _pause(self, attempt: int, error: UpstreamError) -> None:
        delay = self._settings.polza_retry_backoff * 2**attempt
        if error.retry_after is not None:
            delay = max(delay, error.retry_after)
        await asyncio.sleep(delay)

    # ------------------------------------------------------------------ models

    async def get_models(self) -> list[dict[str, Any]]:
        """``GET /models`` (public: no key is sent). Retries like a stream before its first byte."""
        attempt = 0
        while True:
            try:
                return await self._get_models_once()
            except UpstreamError as error:
                if not error.retryable or attempt >= self._settings.polza_max_retries:
                    raise
                log.warning("models_retry", code=error.code, status=error.status, attempt=attempt)
                await self._pause(attempt, error)
                attempt += 1

    async def _get_models_once(self) -> list[dict[str, Any]]:
        try:
            async with asyncio.timeout(self._settings.polza_first_byte_timeout):
                response = await self._http.get(f"{self._base}/models")
        except TimeoutError as exc:
            raise _timeout_error("models") from exc
        except httpx.TimeoutException as exc:
            raise _timeout_error("models") from exc
        except httpx.HTTPError as exc:
            raise UpstreamError(
                "upstream_error", "The provider is unreachable", retryable=True
            ) from exc
        if response.status_code >= 400:
            raise error_for_status(response.status_code, _retry_after(response))
        if len(response.content) > MAX_MODELS_BYTES:
            raise UpstreamError("upstream_error", "The model list is too large")
        try:
            body = response.json()
        except ValueError as exc:
            raise UpstreamError("upstream_error", "The model list is not JSON") from exc
        items = body.get("data") if isinstance(body, dict) else body
        if not isinstance(items, list):
            raise UpstreamError("upstream_error", "The model list has an unexpected shape")
        return [item for item in items if isinstance(item, dict)]

    # ------------------------------------------------------------------ chat stream

    async def stream_chat(self, payload: dict[str, Any]) -> AsyncIterator[dict[str, Any]]:
        """Yield the decoded ``data:`` objects of one streamed completion.

        Retries (connection errors, timeouts of the first byte, 408/429/5xx) happen only while
        nothing has been yielded. Closing the generator closes the provider connection.
        """
        deadline = time.monotonic() + self._settings.polza_total_timeout
        attempt = 0
        while True:
            started = False
            try:
                async for chunk in self._attempt(payload, deadline):
                    started = True
                    yield chunk
                return
            except UpstreamError as error:
                if started or not error.retryable or attempt >= self._settings.polza_max_retries:
                    raise
                log.warning("stream_retry", code=error.code, status=error.status, attempt=attempt)
                await self._pause(attempt, error)
                attempt += 1

    async def _attempt(
        self, payload: dict[str, Any], deadline: float
    ) -> AsyncIterator[dict[str, Any]]:
        settings = self._settings
        first_deadline = min(deadline, time.monotonic() + settings.polza_first_byte_timeout)
        request = self._http.build_request(
            "POST",
            f"{self._base}/chat/completions",
            json=payload,
            headers={**self._auth_headers(), "Accept": "text/event-stream"},
        )
        response: httpx.Response | None = None
        try:
            try:
                async with asyncio.timeout(max(first_deadline - time.monotonic(), 0.001)):
                    response = await self._http.send(request, stream=True)
            except (TimeoutError, httpx.TimeoutException) as exc:
                raise _timeout_error("connect") from exc
            except httpx.HTTPError as exc:
                raise UpstreamError(
                    "upstream_error", "The provider is unreachable", retryable=True
                ) from exc
            if response.status_code >= 400:
                raise error_for_status(response.status_code, _retry_after(response))
            first = True
            lines = response.aiter_lines()
            while True:
                limit = first_deadline if first else time.monotonic() + settings.polza_idle_timeout
                limit = min(limit, deadline)
                try:
                    async with asyncio.timeout(max(limit - time.monotonic(), 0.001)):
                        line = await anext(lines)
                except StopAsyncIteration:
                    if first:  # nothing arrived at all: worth a retry
                        raise UpstreamError(
                            "upstream_error", "The provider closed the stream early", retryable=True
                        ) from None
                    return  # ended without [DONE]; the consumer checks for a finish reason
                except (TimeoutError, httpx.TimeoutException) as exc:
                    raise _timeout_error("stream") from exc
                except httpx.HTTPError as exc:
                    raise UpstreamError(
                        "upstream_error", "The provider stream broke", retryable=True
                    ) from exc
                event = _decode_line(line)
                if event is None:
                    continue
                if isinstance(event, str):  # [DONE]
                    return
                first = False
                yield event
        finally:
            if response is not None:
                await response.aclose()


_DONE = "done"


def _decode_line(line: str) -> dict[str, Any] | str | None:
    """One SSE line -> a decoded object, ``_DONE``, or ``None`` (comments, other fields)."""
    if not line.startswith("data:"):
        return None
    data = line[5:].strip()
    if data == "[DONE]":
        return _DONE
    try:
        decoded = json.loads(data)
    except ValueError as exc:
        raise UpstreamError("upstream_error", "The provider sent malformed data") from exc
    if not isinstance(decoded, dict):
        raise UpstreamError("upstream_error", "The provider sent an unexpected event")
    if "error" in decoded and "choices" not in decoded:
        raise UpstreamError("upstream_error", "The provider reported an error")
    return decoded
