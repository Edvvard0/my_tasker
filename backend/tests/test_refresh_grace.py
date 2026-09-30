"""Refresh-token rotation with a 60 s grace for a lost response (spec 1.3)."""

import asyncio
from typing import Any

from tasker.auth.crypto import hash_refresh_token
from tests.api_support import SCHEMA, DeviceClient, Env
from tests.test_auth_api import error_code


async def refresh(env: Env, token: str) -> Any:
    return await env.client.post("/auth/refresh", json={"refresh_token": token}, headers=SCHEMA)


async def revoked(env: Env) -> bool:
    return await env.scalar("SELECT revoked_at FROM devices") is not None


async def test_previous_token_within_grace_returns_a_fresh_pair(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    first = (await refresh(env, device.refresh_token)).json()  # the response is "lost"
    env.clock.advance(seconds=10)
    retry = await refresh(env, device.refresh_token)
    assert retry.status_code == 200, retry.text
    second = retry.json()
    assert second["device_id"] == first["device_id"]
    assert second["refresh_token"] not in (first["refresh_token"], device.refresh_token)
    assert second["access_token"] != first["access_token"]
    assert not await revoked(env)
    # The new pair works, and rotates normally afterwards.
    env.clock.advance(seconds=1)
    access = {"Authorization": f"Bearer {second['access_token']}", **SCHEMA}
    assert (await env.client.get("/auth/devices", headers=access)).status_code == 200
    third = await refresh(env, second["refresh_token"])
    assert third.status_code == 200


async def test_the_unused_successor_is_revoked_by_the_grace_refresh(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    first = (await refresh(env, device.refresh_token)).json()
    second = (await refresh(env, device.refresh_token)).json()  # grace
    stale = await refresh(env, first["refresh_token"])  # the successor that was never used
    assert (stale.status_code, error_code(stale)) == (401, "refresh_reuse_detected")
    assert await revoked(env)
    late = await refresh(env, second["refresh_token"])
    assert error_code(late) == "device_revoked"


async def test_grace_expires_after_sixty_seconds(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    env.clock.advance(seconds=61)
    reuse = await refresh(env, device.refresh_token)
    assert (reuse.status_code, error_code(reuse)) == (401, "refresh_reuse_detected")
    assert await revoked(env)


async def test_grace_is_still_open_at_exactly_sixty_seconds(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    env.clock.advance(seconds=60)
    assert (await refresh(env, device.refresh_token)).status_code == 200


async def test_grace_window_is_not_extended_by_grace_refreshes(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    env.clock.advance(seconds=40)
    assert (await refresh(env, device.refresh_token)).status_code == 200
    env.clock.advance(seconds=21)  # 61 s after the rotation
    assert error_code(await refresh(env, device.refresh_token)) == "refresh_reuse_detected"


async def test_only_the_immediately_previous_token_has_grace(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=1)
    first = (await refresh(env, device.refresh_token)).json()
    env.clock.advance(seconds=1)
    await refresh(env, first["refresh_token"])  # the successor was used: it was refreshed
    env.clock.advance(seconds=1)
    old = await refresh(env, device.refresh_token)  # two generations back
    assert (old.status_code, error_code(old)) == (401, "refresh_reuse_detected")


async def test_previous_token_of_the_latest_rotation_still_has_grace(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=1)
    first = (await refresh(env, device.refresh_token)).json()
    env.clock.advance(seconds=1)
    await refresh(env, first["refresh_token"])  # R1 -> R2
    env.clock.advance(seconds=1)
    assert (await refresh(env, first["refresh_token"])).status_code == 200  # R1 was just replaced


async def test_used_successor_ends_the_grace(env: Env) -> None:
    """Once an access token of the new pair is seen, the old refresh token is plain reuse."""
    device = await env.login()
    env.clock.advance(seconds=5)
    first = (await refresh(env, device.refresh_token)).json()
    env.clock.advance(seconds=1)
    access = {"Authorization": f"Bearer {first['access_token']}", **SCHEMA}
    assert (await env.client.get("/auth/devices", headers=access)).status_code == 200
    env.clock.advance(seconds=1)
    reuse = await refresh(env, device.refresh_token)
    assert (reuse.status_code, error_code(reuse)) == (401, "refresh_reuse_detected")
    assert await revoked(env)


async def test_an_older_access_token_does_not_end_the_grace(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    env.clock.advance(seconds=1)
    assert (await device.get("/auth/devices")).status_code == 200  # the login-time access token
    assert (await refresh(env, device.refresh_token)).status_code == 200
    assert not await revoked(env)


async def test_grace_token_does_not_bypass_expiry_or_revocation(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    await env.client.delete(f"/auth/devices/{device.device_id}", headers=device.headers)
    assert error_code(await refresh(env, device.refresh_token)) == "device_revoked"


async def test_concurrent_refreshes_with_one_token_do_not_revoke_the_device(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    responses = await asyncio.gather(*(refresh(env, device.refresh_token) for _ in range(6)))
    assert [r.status_code for r in responses] == [200] * 6
    tokens = [r.json()["refresh_token"] for r in responses]
    assert len(set(tokens)) == 6
    assert not await revoked(env)
    # Exactly one of them is the live successor (the last one the server issued).
    current = await env.scalar("SELECT refresh_token_hash FROM devices")
    assert [hash_refresh_token(t) == current for t in tokens].count(True) == 1
    live = next(t for t in tokens if hash_refresh_token(t) == current)
    assert (await refresh(env, live)).status_code == 200


async def test_grace_pair_is_usable_for_sync(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    await refresh(env, device.refresh_token)
    body = (await refresh(env, device.refresh_token)).json()
    env.clock.advance(seconds=1)
    fresh = DeviceClient(env, device.device_id, body["access_token"], body["refresh_token"])
    assert (await fresh.pull()).status_code == 200
