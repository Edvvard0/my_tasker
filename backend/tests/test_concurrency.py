"""Regression tests for races: concurrent pushers, a paging puller, retries and refreshes."""

import asyncio
from typing import Any

from tests.api_support import DeviceClient, Env
from tests.test_refresh_grace import refresh
from tests.test_sync_push import create_setting

PUSHERS = 6
BATCHES = 6
PER_BATCH = 4


async def pusher(dc: DeviceClient, index: int, sent: set[str]) -> None:
    for batch in range(BATCHES):
        keys = [f"p{index}.b{batch}.k{n}" for n in range(PER_BATCH)]
        results = await dc.push_ok([create_setting(dc, key, value=index) for key in keys])
        assert [r["status"] for r in results] == ["applied"] * PER_BATCH
        sent.update(keys)


async def test_paging_puller_sees_every_row_while_pushers_run(env: Env) -> None:
    """Versions are handed out and committed in order, so a cursor can never skip a row."""
    devices = [await env.login(f"D{n}") for n in range(PUSHERS)]
    watcher = await env.login("Watcher")
    sent: set[str] = set()
    seen: list[tuple[int, str]] = []
    done = asyncio.Event()

    async def puller() -> None:
        cursor = 0
        while True:
            finished = done.is_set()  # read before the pull: one last full pass afterwards
            page = await watcher.pull_ok(cursor, limit=7)
            for change in page["changes"]:
                seen.append((change["server_version"], change["row"]["key"]))
            cursor = page["next_since"]
            if finished and not page["has_more"]:
                return
            await asyncio.sleep(0)

    puller_task = asyncio.create_task(puller())
    await asyncio.gather(*(pusher(dc, index, sent) for index, dc in enumerate(devices)))
    done.set()
    await asyncio.wait_for(puller_task, 60)

    total = PUSHERS * BATCHES * PER_BATCH
    assert len(sent) == total
    versions = [version for version, _ in seen]
    assert versions == sorted(versions)  # strictly ascending: no re-delivery, no reordering
    assert len(set(versions)) == len(versions)
    assert {key for _, key in seen} == sent  # nothing skipped
    assert versions == list(range(1, total + 1))  # gapless
    assert await env.scalar("SELECT head_version FROM sync_state") == total


async def test_two_pushes_of_the_same_batch_apply_it_once(env: Env) -> None:
    dc = await env.login()
    ops = [create_setting(dc, f"same.{n}") for n in range(10)]
    first, second = await asyncio.gather(dc.push(ops), dc.push(ops))
    bodies = [first.json(), second.json()]
    assert [r.status_code for r in (first, second)] == [200, 200]
    flags = sorted(all(item["duplicate"] for item in body["results"]) for body in bodies)
    assert flags == [False, True]  # one applied, the other got the remembered answers
    assert await env.scalar("SELECT head_version FROM sync_state") == 10
    assert await env.scalar("SELECT count(*) FROM user_settings") == 10


async def test_concurrent_refreshes_of_different_devices_all_succeed(env: Env) -> None:
    devices = [await env.login(f"D{n}") for n in range(8)]
    env.clock.advance(seconds=5)
    responses = await asyncio.gather(*(refresh(env, dc.refresh_token) for dc in devices))
    assert [r.status_code for r in responses] == [200] * 8
    assert {r.json()["device_id"] for r in responses} == {str(dc.device_id) for dc in devices}
    assert await env.scalar("SELECT count(*) FROM devices WHERE revoked_at IS NULL") == 8


async def test_refresh_racing_with_requests_on_the_same_device(env: Env) -> None:
    dc = await env.login()
    env.clock.advance(seconds=5)

    async def call() -> Any:
        return await env.client.get("/auth/devices", headers=dc.headers)

    results = await asyncio.gather(
        refresh(env, dc.refresh_token), call(), call(), call(), refresh(env, dc.refresh_token)
    )
    assert [r.status_code for r in results] == [200] * 5
    assert await env.scalar("SELECT revoked_at FROM devices") is None
