"""The engine adapter on a (hand-written, Gatus-shaped) recording and on a fake HTTP server."""

import json
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
import pytest

from tasker.monitoring.engine import PAGE_SIZE, EngineError, GatusClient, parse_statuses

DATA = Path(__file__).parent / "data" / "monitoring" / "gatus_statuses.json"
A = uuid.UUID("0192d5a0-0000-7000-8000-000000000001")
B = uuid.UUID("0192d5a0-0000-7000-8000-000000000002")


def recorded() -> list[dict[str, Any]]:
    payload: list[dict[str, Any]] = json.loads(DATA.read_text(encoding="utf-8"))
    return payload


def test_parse_statuses_reads_results_and_skips_the_rest() -> None:
    found = parse_statuses(recorded())
    by_check = {c: [r for r in found if r.check_id == c] for c in (A, B)}
    assert [(r.ok, r.duration_ms) for r in by_check[A]] == [(True, 145), (True, 151), (False, 90)]
    assert by_check[A][0].at == datetime(2026, 10, 4, 10, 0, 0, tzinfo=UTC)  # fractions dropped
    assert by_check[A][2].error == "HTTP 502, условие не выполнено: [STATUS] < 400"
    assert by_check[A][0].error is None
    assert by_check[B][0].error == "dial tcp 93.184.216.34:5432: i/o timeout"
    assert by_check[B][0].duration_ms == 5000
    assert by_check[B][1].at == datetime(2026, 10, 4, 10, 0, 42, tzinfo=UTC)  # +03:00 -> UTC
    # the sentinel endpoint, a non-boolean success, a bad timestamp: left out; a negative duration
    # is kept without a time
    assert all(
        r.check_id in (A, B, uuid.UUID("0192d5a0-0000-7000-8000-000000000003")) for r in found
    )
    third = [r for r in found if str(r.check_id).endswith("3")]
    assert [(r.ok, r.duration_ms) for r in third] == [(True, None)]
    assert len(found) == 3 + 2 + 1


def test_parse_statuses_failure_texts() -> None:
    def one(**result: Any) -> str | None:
        payload = [
            {
                "name": str(A),
                "results": [{"success": False, "timestamp": "2026-10-04T10:00:00Z", **result}],
            }
        ]
        return parse_statuses(payload)[0].error

    assert one(status=0) == "сбой проверки"
    assert one(status=503) == "HTTP 503"
    assert one(errors=["x" * 500]) == "x" * 200
    assert one(
        errors=[], conditionResults=[{"condition": "[CONNECTED] == true", "success": False}]
    ) == ("условие не выполнено: [CONNECTED] == true")
    assert one(conditionResults=[{"condition": "a", "success": True}], status=200) == "HTTP 200"


def test_timestamps_without_a_zone_are_utc_and_odd_ones_are_skipped() -> None:
    def stamp(value: Any) -> list[Any]:
        return parse_statuses(
            [{"name": str(A), "results": [{"success": True, "timestamp": value}]}]
        )

    assert stamp("2026-10-04T10:00:00")[0].at == datetime(2026, 10, 4, 10, 0, 0, tzinfo=UTC)
    assert stamp(1790000000) == [] and stamp(None) == []


def test_parse_statuses_rejects_a_payload_that_is_not_a_list() -> None:
    with pytest.raises(EngineError) as info:
        parse_statuses({"error": "nope"})
    assert info.value.code == "engine_bad_response"
    assert parse_statuses([1, "x", None, {"name": 5}]) == []


def client_for(handler: Any) -> GatusClient:
    return GatusClient(
        "http://gatus:8080/", httpx.AsyncClient(transport=httpx.MockTransport(handler))
    )


async def test_the_client_reads_every_page() -> None:
    pages: list[int] = []
    full = [{"name": str(uuid.uuid4()), "results": []} for _ in range(PAGE_SIZE)]

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/endpoints/statuses"
        page = int(request.url.params["page"])
        assert request.url.params["pageSize"] == str(PAGE_SIZE)
        pages.append(page)
        if page == 1:
            return httpx.Response(200, json=full)
        return httpx.Response(200, json=recorded())

    found = await client_for(handler).fetch()
    assert pages == [1, 2]
    assert len(found) == 6


async def test_the_client_maps_failures_to_safe_codes() -> None:
    def refused(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom http://secret-host", request=request)

    cases = [
        (refused, "engine_unreachable"),
        (lambda r: httpx.Response(500), "engine_bad_status"),
        (lambda r: httpx.Response(200, content=b"<html>"), "engine_bad_response"),
        (lambda r: httpx.Response(200, json={"a": 1}), "engine_bad_response"),
    ]
    for handler, code in cases:
        with pytest.raises(EngineError) as info:
            await client_for(handler).fetch()
        assert info.value.code == code
        assert "secret-host" not in str(info.value)
