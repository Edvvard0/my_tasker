"""The polling cycle on a real PostgreSQL: results -> state machine -> incidents -> outbox, and the
Telegram delivery. The headline rule: a fall is announced exactly once, then the recovery."""

import json
import uuid
from datetime import timedelta
from typing import Any

import sqlalchemy as sa

from tasker.monitoring import service
from tasker.monitoring.service import MonitorSettings
from tasker.monitoring.telegram import SendResult
from tests.api_support import DeviceClient, Env
from tests.monitoring_support import T0, FakeEngine, FakeNotifier, make_graph, result

CFG = MonitorSettings("http://gatus:8080", None, "1.1.1.1:53", "Europe/Moscow", None, None)


def at(env: Env, seconds: int) -> None:
    env.clock.current = T0 + timedelta(seconds=seconds)


async def poll(
    env: Env, engine: FakeEngine, seconds: int, cfg: MonitorSettings = CFG
) -> service.CycleReport:
    at(env, seconds)
    return await service.poll_cycle(env.sessionmaker, engine, cfg, env.clock)


async def outbox(env: Env) -> list[tuple[str, str]]:
    async with env.sessionmaker() as session:
        rows = await session.execute(sa.text("SELECT kind, text FROM monitor_outbox ORDER BY id"))
        return [(k, t) for k, t in rows.all()]


async def deliver(
    env: Env, notifier: FakeNotifier, seconds: int, **kwargs: Any
) -> service.DeliveryReport:
    at(env, seconds)

    async def no_sleep(_: float) -> None:
        return None

    return await service.deliver_outbox(
        env.sessionmaker, notifier, env.clock, sleep=no_sleep, **kwargs
    )


async def test_fall_is_announced_once_then_the_recovery_once(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)])
    assert (await poll(env, engine, 1)).messages == 0

    engine.results += [result(check, s, ok=False) for s in (20, 40, 60)]
    await poll(env, engine, 61)
    assert await outbox(env) == []  # confirmed, but the alert waits its few seconds
    await poll(env, engine, 71)
    messages = await outbox(env)
    assert [k for k, _ in messages] == ["down"]
    assert "ЛЕЖИТ: Сайт (VPS Берлин)" in messages[0][1]
    assert "Проверка 0: HTTP 502" in messages[0][1]

    for seconds in (72, 81, 91, 200):  # the same results again and again: nothing new
        await poll(env, engine, seconds)
    assert len(await outbox(env)) == 1

    engine.results += [result(check, 80), result(check, 100)]
    await poll(env, engine, 101)
    messages = await outbox(env)
    assert [k for k, _ in messages] == ["down", "recovered"]
    assert "РАБОТАЕТ: Сайт (VPS Берлин)" in messages[1][1]
    assert "Простой: 1 мин" in messages[1][1]  # 20 s .. 100 s = 80 s
    await poll(env, engine, 150)
    assert len(await outbox(env)) == 2

    notifier = FakeNotifier()
    report = await deliver(env, notifier, 600)
    assert (report.sent, report.failed) == (2, 0)
    assert [t.split(":")[0] for t in notifier.sent] == ["ЛЕЖИТ", "РАБОТАЕТ"]
    again = await deliver(env, notifier, 700)
    assert again.sent == 0 and len(notifier.sent) == 2  # sent exactly once each

    async with env.sessionmaker() as session:
        rows = (
            await session.execute(
                sa.text("SELECT n, ended_at, reason, check_ids FROM monitor_incidents")
            )
        ).all()
    assert len(rows) == 1
    assert rows[0].n == 1 and rows[0].ended_at is not None
    assert rows[0].reason == "HTTP 502" and rows[0].check_ids == [str(check)]


async def test_two_cycles_at_once_are_serialised_by_the_lock(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)])
    async with env.sessionmaker() as holder, holder.begin():
        await holder.execute(sa.select(sa.func.pg_advisory_xact_lock(service.LOCK_KEY)))
        skipped = await poll(env, engine, 1)
    assert skipped.skipped is True and skipped.new_results == 0
    assert (await poll(env, engine, 2)).new_results == 1


async def test_results_of_unknown_or_trashed_checks_are_ignored(env: Env) -> None:
    phone = await env.login()
    graph, (check,) = await make_graph(phone)
    stranger = uuid.uuid4()
    engine = FakeEngine([result(check, 0), result(stranger, 0)])
    assert (await poll(env, engine, 1)).new_results == 1
    await phone.push_ok(
        [
            phone.op(
                "monitor_services",
                graph.service,
                "delete",
                base=int((await phone.pull_ok(0))["head_version"]),
            )
        ]
    )
    engine.results.append(result(check, 20))
    assert (await poll(env, engine, 21)).new_results == 0
    assert (
        await env.scalar("SELECT count(*) FROM monitor_state") == 0
    )  # a trashed service has no state


async def test_the_engine_failing_raises_no_false_alerts_and_staleness_is_announced_once(
    env: Env,
) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0), result(check, 20)])
    await poll(env, engine, 21)
    engine.error = "engine_unreachable"
    report = await poll(env, engine, 100)
    assert report.error == "engine_unreachable" and report.polled is False
    assert await outbox(env) == []  # silence is not an outage of the services
    await poll(env, engine, 200)
    assert await outbox(env) == []  # the last result is 180 s old: still fresh enough
    await poll(env, engine, 400)
    await poll(env, engine, 500)
    assert [k for k, _ in await outbox(env)] == ["engine_down"]
    engine.error = None
    engine.results.append(result(check, 520))
    await poll(env, engine, 521)
    await poll(env, engine, 560)
    assert [k for k, _ in await outbox(env)] == ["engine_down", "engine_up"]
    assert await env.scalar("SELECT value FROM app_meta WHERE key = 'monitor.last_error'") == ""


async def test_several_services_falling_together_give_one_group_message(env: Env) -> None:
    phone = await env.login()
    engine = FakeEngine()
    for _ in range(3):
        _, (check,) = await make_graph(phone)
        engine.results += [result(check, 0, ok=False) for _ in range(1)]
        engine.results += [result(check, s, ok=False) for s in (20, 40)]
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    messages = await outbox(env)
    assert [k for k, _ in messages] == ["down_group"]
    text = messages[0][1]
    assert text.startswith("ЛЕЖАТ (3):") and text.count("Сайт (VPS Берлин)") == 3
    assert "Возможна проблема на стороне мониторинга" in text


async def test_quiet_hours_hold_a_normal_service_but_not_a_critical_one(env: Env) -> None:
    phone = await env.login()
    engine = FakeEngine()
    _, (calm,) = await make_graph(phone)
    _, (loud,) = await make_graph(phone, critical=True)
    for check in (calm, loud):
        engine.results += [result(check, s, ok=False) for s in (0, 20, 40)]
    quiet = MonitorSettings("http://gatus:8080", None, "1.1.1.1:53", "UTC", "11:00", "13:00")
    await poll(env, engine, 41, quiet)
    await poll(env, engine, 60, quiet)
    messages = await outbox(env)
    assert len(messages) == 1 and messages[0][0] == "down"  # only the critical one
    later = MonitorSettings("http://gatus:8080", None, "1.1.1.1:53", "UTC", "00:00", "01:00")
    await poll(env, engine, 120, later)
    assert [k for k, _ in await outbox(env)] == [
        "down",
        "down",
    ]  # the held one, after the quiet hours


async def test_rollups_and_the_pulse_numbers_add_up(env: Env) -> None:
    phone = await env.login()
    graph, (check,) = await make_graph(phone)
    engine = FakeEngine(
        [
            result(check, 0, ms=100),
            result(check, 20, ms=300),
            result(check, 40, ok=False),
            result(check, 60, ms=200),
        ]
    )
    await poll(env, engine, 61)
    await poll(env, engine, 62)  # again: nothing is counted twice
    row = (await env.execute_fetch("SELECT total, ok, ms_sum, ms_count FROM monitor_rollups"))[0]
    assert tuple(row) == (4, 3, 600, 3)
    async with env.sessionmaker() as session, session.begin():
        snapshot = await service.pulse_snapshot(session, CFG, env.clock, telegram_configured=False)
    (card,) = snapshot["services"]
    assert card["availability"] == {"h24": 7500, "d7": 7500, "d30": 7500}
    assert card["response_ms"] == 200 and card["status"] == "up"
    (check_card,) = card["checks"]
    assert check_card["spark"] == [100, 300, -1, 200]
    assert snapshot["summary"] == {"services": 1, "down": 0, "up": 1, "unknown": 0}
    assert snapshot["engine"]["healthy"] is True and graph.service is not None


async def test_the_state_of_a_deleted_service_is_dropped(env: Env) -> None:
    phone = await env.login()
    graph, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)])
    await poll(env, engine, 1)
    assert await env.scalar("SELECT count(*) FROM monitor_state") == 1
    head = int((await phone.pull_ok(0))["head_version"])
    await phone.push_ok([phone.op("monitor_servers", graph.server, "delete", base=head)])
    await poll(env, engine, 30)
    assert await env.scalar("SELECT count(*) FROM monitor_state") == 0


async def test_delivery_pacing_rate_limit_backoff_and_expiry(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)])
    await poll(env, engine, 1)
    at(env, 2)
    now = env.clock.now()
    async with env.sessionmaker() as session, session.begin():
        for i in range(4):
            await session.execute(
                sa.text(
                    "INSERT INTO monitor_outbox (dedup_key, kind, text, created_at, expires_at, next_attempt_at)"
                    " VALUES (:k, 'x', :t, :c, :e, :c)"
                ),
                {"k": f"k{i}", "t": f"m{i}", "c": now, "e": now + timedelta(hours=6)},
            )
    sleeps: list[float] = []

    async def record(seconds: float) -> None:
        sleeps.append(seconds)

    notifier = FakeNotifier([SendResult(True), SendResult(False, "rate_limited", retry_after=17)])
    report = await service.deliver_outbox(env.sessionmaker, notifier, env.clock, sleep=record)
    assert (report.sent, report.failed, report.error) == (1, 1, "rate_limited")
    assert sleeps == [1.0]  # about a message a second
    assert notifier.sent == ["m0"] and notifier.attempts == 2
    attempts, due = (
        await env.execute_fetch(
            "SELECT attempts, next_attempt_at FROM monitor_outbox WHERE text = 'm1'"
        )
    )[0]
    assert attempts == 0 and due == now + timedelta(seconds=17)  # a 429 is not the message's fault

    again = await deliver(env, notifier, 10)  # 8 s later: still waiting
    assert again.sent == 0 and notifier.attempts == 2
    done = await deliver(env, notifier, 30)
    assert done.sent == 3 and notifier.sent == ["m0", "m1", "m2", "m3"]

    # network errors back off 10 s, 20 s ...; a rejection that will not change waits 10 minutes
    async with env.sessionmaker() as session, session.begin():
        await session.execute(
            sa.text(
                "INSERT INTO monitor_outbox (dedup_key, kind, text, created_at, expires_at, next_attempt_at)"
                " VALUES ('n', 'x', 'later', :c, :e, :c)"
            ),
            {"c": env.clock.now(), "e": env.clock.now() + timedelta(hours=6)},
        )
    flaky = FakeNotifier([SendResult(False, "network"), SendResult(False, "network")])
    await deliver(env, flaky, 31)
    attempts, due = (
        await env.execute_fetch(
            "SELECT attempts, next_attempt_at FROM monitor_outbox WHERE dedup_key = 'n'"
        )
    )[0]
    assert attempts == 1 and due == env.clock.now() + timedelta(seconds=10)
    await deliver(env, flaky, 42)
    attempts, due = (
        await env.execute_fetch(
            "SELECT attempts, next_attempt_at FROM monitor_outbox WHERE dedup_key = 'n'"
        )
    )[0]
    assert attempts == 2 and due == env.clock.now() + timedelta(seconds=20)
    wrong = FakeNotifier([SendResult(False, "unauthorized", permanent=True)])
    await deliver(env, wrong, 70)
    attempts, due = (
        await env.execute_fetch(
            "SELECT attempts, next_attempt_at FROM monitor_outbox WHERE dedup_key = 'n'"
        )
    )[0]
    assert attempts == 3 and due == env.clock.now() + timedelta(
        seconds=service.PERMANENT_RETRY_SECONDS
    )
    assert (
        await env.scalar("SELECT value FROM app_meta WHERE key = 'monitor.telegram.last_error'")
        == "unauthorized"
    )
    healed = FakeNotifier()
    await deliver(env, healed, 70 + service.PERMANENT_RETRY_SECONDS + 1)
    assert healed.sent == ["later"]  # a fixed .env heals itself
    assert (
        await env.scalar("SELECT value FROM app_meta WHERE key = 'monitor.telegram.last_error'")
        == ""
    )

    # a message older than its lifetime is not sent any more
    async with env.sessionmaker() as session, session.begin():
        await session.execute(
            sa.text(
                "INSERT INTO monitor_outbox (dedup_key, kind, text, created_at, expires_at, next_attempt_at)"
                " VALUES ('old', 'x', 'stale', :c, :e, :c)"
            ),
            {"c": env.clock.now(), "e": env.clock.now() + timedelta(hours=1)},
        )
    late = FakeNotifier()
    await deliver(env, late, 70 + service.PERMANENT_RETRY_SECONDS + 3 * 3600 + 5)
    assert late.sent == []


async def test_delivery_without_telegram_keeps_the_queue(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    report = await deliver(env, FakeNotifier(is_configured=False), 70)
    assert report.error == "not_configured" and report.sent == 0
    assert len(await outbox(env)) == 1
    assert await env.scalar("SELECT count(*) FROM monitor_outbox WHERE sent_at IS NULL") == 1
    sent = FakeNotifier()
    await deliver(env, sent, 80)
    assert len(sent.sent) == 1


async def test_a_message_is_never_queued_twice(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    # a worker that lost its state row would replay the incident: the unique key stops the repeat
    await env.execute("DELETE FROM monitor_state")
    await env.execute("DELETE FROM monitor_incidents")
    await env.execute("DELETE FROM monitor_results")
    await poll(env, engine, 61)
    await poll(env, engine, 80)
    assert len(await outbox(env)) == 1


async def test_cleanup_applies_the_retention(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    now = env.clock.now()
    async with env.sessionmaker() as session, session.begin():
        for days in (0, 3):
            await session.execute(
                sa.text("INSERT INTO monitor_results (check_id, at, ok) VALUES (:c, :a, true)"),
                {"c": check, "a": now - timedelta(days=days)},
            )
        for days in (1, 200):
            await session.execute(
                sa.text("INSERT INTO monitor_rollups VALUES (:c, :h, 1, 1, 0, 0)"),
                {"c": check, "h": now - timedelta(days=days)},
            )
        for days in (1, 40):
            await session.execute(
                sa.text(
                    "INSERT INTO monitor_outbox (dedup_key, kind, text, created_at, expires_at, next_attempt_at)"
                    " VALUES (:k, 'x', 't', :c, :c, :c)"
                ),
                {"k": f"k{days}", "c": now - timedelta(days=days)},
            )
    await service.cleanup(env.sessionmaker, env.clock)
    assert await env.scalar("SELECT count(*) FROM monitor_results") == 1
    assert await env.scalar("SELECT count(*) FROM monitor_rollups") == 1
    assert await env.scalar("SELECT count(*) FROM monitor_outbox") == 1


async def test_sync_config_writes_the_file_and_reports_the_refused_checks(
    env: Env, tmp_path: Any
) -> None:
    phone = await env.login()
    graph, (good,) = await make_graph(phone)
    bad = uuid.uuid4()
    # a row that predates the rule (written behind the validation): the cycle must still refuse it
    await env.execute(
        "INSERT INTO monitor_checks (id, created_at, updated_at, server_version, origin_device_id,"
        " service_id, kind, name, url, interval_seconds, timeout_seconds)"
        " VALUES (:id, now(), 'x', 99, gen_random_uuid(), :s, 'http', 'old', 'http://10.0.0.1/', 20, 5)",
        id=bad,
        s=graph.service,
    )
    path = tmp_path / "monitor" / "config.yaml"
    cfg = MonitorSettings(None, str(path), "1.1.1.1:53", "UTC", None, None)

    async def resolve(host: str) -> list[str]:
        return ["93.184.216.34"]

    built = await service.sync_config(env.sessionmaker, cfg, env.clock, resolve)
    assert built is not None and built.active == [str(good)]
    assert str(good) in path.read_text() and str(bad) not in path.read_text()
    report = json.loads(await env.scalar("SELECT value FROM app_meta WHERE key = 'monitor.config'"))
    assert report["active"] == [str(good)]
    assert report["rejected"] == [{"check_id": str(bad), "reason": "target_non_global_ip"}]
    again = await service.sync_config(env.sessionmaker, cfg, env.clock, resolve)
    assert again is not None and again.digest == built.digest
    nothing = await service.sync_config(
        env.sessionmaker, MonitorSettings(None, None, "x", "UTC", None, None), env.clock, resolve
    )
    assert nothing is None


async def test_a_flapping_service_is_one_message_not_a_storm(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    pattern = [
        True,
        False,
        False,
        False,
        True,
        True,
        False,
        False,
        False,
        True,
        True,
        False,
        False,
        False,
    ]
    engine = FakeEngine()
    for index, ok in enumerate(pattern):
        engine.results.append(result(check, index * 20, ok=ok))
        await poll(env, engine, index * 20 + 21)
    kinds = [k for k, _ in await outbox(env)]
    assert kinds.count("flapping") == 1
    assert kinds.count("down") <= 2 and kinds.count("recovered") <= 2


async def helper_unused(_: DeviceClient) -> None:  # keeps the import used by type checkers
    return None


async def test_a_check_added_to_a_quiet_engine_is_given_time_before_the_engine_is_called_dead(
    env: Env,
) -> None:
    phone = await env.login()
    engine = FakeEngine()
    await poll(env, engine, 1)  # no checks at all: nobody waits for the engine
    await poll(env, engine, 1000)
    assert await outbox(env) == []
    await phone.refresh()  # the clock ran past the access token
    _, (check,) = await make_graph(phone)  # the owner adds a check; the engine has no result yet
    await poll(env, engine, 1010)
    await poll(env, engine, 1200)
    await poll(env, engine, 1300)
    assert await outbox(env) == []  # less than 300 s of waiting
    await poll(env, engine, 1400)
    assert [k for k, _ in await outbox(env)] == [
        "engine_down"
    ]  # nothing ever came: now it is called
    engine.results = [result(check, 1450)]
    await poll(env, engine, 1451)
    assert [k for k, _ in await outbox(env)] == ["engine_down", "engine_up"]


async def test_old_results_do_not_make_a_new_check_look_like_a_dead_engine(env: Env) -> None:
    phone = await env.login()
    graph, (old,) = await make_graph(phone)
    engine = FakeEngine([result(old, 0)])
    await poll(env, engine, 1)
    head = int((await phone.pull_ok(0))["head_version"])
    await phone.push_ok([phone.op("monitor_servers", graph.server, "delete", base=head)])
    await poll(env, engine, 400)  # no live checks: no waiting
    await make_graph(phone)  # a new one, while the newest stored result is 10 minutes old
    await poll(env, engine, 600)
    await poll(env, engine, 700)
    assert await outbox(env) == []
