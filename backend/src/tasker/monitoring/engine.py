"""The check engine behind an interface: ``EngineClient.fetch()`` returns the recent results of
every endpoint. The shipped engine is Gatus (spec stage9, section 1); replacing it means a new
implementation of this one protocol plus ``config_gen`` — nothing else knows the engine.
"""

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

import httpx

PAGE_SIZE = 100
MAX_PAGES = 50
MAX_ERROR = 200


class EngineError(Exception):
    """The engine did not answer usefully. ``code`` is safe to log and to show."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True, slots=True)
class EngineResult:
    check_id: uuid.UUID
    at: datetime
    ok: bool
    duration_ms: int | None
    error: str | None


class EngineClient(Protocol):
    async def fetch(self) -> list[EngineResult]: ...


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC).replace(microsecond=0)


def _failure_text(result: dict[str, Any]) -> str:
    errors = result.get("errors")
    if isinstance(errors, list) and errors and isinstance(errors[0], str):
        return errors[0][:MAX_ERROR]
    status = result.get("status")
    for condition in result.get("conditionResults") or ():
        if isinstance(condition, dict) and condition.get("success") is False:
            text = f"условие не выполнено: {condition.get('condition')}"
            return (f"HTTP {status}, {text}" if status else text)[:MAX_ERROR]
    return f"HTTP {status}" if status else "сбой проверки"


def parse_statuses(payload: Any) -> list[EngineResult]:
    """Gatus ``/api/v1/endpoints/statuses`` -> results. An endpoint whose ``name`` is not a check id
    (the engine's own sentinel) is skipped, a malformed result is skipped, the rest is kept.
    ``duration`` is nanoseconds (Go ``time.Duration``), cut to whole milliseconds."""
    if not isinstance(payload, list):
        raise EngineError("engine_bad_response")
    found: list[EngineResult] = []
    for endpoint in payload:
        if not isinstance(endpoint, dict):
            continue
        try:
            check_id = uuid.UUID(str(endpoint.get("name")))
        except ValueError:
            continue
        for result in endpoint.get("results") or ():
            if not isinstance(result, dict) or not isinstance(result.get("success"), bool):
                continue
            at = _timestamp(result.get("timestamp"))
            if at is None:
                continue
            duration = result.get("duration")
            ms = duration // 1_000_000 if type(duration) is int and duration >= 0 else None
            ok = result["success"]
            found.append(EngineResult(check_id, at, ok, ms, None if ok else _failure_text(result)))
    return found


class GatusClient:
    """Reads Gatus over HTTP (``GET /api/v1/endpoints/statuses``, paged)."""

    def __init__(self, base_url: str, http: httpx.AsyncClient, *, timeout: float = 10.0) -> None:
        self._base = base_url.rstrip("/")
        self._http = http
        self._timeout = timeout

    async def fetch(self) -> list[EngineResult]:
        collected: list[EngineResult] = []
        for page in range(1, MAX_PAGES + 1):
            try:
                response = await self._http.get(
                    f"{self._base}/api/v1/endpoints/statuses",
                    params={"page": page, "pageSize": PAGE_SIZE},
                    timeout=self._timeout,
                )
            except httpx.HTTPError as exc:
                raise EngineError("engine_unreachable") from exc
            if response.status_code != 200:
                raise EngineError("engine_bad_status")
            try:
                payload = response.json()
            except ValueError as exc:
                raise EngineError("engine_bad_response") from exc
            collected.extend(parse_statuses(payload))
            if not isinstance(payload, list) or len(payload) < PAGE_SIZE:
                break
        return collected
