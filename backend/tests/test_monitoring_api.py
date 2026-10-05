"""The Pulse endpoints: authorization, the snapshot and its cache tag, incidents, "Check now", the
self-check and the Telegram test. No secret ever appears in an answer or a log line."""

import json
import uuid
from collections.abc import AsyncIterator
from datetime import timedelta
from typing import Any

import httpx
import pytest

from tasker.monitoring import service
from tasker.monitoring.telegram import TelegramNotifier
from tests.api_support import SCHEMA, DeviceClient, Env, make_env
from tests.monitoring_support import T0, FakeEngine, make_graph, result

TOKEN = "987654:API-test-token-not-real"  # gitleaks:allow
CHAT = "-1004242424242"
ENGINE_URL = "http://gatus.internal-test:8080"


@pytest.fixture
async def menv(migrated_db_url: str) -> AsyncIterator[Env]:
    async with make_env(
        migrated_db_url,
        monitor_engine_url=ENGINE_URL,
        telegram_bot_token=TOKEN,
        telegram_chat_id=CHAT,
    ) as environment:
        yield environment


def use(env: Env, engine: FakeEngine | None = None, handler: Any = None) -> FakeEngine:
    """Swap the engine and the Telegram transport of the running app for fakes."""
    mon = env.app.state.monitoring
    fake = engine or FakeEngine()
    mon.engine = fake
    http = httpx.AsyncClient(
        transport=httpx.MockTransport(handler or (lambda r: httpx.Response(200, json={"ok": True})))
    )
    mon.notifier = TelegramNotifier(TOKEN, CHAT, http)
    return fake


async def cycle(env: Env, engine: FakeEngine, seconds: int) -> None:
    env.clock.current = T0 + timedelta(seconds=seconds)
    await service.poll_cycle(env.sessionmaker, engine, env.app.state.monitoring.settings, env.clock)


def raw(env: Env, dc: DeviceClient | None, method: str, path: str, **kwargs: Any) -> Any:
    headers = dc.headers if dc else dict(SCHEMA)
    return env.client.request(
        method, path, headers={**headers, **kwargs.pop("headers", {})}, **kwargs
    )


ENDPOINTS = [
    ("GET", "/monitoring/pulse"),
    ("POST", "/monitoring/refresh"),
    ("GET", "/monitoring/incidents"),
    ("GET", "/monitoring/self-check"),
    ("POST", "/monitoring/telegram/test"),
]


async def test_every_endpoint_needs_a_signed_in_device(menv: Env) -> None:
    phone = await menv.login()
    for method, path in ENDPOINTS:
        assert (await raw(menv, None, method, path)).status_code == 401, path
        bad = await menv.client.request(
            method, path, headers={**SCHEMA, "Authorization": "Bearer nope"}
        )
        assert bad.status_code == 401, path
        assert (
            await menv.client.request(
                method, path, headers=dict(phone.headers, **{"X-Client-Schema-Version": "0"})
            )
        ).status_code in (400, 426), path


async def test_an_empty_pulse(menv: Env) -> None:
    phone = await menv.login()
    use(menv)
    body = (await phone.get("/monitoring/pulse")).json()
    assert body["services"] == []
    assert body["summary"] == {"services": 0, "down": 0, "up": 0, "unknown": 0}
    assert body["engine"] == {
        "configured": True,
        "last_poll_at": None,
        "healthy": False,
        "error": None,
        "telegram_configured": True,
    }


async def test_the_pulse_shows_down_first_with_numbers_and_a_stable_etag(menv: Env) -> None:
    phone = await menv.login()
    engine = use(menv)
    graph_a, (a,) = await make_graph(phone)  # "Сайт": will fall
    graph_b, (b,) = await make_graph(phone)  # the second "Сайт": stays up
    await phone.push_ok(
        [phone.op("monitor_services", graph_b.service, fields={"name": "Аптайм"}, base=1)]
    )
    engine.results = [result(a, s, ok=s < 20) for s in (0, 20, 40, 60)] + [
        result(b, 0, ms=250),
        result(b, 20, ms=350),
    ]
    await cycle(menv, engine, 61)
    await cycle(menv, engine, 80)

    response = await phone.get("/monitoring/pulse")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "private, no-cache"
    body = response.json()
    assert [s["status"] for s in body["services"]] == ["down", "up"]  # the fallen card first
    down, up = body["services"]
    assert down["name"] == "Сайт" and up["name"] == "Аптайм"
    assert down["server_id"] == str(graph_a.server) and down["open_incident"] is not None
    assert down["down_since"] == "2026-10-01T12:00:20Z"
    assert down["availability"]["h24"] == 2500 and down["response_ms"] is None
    assert up["availability"]["d30"] == 10000 and up["response_ms"] == 350
    assert body["summary"] == {"services": 2, "down": 1, "up": 1, "unknown": 0}
    assert body["engine"]["healthy"] is True
    (check,) = down["checks"]
    assert (
        check["kind"] == "http"
        and check["status"] == "down"
        and check["spark"] == [100, -1, -1, -1]
    )

    etag = response.headers["etag"]
    same = await phone.get("/monitoring/pulse")
    assert same.headers["etag"] == etag  # a later poll with nothing new keeps the tag
    cached = await menv.client.get(
        "/monitoring/pulse", headers={**phone.headers, "If-None-Match": etag}
    )
    assert cached.status_code == 304 and cached.content == b""
    engine.results.append(result(b, 40, ms=500))
    await cycle(menv, engine, 100)
    changed = await menv.client.get(
        "/monitoring/pulse", headers={**phone.headers, "If-None-Match": etag}
    )
    assert changed.status_code == 200 and changed.headers["etag"] != etag


async def test_incidents_page_back_in_time(menv: Env) -> None:
    phone = await menv.login()
    engine = use(menv)
    graph, (check,) = await make_graph(phone)
    clock = 0
    for _ in range(3):  # three outages of 60 s, each followed by a recovery
        engine.results += [result(check, clock + s, ok=False) for s in (0, 20, 40)]
        engine.results += [result(check, clock + 60, ok=True), result(check, clock + 80, ok=True)]
        clock += 4000
    for seconds in range(0, 12000, 2000):
        await cycle(menv, engine, seconds + 100)
    await cycle(menv, engine, 12001)
    await phone.refresh()  # the clock ran past the access token
    first = (await phone.get("/monitoring/incidents", limit=2)).json()
    assert len(first["incidents"]) == 2 and first["next_before"] is not None
    newest, older = first["incidents"]
    assert newest["started_at"] > older["started_at"]
    assert newest["service_name"] == "Сайт" and newest["reason"] == "HTTP 502"
    assert newest["duration_seconds"] == 80 and newest["check_ids"] == [str(check)]
    rest = (
        await phone.get(
            "/monitoring/incidents",
            limit=2,
            before=first["next_before"],
            before_id=first["next_before_id"],
        )
    ).json()
    assert len(rest["incidents"]) == 1 and rest["next_before"] is None
    only = (await phone.get("/monitoring/incidents", service_id=str(graph.service))).json()
    assert len(only["incidents"]) == 3
    none = (
        await phone.get("/monitoring/incidents", service_id="0192d5a0-0000-7000-8000-00000000ffff")
    ).json()
    assert none == {"incidents": [], "next_before": None, "next_before_id": None}
    for bad in (
        {"before": "yesterday"},
        {"before": "2026-13-45T00:00:00Z"},
        {"limit": 0},
        {"limit": 101},
        {"service_id": "x"},
    ):
        assert (await phone.get("/monitoring/incidents", **bad)).status_code == 422


async def test_refresh_reads_the_engine_but_not_twice_in_five_seconds(menv: Env) -> None:
    phone = await menv.login()
    _, (check,) = await make_graph(phone)
    engine = use(menv, FakeEngine([result(check, 0)]))
    menv.clock.current = T0 + timedelta(seconds=10)
    first = await phone.post("/monitoring/refresh")
    assert first.status_code == 200 and engine.calls == 1
    assert first.json()["services"][0]["status"] == "up"
    menv.clock.current = T0 + timedelta(seconds=12)
    await phone.post("/monitoring/refresh")
    assert engine.calls == 1  # too soon: the known state is returned
    menv.clock.current = T0 + timedelta(seconds=16)
    await phone.post("/monitoring/refresh")
    assert engine.calls == 2


async def test_refresh_without_an_engine_says_so(env: Env) -> None:
    phone = await env.login()
    response = await phone.post("/monitoring/refresh")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "monitoring_not_configured"
    body = (await phone.get("/monitoring/pulse")).json()
    assert body["engine"]["configured"] is False and body["engine"]["telegram_configured"] is False


async def test_self_check_tells_the_state_of_the_monitoring(menv: Env) -> None:
    phone = await menv.login()
    engine = use(menv)
    empty = (await phone.get("/monitoring/self-check")).json()
    assert empty["engine"] == {
        "configured": True,
        "last_poll_at": None,
        "lag_seconds": None,
        "error": None,
    }
    assert empty["telegram"] == {
        "configured": True,
        "last_success_at": None,
        "last_error": None,
        "queued": 0,
    }
    assert empty["config"] == {"synced_at": None, "checks_active": 0, "checks_rejected": []}

    _, (check,) = await make_graph(phone)
    engine.results = [result(check, s, ok=False) for s in (0, 20, 40)]
    await cycle(menv, engine, 41)
    await cycle(menv, engine, 60)
    menv.clock.current = T0 + timedelta(seconds=90)
    report = (await phone.get("/monitoring/self-check")).json()
    assert report["engine"]["last_poll_at"] == "2026-10-01T12:01:00Z"
    assert report["engine"]["lag_seconds"] == 30
    assert report["telegram"]["queued"] == 1
    await menv.execute(
        "INSERT INTO app_meta (key, value) VALUES ('monitor.config', :v)",
        v=json.dumps(
            {
                "synced_at": "2026-10-01T12:00:00Z",
                "active": ["a"],
                "rejected": [{"check_id": "b", "reason": "resolves_to_non_global"}],
            }
        ),
    )
    config = (await phone.get("/monitoring/self-check")).json()["config"]
    assert config == {
        "synced_at": "2026-10-01T12:00:00Z",
        "checks_active": 1,
        "checks_rejected": [{"check_id": "b", "reason": "resolves_to_non_global"}],
    }
    engine.error = "engine_unreachable"
    await cycle(menv, engine, 100)
    assert (await phone.get("/monitoring/self-check")).json()["engine"][
        "error"
    ] == "engine_unreachable"


async def test_the_telegram_test_message_answers_with_a_code_only(menv: Env) -> None:
    phone = await menv.login()
    sent: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(json.loads(request.content))
        return httpx.Response(200, json={"ok": True})

    use(menv, handler=handler)
    assert (await phone.post("/monitoring/telegram/test")).json() == {"ok": True, "error": None}
    assert sent[0]["chat_id"] == CHAT and "Проверка связи" in sent[0]["text"]
    menv.clock.advance(seconds=service.TELEGRAM_TEST_MIN_SECONDS)

    use(
        menv,
        handler=lambda r: httpx.Response(
            401, json={"ok": False, "description": f"Unauthorized {TOKEN}"}
        ),
    )
    failed = await phone.post("/monitoring/telegram/test")
    assert failed.json() == {"ok": False, "error": "unauthorized"}
    menv.clock.advance(seconds=service.TELEGRAM_TEST_MIN_SECONDS)

    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"no route to {request.url}", request=request)

    use(menv, handler=boom)
    assert (await phone.post("/monitoring/telegram/test")).json() == {
        "ok": False,
        "error": "network",
    }


async def test_no_answer_and_no_log_line_contains_the_token_or_the_chat_id(
    menv: Env, capfd: pytest.CaptureFixture[str]
) -> None:
    phone = await menv.login()
    engine = use(
        menv, handler=lambda r: httpx.Response(401, json={"ok": False, "description": TOKEN})
    )
    _, (check,) = await make_graph(phone)
    engine.results = [result(check, s, ok=False) for s in (0, 20, 40)]
    await cycle(menv, engine, 41)
    await cycle(menv, engine, 60)
    await service.deliver_outbox(menv.sessionmaker, menv.app.state.monitoring.notifier, menv.clock)
    texts = [
        (await phone.get("/monitoring/pulse")).text,
        (await phone.get("/monitoring/self-check")).text,
        (await phone.get("/monitoring/incidents")).text,
        (await phone.post("/monitoring/telegram/test")).text,
        (await phone.post("/monitoring/refresh")).text,
    ]
    rows = await menv.execute_fetch("SELECT text, last_error FROM monitor_outbox")
    texts.append(json.dumps([list(r) for r in rows], ensure_ascii=False))
    texts.append(capfd.readouterr().out + capfd.readouterr().err)
    for text in texts:
        assert TOKEN not in text and CHAT not in text
        assert "987654" not in text and "4242424242" not in text
    assert repr(menv.settings).count(TOKEN) == 0 and repr(menv.settings).count(CHAT) == 0


async def test_the_telegram_test_is_limited_to_once_in_ten_seconds(menv: Env) -> None:
    phone = await menv.login()
    sent: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(1)
        return httpx.Response(200, json={"ok": True})

    use(menv, handler=handler)
    assert (await phone.post("/monitoring/telegram/test")).json() == {"ok": True, "error": None}
    menv.clock.advance(seconds=service.TELEGRAM_TEST_MIN_SECONDS - 1)
    assert (await phone.post("/monitoring/telegram/test")).json() == {
        "ok": False,
        "error": "rate_limited",
    }
    assert len(sent) == 1  # nothing was sent for the second press
    menv.clock.advance(seconds=1)
    assert (await phone.post("/monitoring/telegram/test")).json() == {"ok": True, "error": None}
    assert len(sent) == 2


@pytest.mark.parametrize(
    ("header", "matches"),
    [
        ('"abc"', True),
        ('W/"abc"', True),
        ('"x", "abc"', True),
        ('"x" , W/"abc" ,"y"', True),
        ("*", True),
        ('"abcd"', False),
        ('"x", "y"', False),
        ("abc", False),
        ("", False),
        (None, False),
    ],
)
def test_if_none_match_is_a_list_of_possibly_weak_tags(header: str | None, matches: bool) -> None:
    assert service.etag_matches(header, '"abc"') is matches


async def test_an_unchanged_pulse_stays_304_while_the_poll_moves_on(menv: Env) -> None:
    phone = await menv.login()
    engine = use(menv)
    _, (check,) = await make_graph(phone)
    engine.results = [result(check, 0), result(check, 20)]
    await cycle(menv, engine, 21)
    first = await phone.get("/monitoring/pulse")
    etag = first.headers["etag"]
    for seconds in (31, 41, 51):  # the poll runs every 10 s: last_poll_at moves, the picture not
        await cycle(menv, engine, seconds)
    again = await phone.get("/monitoring/pulse")
    assert again.json()["engine"]["last_poll_at"] != first.json()["engine"]["last_poll_at"]
    assert again.headers["etag"] == etag
    for header in (etag, f"W/{etag}", f'"other", {etag}'):
        cached = await menv.client.get(
            "/monitoring/pulse", headers={**phone.headers, "If-None-Match": header}
        )
        assert cached.status_code == 304, header


async def test_incidents_that_started_in_the_same_second_are_all_paged(menv: Env) -> None:
    phone = await menv.login()
    graph, _ = await make_graph(phone)
    for n in range(1, 8):
        await menv.execute(
            "INSERT INTO monitor_incidents (id, service_id, n, started_at, check_ids) "
            "VALUES (:id, :s, :n, :t, '[]')",
            id=uuid.uuid4(),
            s=graph.service,
            n=n,
            t=T0,
        )
    seen: list[str] = []
    cursor: dict[str, Any] = {}
    for _ in range(10):
        page = (await phone.get("/monitoring/incidents", limit=3, **cursor)).json()
        seen += [i["id"] for i in page["incidents"]]
        if page["next_before"] is None:
            break
        assert page["next_before_id"] is not None
        cursor = {"before": page["next_before"], "before_id": page["next_before_id"]}
    assert len(seen) == 7 and len(set(seen)) == 7
    assert (
        await phone.get("/monitoring/incidents", before_id=str(uuid.uuid4()))
    ).status_code == 422


async def test_the_pulse_trims_the_spark_and_names_a_refused_check(menv: Env) -> None:
    phone = await menv.login()
    engine = use(menv)
    _, (check, other) = await make_graph(phone, checks=2)
    engine.results = [result(check, s * 5, ms=s + 1) for s in range(45)]
    await cycle(menv, engine, 300)
    await menv.execute(
        "INSERT INTO app_meta (key, value) VALUES ('monitor.config', :v)",
        v=json.dumps(
            {
                "synced_at": "2026-10-01T12:00:00Z",
                "active": [str(check)],
                "rejected": [{"check_id": str(other), "reason": "resolve_failed"}],
            }
        ),
    )
    body = (await phone.get("/monitoring/pulse")).json()
    cards = {c["id"]: c for c in body["services"][0]["checks"]}
    assert cards[str(check)]["spark"] == list(range(16, 46))  # the last 30, oldest first
    assert cards[str(check)]["problem"] is None
    assert cards[str(other)]["problem"] == "resolve_failed" and cards[str(other)]["spark"] == []
