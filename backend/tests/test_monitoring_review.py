"""Review fixes of Stage 9, on a real PostgreSQL: reminders that are not lost, incident numbers
that are never reused, a deleted check that does not keep a service down, big batches, a message
that is sent by one worker only, the retry delay of Telegram, the false "monitoring restored"."""

import uuid
from datetime import timedelta
from typing import Any

import pytest

from tasker.ids import uuid7
from tasker.monitoring import service
from tasker.monitoring.telegram import SendResult, interpret
from tests.api_support import DeviceClient, Env
from tests.monitoring_support import T0, FakeEngine, FakeNotifier, check_fields, make_graph, result
from tests.test_monitoring_cycle import deliver, outbox, poll


async def kinds(env: Env) -> list[str]:
    return [k for k, _ in await outbox(env)]


async def delete(phone: DeviceClient, table: str, row_id: uuid.UUID) -> None:
    head = int((await phone.pull_ok(0))["head_version"])
    (done,) = await phone.push_ok([phone.op(table, row_id, "delete", base=head)])
    assert done["status"] == "applied", done


# ------------------------------------------------------------------ M1: reminders


async def test_every_reminder_of_one_incident_reaches_the_outbox(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)] + [result(check, s, ok=False) for s in (20, 40, 60)])
    await poll(env, engine, 61)
    await poll(env, engine, 71)
    assert await kinds(env) == ["down"]
    for seconds in (3700, 3701, 3800):  # one hour after the alert; the next waits four more
        await poll(env, engine, seconds)
    assert (await kinds(env)).count("reminder") == 1
    await poll(env, engine, 3700 + 5 * 3600 - 3600)  # +5 h after the fall
    await poll(env, engine, 3700 + 9 * 3600 - 3600)  # +9 h
    found = [k for k in await kinds(env) if k == "reminder"]
    assert len(found) == 3
    keys = await env.execute_fetch("SELECT dedup_key FROM monitor_outbox WHERE kind = 'reminder'")
    assert len({k[0] for k in keys}) == 3


# ------------------------------------------------------------------ M2: incident numbers


async def test_a_service_that_lost_its_state_does_not_reuse_incident_numbers(env: Env) -> None:
    phone = await env.login()
    graph, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, 0)] + [result(check, s, ok=False) for s in (20, 40, 60)])
    await poll(env, engine, 61)
    await poll(env, engine, 71)
    engine.results += [result(check, 80), result(check, 100)]
    await poll(env, engine, 101)
    assert await kinds(env) == ["down", "recovered"]

    await delete(phone, "monitor_checks", check)
    await poll(env, engine, 150)  # no live checks: the state of the service is erased
    assert await env.scalar("SELECT count(*) FROM monitor_state") == 0

    fresh = uuid7()
    (made,) = await phone.push_ok(
        [phone.op("monitor_checks", fresh, fields=check_fields(phone, graph.service, name="Новая"))]
    )
    assert made["status"] == "applied"
    engine.results = [result(fresh, 300)] + [result(fresh, s, ok=False) for s in (320, 340, 360)]
    await poll(env, engine, 361)
    await poll(env, engine, 371)
    assert await kinds(env) == ["down", "recovered", "down"]  # not swallowed by the old key
    rows = await env.execute_fetch("SELECT n, ended_at FROM monitor_incidents ORDER BY n")
    assert [(r.n, r.ended_at is None) for r in rows] == [(1, False), (2, True)]
    keys = await env.execute_fetch("SELECT dedup_key FROM monitor_outbox WHERE kind = 'down'")
    assert sorted(k[0].split("#")[1] for k in keys) == ["1", "2"]

    state = await env.scalar("SELECT state->>'seq' FROM monitor_state")
    assert state == "2"


async def test_an_open_incident_of_a_service_without_live_checks_is_closed(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    assert await env.scalar("SELECT count(*) FROM monitor_incidents WHERE ended_at IS NULL") == 1
    await delete(phone, "monitor_checks", check)
    await poll(env, engine, 100)
    assert await env.scalar("SELECT count(*) FROM monitor_incidents WHERE ended_at IS NULL") == 0
    assert await kinds(env) == ["down"]  # nothing is announced for a check the owner removed


# ------------------------------------------------------------------ M3: a deleted check


async def test_a_deleted_fallen_check_lets_the_service_recover_once(env: Env) -> None:
    phone = await env.login()
    _, (a, b) = await make_graph(phone, checks=2)
    engine = FakeEngine(
        [result(a, 0), result(b, 0)]
        + [result(a, s) for s in (20, 40, 60)]
        + [result(b, s, ok=False) for s in (20, 40, 60)]
    )
    await poll(env, engine, 61)
    await poll(env, engine, 71)
    assert await kinds(env) == ["down"]
    await delete(phone, "monitor_checks", b)
    engine.results.append(result(a, 80))
    await poll(env, engine, 81)
    assert await kinds(env) == ["down", "recovered"]
    for seconds, extra in ((100, result(a, 100)), (200, result(a, 200)), (4000, result(a, 3900))):
        engine.results.append(extra)
        await poll(env, engine, seconds)
    assert await kinds(env) == ["down", "recovered"]  # exactly one recovery, no reminders
    rows = await env.execute_fetch("SELECT ended_at FROM monitor_incidents")
    assert len(rows) == 1 and rows[0].ended_at is not None


# ------------------------------------------------------------------ m1: big batches


async def test_a_batch_beyond_the_parameter_limit_is_stored(env: Env) -> None:
    phone = await env.login()
    _, ids = await make_graph(phone, checks=40)
    engine = FakeEngine([result(c, s) for c in ids for s in range(0, 210 * 5, 5)])
    assert len(engine.results) == 40 * 210 > 8000
    report = await poll(env, engine, 1100)
    assert report.new_results == 8400
    assert await env.scalar("SELECT count(*) FROM monitor_results") == 8400
    assert await env.scalar("SELECT sum(total) FROM monitor_rollups") == 8400
    again = await poll(env, engine, 1110)
    assert again.new_results == 0


# ------------------------------------------------------------------ m5: one worker per message


class Reentrant(FakeNotifier):
    """While this one is sending, a second worker looks at the queue."""

    def __init__(self, env: Env, other: FakeNotifier, seconds: int) -> None:
        super().__init__()
        self.env, self.other, self.seconds = env, other, seconds

    async def send(self, text: str) -> SendResult:
        report = await deliver(self.env, self.other, self.seconds)
        assert report.sent == 0
        return await super().send(text)


async def test_a_message_being_sent_is_not_sent_by_a_second_worker(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    other = FakeNotifier()
    first = Reentrant(env, other, 100)
    report = await deliver(env, first, 100)
    assert report.sent == 1 and len(first.sent) == 1
    assert other.attempts == 0  # the second worker found nothing due


async def test_a_message_whose_sender_died_comes_back_after_the_lease(env: Env) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)

    class Dying(FakeNotifier):
        async def send(self, text: str) -> SendResult:
            raise RuntimeError("the process died")

    with pytest.raises(RuntimeError):
        await deliver(env, Dying(), 100)
    alive = FakeNotifier()
    assert (await deliver(env, alive, 100 + service.LEASE_SECONDS - 5)).sent == 0
    assert (await deliver(env, alive, 100 + service.LEASE_SECONDS + 5)).sent == 1


# ------------------------------------------------------------------ m6: retry_after


@pytest.mark.parametrize(
    ("given", "expected"),
    [(10**30, 3600), (3601, 3600), (3600, 3600), (45, 45), (1, 1), (0, 1), (-5, 1)],
)
def test_retry_after_is_kept_within_sane_bounds(given: int, expected: int) -> None:
    body: dict[str, Any] = {"ok": False, "parameters": {"retry_after": given}}
    assert interpret(429, body).retry_after == expected


@pytest.mark.parametrize("junk", [True, "30", 2.5, None, [1]])
def test_a_retry_after_of_the_wrong_type_is_the_default(junk: Any) -> None:
    assert interpret(429, {"parameters": {"retry_after": junk}}).retry_after == 30
    assert interpret(429, {}).retry_after == 30


@pytest.mark.parametrize(
    ("given", "seconds"), [(10**15, 3600), (-100, 1), (0, 1), (None, 30), (12, 12)]
)
async def test_the_delivery_clamps_a_wild_retry_after(
    env: Env, given: int | None, seconds: int
) -> None:
    phone = await env.login()
    _, (check,) = await make_graph(phone)
    engine = FakeEngine([result(check, s, ok=False) for s in (0, 20, 40)])
    await poll(env, engine, 41)
    await poll(env, engine, 60)
    notifier = FakeNotifier([SendResult(False, "rate_limited", retry_after=given)])
    report = await deliver(env, notifier, 100)
    assert report.failed == 1
    rows = await env.execute_fetch("SELECT next_attempt_at, attempts FROM monitor_outbox")
    assert rows[0].next_attempt_at == T0 + timedelta(seconds=100 + seconds)
    assert rows[0].attempts == 0


# ------------------------------------------------------------------ m9: the false "restored"


async def test_no_restored_message_when_the_checks_are_gone(env: Env) -> None:
    phone = await env.login()
    graph, _ = await make_graph(phone)
    engine = FakeEngine()
    await poll(env, engine, 1)
    await poll(env, engine, 400)  # a check that never answered: the engine is called dead
    assert await kinds(env) == ["engine_down"]
    await delete(phone, "monitor_services", graph.service)
    await poll(env, engine, 410)
    assert await kinds(env) == ["engine_down"]  # nothing came back: no "restored"
    value = await env.scalar("SELECT value FROM app_meta WHERE key = 'monitor.engine_alerted'")
    assert value == "0"
