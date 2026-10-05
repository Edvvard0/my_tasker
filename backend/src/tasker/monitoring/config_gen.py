"""The engine configuration, generated from the owner's data (spec stage9, sections 4 and 5).

Nothing here is secret: only the targets the owner typed in. Every check is judged again before it
is written (the rows may predate a stricter rule and a name may have started to resolve to a
private address); a check that fails is left out and reported, never fixed silently.
"""

import asyncio
import hashlib
import ipaddress
import json
import socket
from collections.abc import Awaitable, Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any

from tasker.monitoring import targets

Resolver = Callable[[str], Awaitable[list[str]]]
DEFAULT_SSL_DAYS = 14
DEFAULT_SSL_PORT = 443
SENTINEL_NAME = "engine-self"
RESOLVE_TIMEOUT = 3.0
RESOLVE_PARALLEL = 10
RESOLVE_FAILED = "resolve_failed"  # the name did not resolve now: not judged, so not configured


@dataclass(frozen=True, slots=True)
class CheckSpec:
    id: str
    service_id: str
    kind: str
    interval_seconds: int
    timeout_seconds: int
    url: str | None = None
    host: str | None = None
    port: int | None = None
    dns_record_type: str | None = None
    expected_status: int | None = None
    expected_value: str | None = None
    keyword: str | None = None
    ssl_min_days: int | None = None


@dataclass(frozen=True, slots=True)
class ConfigResult:
    text: str
    digest: str
    active: list[str]
    rejected: list[dict[str, str]]


class ResolveError(Exception):
    """The name could not be resolved (timeout, SERVFAIL, NXDOMAIN, any resolver error)."""


async def system_resolver(host: str) -> list[str]:
    """Addresses of a name through the system resolver. A name that does not resolve — for any
    reason: a timeout and SERVFAIL as much as NXDOMAIN — raises ``ResolveError``: what cannot be
    judged is not let through (fail closed)."""
    loop = asyncio.get_running_loop()
    try:
        info = await asyncio.wait_for(
            loop.getaddrinfo(host, None, type=socket.SOCK_STREAM), RESOLVE_TIMEOUT
        )
    except (OSError, TimeoutError) as exc:
        raise ResolveError(type(exc).__name__) from None
    return sorted({str(item[4][0]) for item in info})


def target_host(check: CheckSpec) -> str | None:
    """The host the engine connects to for this check (``None``: nothing is connected to)."""
    if check.kind == "http":
        verdict = targets.check_url(check.url or "")
    elif check.kind == "dns":
        verdict = targets.check_host(check.host or "")
        return verdict.host if verdict.valid else None
    else:
        verdict = targets.check_host(check.host or "")
    return verdict.host if verdict.valid else None


def _is_ip(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def syntactic_problem(check: CheckSpec) -> str | None:
    if check.kind == "http":
        verdict = targets.check_url(check.url or "")
    else:
        verdict = targets.check_host(check.host or "")
    return None if verdict.valid else f"target_{verdict.reason}"


def _duration(seconds: int) -> str:
    return f"{seconds}s"


def _host_in_url(host: str) -> str:
    return f"[{host}]" if ":" in host else host


def endpoint_for(check: CheckSpec, dns_resolver: str) -> dict[str, Any]:
    """The engine endpoint of a check that passed the target rules."""
    endpoint: dict[str, Any] = {"name": check.id, "group": check.service_id}
    host = target_host(check) or check.host or ""  # normalised: lower case, no brackets, no dot
    client = {"timeout": _duration(check.timeout_seconds), "ignore-redirect": True}
    conditions: list[str]
    if check.kind == "http":
        endpoint["url"] = check.url
        conditions = [
            f"[STATUS] == {check.expected_status}" if check.expected_status else "[STATUS] < 400"
        ]
        if check.keyword:
            conditions.append(f"[BODY] == pat(*{check.keyword}*)")
    elif check.kind == "tcp":
        endpoint["url"] = f"tcp://{_host_in_url(host)}:{check.port}"
        conditions = ["[CONNECTED] == true"]
    elif check.kind == "dns":
        endpoint["url"] = dns_resolver
        endpoint["dns"] = {"query-name": host, "query-type": check.dns_record_type}
        conditions = ["[DNS_RCODE] == NOERROR"]
        if check.expected_value:
            conditions.append(f"[BODY] == pat(*{check.expected_value}*)")
    else:  # ssl
        port = check.port or DEFAULT_SSL_PORT
        endpoint["url"] = f"https://{_host_in_url(host)}:{port}"
        days = check.ssl_min_days or DEFAULT_SSL_DAYS
        conditions = ["[CONNECTED] == true", f"[CERTIFICATE_EXPIRATION] > {days * 24}h"]
    endpoint["interval"] = _duration(check.interval_seconds)
    if check.kind != "dns":
        endpoint["client"] = client
    endpoint["conditions"] = conditions
    return endpoint


# A tiny YAML writer: block style, every string as a JSON (= YAML double-quoted) scalar, so a
# value can never be read as anything but text.


def _scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=True)


def _emit(value: Any, indent: int, out: list[str]) -> None:
    pad = "  " * indent
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, dict | list) and item:
                out.append(f"{pad}{key}:")
                _emit(item, indent + 1, out)
            else:
                out.append(
                    f"{pad}{key}: {_scalar(item) if not isinstance(item, dict | list) else '[]'}"
                )
    else:
        for item in value:
            if isinstance(item, dict):
                body: list[str] = []
                _emit(item, indent + 1, body)
                out.append(f"{pad}- {body[0].lstrip()}")
                out.extend(body[1:])
            else:
                out.append(f"{pad}- {_scalar(item)}")


def render_yaml(document: Mapping[str, Any]) -> str:
    out: list[str] = []
    _emit(dict(document), 0, out)
    return "\n".join(out) + "\n"


def sentinel_endpoint() -> dict[str, Any]:
    """Keeps the engine running when the owner has no checks (it refuses an empty list): it asks
    the engine's own health page and is ignored by the ingest (its name is not a check id)."""
    return {
        "name": SENTINEL_NAME,
        "url": "http://127.0.0.1:8080/health",
        "interval": "60s",
        "conditions": ["[STATUS] == 200"],
    }


def document_for(endpoints: Iterable[dict[str, Any]]) -> dict[str, Any]:
    return {
        "storage": {
            "type": "sqlite",
            "path": "/data/data.db",
            "maximum-number-of-results": 200,
            "maximum-number-of-events": 50,
        },
        "web": {"address": "0.0.0.0", "port": 8080},  # noqa: S104 - the engine's own container
        "endpoints": [*endpoints, sentinel_endpoint()],
    }


async def build_config(
    checks: Iterable[CheckSpec], resolve: Resolver, dns_resolver: str
) -> ConfigResult:
    """Judge every check (syntax, then what its host resolves to) and render the engine file."""
    ordered = sorted(checks, key=lambda c: c.id)
    rejected: list[dict[str, str]] = []
    judged: list[tuple[CheckSpec, str | None]] = [(c, syntactic_problem(c)) for c in ordered]
    gate = asyncio.Semaphore(RESOLVE_PARALLEL)

    async def judge(check: CheckSpec, problem: str | None) -> str | None:
        if problem is not None:
            return problem
        if check.kind == "dns":
            return None  # the owner's name is only asked of the public resolver
        host = target_host(check)
        assert host is not None  # noqa: S101 - the syntactic judgement above passed
        if _is_ip(host):
            return None  # an IP literal: already judged
        async with gate:
            try:
                addresses = await resolve(host)
            except Exception:  # whatever the resolver does: a name that was not judged is out
                return RESOLVE_FAILED
        if not addresses:
            return RESOLVE_FAILED
        return targets.check_addresses(addresses)

    verdicts = await asyncio.gather(*(judge(c, p) for c, p in judged))
    endpoints = []
    active = []
    for (check, _), problem in zip(judged, verdicts, strict=True):
        if problem is not None:
            rejected.append({"check_id": check.id, "reason": problem})
            continue
        endpoints.append(endpoint_for(check, dns_resolver))
        active.append(check.id)
    text = render_yaml(document_for(endpoints))
    return ConfigResult(text, hashlib.sha256(text.encode()).hexdigest(), active, rejected)
