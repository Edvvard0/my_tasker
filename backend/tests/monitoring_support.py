"""Builders of valid Stage 9 rows, a fake engine and a fake Telegram."""

import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from tasker.ids import uuid7
from tasker.monitoring.engine import EngineError, EngineResult
from tasker.monitoring.telegram import SendResult
from tests.api_support import DeviceClient


def server_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {"name": "VPS Берлин", "host": "vps.example.com", "created_at": dc.created(), **over}


def service_fields(dc: DeviceClient, server: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "server_id": str(server),
        "name": "Сайт",
        "critical": False,
        "created_at": dc.created(),
        **over,
    }


def check_fields(dc: DeviceClient, service: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "service_id": str(service),
        "kind": "http",
        "name": "Главная",
        "url": "https://example.com/",
        "interval_seconds": 20,
        "timeout_seconds": 5,
        "created_at": dc.created(),
        **over,
    }


@dataclass
class Graph:
    server: uuid.UUID
    service: uuid.UUID
    check: uuid.UUID


async def make_graph(
    dc: DeviceClient, *, critical: bool = False, checks: int = 1, **check_over: Any
) -> tuple[Graph, list[uuid.UUID]]:
    """One server, one service and ``checks`` HTTP checks; returns the graph and all check ids."""
    graph = Graph(uuid7(), uuid7(), uuid7())
    ids = [graph.check] + [uuid7() for _ in range(checks - 1)]
    ops = [
        dc.op("monitor_servers", graph.server, fields=server_fields(dc)),
        dc.op(
            "monitor_services",
            graph.service,
            fields=service_fields(dc, graph.server, critical=critical),
        ),
    ]
    for i, check_id in enumerate(ids):
        ops.append(
            dc.op(
                "monitor_checks",
                check_id,
                fields=check_fields(dc, graph.service, name=f"Проверка {i}", **check_over),
            )
        )
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return graph, ids


T0 = datetime(2026, 10, 1, 12, 0, 0, tzinfo=UTC)


def result(
    check: uuid.UUID, seconds: int, ok: bool = True, ms: int = 100, error: str | None = None
) -> EngineResult:
    return EngineResult(
        check,
        T0 + timedelta(seconds=seconds),
        ok,
        ms if ok else None,
        None if ok else (error or "HTTP 502"),
    )


@dataclass
class FakeEngine:
    results: list[EngineResult] = field(default_factory=list)
    error: str | None = None
    calls: int = 0

    async def fetch(self) -> list[EngineResult]:
        self.calls += 1
        if self.error:
            raise EngineError(self.error)
        return list(self.results)


@dataclass
class FakeNotifier:
    outcomes: list[SendResult] = field(default_factory=list)
    sent: list[str] = field(default_factory=list)
    attempts: int = 0
    is_configured: bool = True

    @property
    def configured(self) -> bool:
        return self.is_configured

    async def send(self, text: str) -> SendResult:
        self.attempts += 1
        outcome = self.outcomes.pop(0) if self.outcomes else SendResult(True)
        if outcome.ok:
            self.sent.append(text)
        return outcome
