"""Columns and validators of the Stage 9 tables (spec: ``docs/specs/stage9_monitoring.md``).

These are the entities the owner types in: servers, services (projects on a server, the cards of
the "Pulse" screen) and checks. What the engine measures (results, incidents, alert state) is not
synchronised: it lives in server-only tables (``tasker.monitoring.storage``).
"""

from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from tasker.monitoring import targets
from tasker.sync.registry import (
    ColumnSpec,
    bool_column,
    enum_column,
    int_column,
    reference_column,
    text_column,
    uuid_column,
)

Row = Mapping[str, Any]

CHECK_KINDS = ("http", "tcp", "dns", "ssl")
DNS_RECORD_TYPES = ("A", "AAAA", "CNAME", "MX", "NS", "TXT")

MIN_INTERVAL, MAX_INTERVAL = 10, 3600
MAX_TIMEOUT = 30
# One token the engine can match literally: no spaces, wildcards, quotes or brackets.
KEYWORD_PATTERN = r"^[^\s*()\[\]'\"\\<>=!$`]{1,100}$"
EXPECTED_VALUE_PATTERN = r"^[A-Za-z0-9._:/-]{1,253}$"


def _blank(value: object) -> bool:
    return not str(value).strip()


def _fixed(column: ColumnSpec) -> ColumnSpec:
    return replace(column, immutable=True)


# ------------------------------------------------------------------ monitor_servers

SERVER_COLUMNS: tuple[ColumnSpec, ...] = (
    text_column("name", min_length=1, max_length=100),
    text_column("host", min_length=1, max_length=253),
    text_column("provider", max_length=100, nullable=True, required=False),
    text_column("note", max_length=2000, nullable=True, required=False),
)


def server_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    verdict = targets.check_host(row["host"])
    return None if verdict.valid else f"host is not an allowed target ({verdict.reason})"


# ------------------------------------------------------------------ monitor_services

SERVICE_COLUMNS: tuple[ColumnSpec, ...] = (
    _fixed(reference_column("server_id", "monitor_servers")),
    text_column("name", min_length=1, max_length=100),
    uuid_column("work_project_id", nullable=True, required=False),
    bool_column("critical"),
    text_column("note", max_length=2000, nullable=True, required=False),
)


def service_problem(row: Row) -> str | None:
    return "name must not be blank" if _blank(row["name"]) else None


# ------------------------------------------------------------------ monitor_checks

CHECK_COLUMNS: tuple[ColumnSpec, ...] = (
    _fixed(reference_column("service_id", "monitor_services")),
    _fixed(enum_column("kind", CHECK_KINDS)),
    text_column("name", min_length=1, max_length=100),
    text_column("url", max_length=targets.MAX_URL_LENGTH, nullable=True, required=False),
    text_column("host", max_length=253, nullable=True, required=False),
    int_column("port", ge=1, le=65535, nullable=True, required=False),
    enum_column("dns_record_type", DNS_RECORD_TYPES, nullable=True, required=False),
    text_column(
        "expected_value",
        max_length=253,
        pattern=EXPECTED_VALUE_PATTERN,
        nullable=True,
        required=False,
    ),
    int_column("expected_status", ge=100, le=599, nullable=True, required=False),
    text_column("keyword", max_length=100, pattern=KEYWORD_PATTERN, nullable=True, required=False),
    int_column("ssl_min_days", ge=1, le=365, nullable=True, required=False),
    int_column("interval_seconds", ge=MIN_INTERVAL, le=MAX_INTERVAL),
    int_column("timeout_seconds", ge=1, le=MAX_TIMEOUT),
)

# Which optional columns a kind uses (everything else must be null).
USED: dict[str, set[str]] = {
    "http": {"url", "expected_status", "keyword"},
    "tcp": {"host", "port"},
    "dns": {"host", "dns_record_type", "expected_value"},
    "ssl": {"host", "port", "ssl_min_days"},
}
REQUIRED: dict[str, tuple[str, ...]] = {
    "http": ("url",),
    "tcp": ("host", "port"),
    "dns": ("host", "dns_record_type"),
    "ssl": ("host",),
}
OPTIONAL_COLUMNS = (
    "url",
    "host",
    "port",
    "dns_record_type",
    "expected_value",
    "expected_status",
    "keyword",
    "ssl_min_days",
)


def check_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    kind = row["kind"]
    for name in OPTIONAL_COLUMNS:
        if row[name] is not None and name not in USED[kind]:
            return f"{name} does not go with a {kind} check"
    for name in REQUIRED[kind]:
        if row[name] is None:
            return f"a {kind} check needs {name}"
    if row["timeout_seconds"] >= row["interval_seconds"]:
        return "timeout_seconds must be less than interval_seconds"
    verdict = targets.check_url(row["url"]) if kind == "http" else targets.check_host(row["host"])
    if not verdict.valid:
        return f"target is not allowed ({verdict.reason})"
    return None
