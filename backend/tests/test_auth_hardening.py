"""Hostile input, lockout atomicity and secret handling in the auth layer."""

import asyncio
import json
import uuid
from datetime import timedelta
from types import SimpleNamespace
from typing import Any

import pytest
import sqlalchemy as sa
from argon2 import PasswordHasher
from sqlalchemy.exc import DBAPIError

from tasker.auth import lockout
from tasker.auth.crypto import derive_key
from tasker.auth.deps import client_ip
from tasker.auth.passwords import _dummy_hash, make_hasher
from tasker.auth.service import upsert_owner
from tasker.db import create_engine
from tests.api_support import PASSWORD, SCHEMA, Env
from tests.test_auth_api import error_code, login_response

WRONG = {"password": "wrong password!!", "totp_code": "000000"}


async def raw_post(env: Env, path: str, payload: dict[str, Any], **headers: str) -> Any:
    """POST ASCII-escaped JSON: httpx would refuse to encode a lone surrogate itself."""
    return await env.client.post(
        path,
        content=json.dumps(payload, ensure_ascii=True).encode(),
        headers={"Content-Type": "application/json", **SCHEMA, **headers},
    )


# ------------------------------------------------------------------ MINOR-2: hostile input


@pytest.mark.parametrize("token", ["at1.é.é", "at1.payload.ÿþ", "éé", "at1." + "é" * 60 + ".x"])
async def test_non_ascii_bearer_token_is_401_not_500(env: Env, token: str) -> None:
    response = await env.client.get(
        "/auth/devices",
        headers=[(b"authorization", b"Bearer " + token.encode("latin-1")), (b"x-a", b"1")],
    )
    assert (response.status_code, error_code(response)) == (401, "invalid_token")


async def test_lone_surrogate_refresh_token_is_a_client_error(env: Env) -> None:
    device = await env.login()
    bad = device.refresh_token[:-3] + "\ud800ab"
    response = await raw_post(env, "/auth/refresh", {"refresh_token": bad})
    assert (response.status_code, error_code(response)) == (422, "validation_error")
    assert (await env.client.get("/auth/devices", headers=device.headers)).status_code == 200


async def test_non_ascii_refresh_token_is_401(env: Env) -> None:
    device = await env.login()
    bad = device.refresh_token[:-3] + "ééé"
    response = await raw_post(env, "/auth/refresh", {"refresh_token": bad})
    assert (response.status_code, error_code(response)) == (401, "invalid_refresh_token")


@pytest.mark.parametrize("password", ["pass\u0000word 123456", "pass\ud800word 123456"])
async def test_password_with_nul_or_surrogate_is_a_validation_error(
    env: Env, password: str
) -> None:
    body = env.login_body()
    body["password"] = password
    response = await raw_post(env, "/auth/login", body)
    assert (response.status_code, error_code(response)) == (422, "validation_error")


@pytest.mark.parametrize(
    "device",
    [
        {"name": "a\u0000b", "platform": "other"},
        {"name": "a\ud800b", "platform": "other"},
        {"name": "ok", "platform": "other", "app_version": "1\u0000"},
    ],
)
async def test_device_text_that_postgres_cannot_store_is_a_validation_error(
    env: Env, device: dict[str, Any]
) -> None:
    body = env.login_body()
    body["device"] = device
    response = await raw_post(env, "/auth/login", body)
    assert (response.status_code, error_code(response)) == (422, "validation_error")
    assert await env.scalar("SELECT count(*) FROM devices") == 0


def test_client_ip_is_sanitised() -> None:
    request = SimpleNamespace(
        headers={"x-forwarded-for": "1.1.1.1, 2.2.2.2\u0000" + "x" * 100}, client=None
    )
    assert client_ip(request, True) == ("2.2.2.2" + "x" * 100)[:64]  # type: ignore[arg-type]
    assert client_ip(request, False) == "unknown"  # type: ignore[arg-type]


# ------------------------------------------------------------------ MINOR-7: changed secret key


async def test_changed_secret_key_gives_a_clear_error_not_a_500(
    env: Env, caplog: pytest.LogCaptureFixture
) -> None:
    env.rt.box_key = derive_key("another-secret-key-that-is-long-enough", "secret-box")
    response = await login_response(env)
    assert (response.status_code, error_code(response)) == (409, "owner_secret_unreadable")
    assert "user reset" in response.json()["error"]["message"]
    assert "user reset" in caplog.text  # and the operator sees it in the log
    # A wrong password still looks like any other failed login: nothing is revealed.
    wrong = await login_response(env, password="wrong password!!")
    assert (wrong.status_code, error_code(wrong)) == (401, "invalid_credentials")
    # `user reset` (under the new key) repairs it.
    async with env.sessionmaker() as session:
        enrollment = await upsert_owner(env.rt, session, password=PASSWORD, replace=True)
    env.totp_secret = enrollment.totp_secret
    assert (await login_response(env)).status_code == 200


# ------------------------------------------------------------------ MINOR-4: lockout


async def test_parallel_burst_of_wrong_logins_cannot_exceed_the_threshold(env: Env) -> None:
    responses = await asyncio.gather(*(login_response(env, **WRONG) for _ in range(40)))
    codes = [r.status_code for r in responses]
    assert codes.count(401) <= lockout.IP_THRESHOLD
    assert codes.count(401) + codes.count(429) == 40
    assert codes.count(429) >= 40 - lockout.IP_THRESHOLD
    locked = next(r for r in responses if r.status_code == 429)
    assert error_code(locked) == "too_many_attempts"
    assert int(locked.headers["Retry-After"]) >= 1
    assert (await login_response(env)).status_code == 429  # correct credentials do not bypass it


async def test_burst_from_many_addresses_stops_at_the_global_threshold(env: Env) -> None:
    env.settings.trust_forwarded_for = True

    async def attempt(index: int) -> int:
        body = env.login_body(code="000000")
        body["password"] = "wrong password!!"
        headers = {**SCHEMA, "X-Forwarded-For": f"10.1.{index // 200}.{index % 200}"}
        return (await env.client.post("/auth/login", json=body, headers=headers)).status_code

    codes = await asyncio.gather(*(attempt(i) for i in range(60)))
    assert codes.count(401) <= lockout.GLOBAL_THRESHOLD
    assert codes.count(429) >= 60 - lockout.GLOBAL_THRESHOLD


async def test_global_lock_is_capped_below_the_per_ip_cap(env: Env) -> None:
    env.settings.trust_forwarded_for = True
    for index in range(lockout.GLOBAL_THRESHOLD + 40):
        env.clock.advance(seconds=lockout.GLOBAL_MAX_LOCK_SECONDS + 1)
        body = env.login_body(code="000000")
        body["password"] = "wrong password!!"
        headers = {**SCHEMA, "X-Forwarded-For": f"10.2.0.{index % 200}"}
        await env.client.post("/auth/login", json=body, headers=headers)
    locked_until = await env.scalar(
        "SELECT locked_until FROM login_failures WHERE scope = 'global'"
    )
    assert locked_until - env.clock.now() <= timedelta(seconds=lockout.GLOBAL_MAX_LOCK_SECONDS)
    assert lockout.GLOBAL_MAX_LOCK_SECONDS < lockout.MAX_LOCK_SECONDS


async def test_success_clears_only_its_own_address_and_gives_the_global_attempt_back(
    env: Env,
) -> None:
    env.settings.trust_forwarded_for = True

    async def login_from(ip: str, *, ok: bool) -> Any:
        body = env.login_body() if ok else {**env.login_body(code="000000"), **WRONG}
        return await env.client.post(
            "/auth/login", json=body, headers={**SCHEMA, "X-Forwarded-For": ip}
        )

    for _ in range(3):
        await login_from("198.51.100.1", ok=False)
    await login_from("198.51.100.2", ok=False)
    assert (await login_from("198.51.100.2", ok=True)).status_code == 200
    rows = {(r.scope, r.key): r.failures for r in await _failure_rows(env)}
    assert rows == {("ip", "198.51.100.1"): 3, ("global", ""): 4}


async def _failure_rows(env: Env) -> list[Any]:
    async with env.sessionmaker() as session:
        return list((await session.execute(sa.text("SELECT * FROM login_failures"))).all())


async def test_a_successful_login_that_trips_the_global_threshold_is_not_a_failure(
    env: Env,
) -> None:
    env.settings.trust_forwarded_for = True
    for index in range(lockout.GLOBAL_THRESHOLD - 1):
        body = {**env.login_body(code="000000"), **WRONG}
        await env.client.post(
            "/auth/login", json=body, headers={**SCHEMA, "X-Forwarded-For": f"10.3.0.{index}"}
        )
    ok = await env.client.post(
        "/auth/login", json=env.login_body(), headers={**SCHEMA, "X-Forwarded-For": "10.3.9.9"}
    )
    assert ok.status_code == 200  # the 20th attempt, correct: allowed and gives its slot back
    assert await env.scalar("SELECT locked_until FROM login_failures WHERE scope='global'") is None
    again = await env.client.post(
        "/auth/login", json=env.login_body(), headers={**SCHEMA, "X-Forwarded-For": "10.3.9.8"}
    )
    assert again.status_code == 200


async def test_clear_all_lifts_every_lock(env: Env) -> None:
    for _ in range(lockout.IP_THRESHOLD):
        await login_response(env, **WRONG)
    assert (await login_response(env)).status_code == 429
    async with env.sessionmaker() as session, session.begin():
        assert await lockout.clear_all(session) == 2
    assert (await login_response(env)).status_code == 200


# ------------------------------------------------------------------ NIT-10


async def test_login_rehashes_when_the_cost_parameters_were_raised(env: Env) -> None:
    old = await env.scalar("SELECT password_hash FROM users")
    env.rt.hasher = PasswordHasher(time_cost=2, memory_cost=16, parallelism=1)
    assert env.rt.hasher.check_needs_rehash(old)
    assert (await login_response(env)).status_code == 200
    new = await env.scalar("SELECT password_hash FROM users")
    assert new != old
    assert not env.rt.hasher.check_needs_rehash(new)
    assert (await login_response(env)).status_code == 200  # the new hash verifies


def test_dummy_hash_follows_the_hashers_cost_not_its_identity(env: Env) -> None:
    a = PasswordHasher(time_cost=1, memory_cost=8, parallelism=1)
    b = PasswordHasher(time_cost=1, memory_cost=8, parallelism=1)
    c = make_hasher(env.settings.model_copy(update={"argon2_memory_kib": 16}))
    assert _dummy_hash(a) == _dummy_hash(b)
    assert _dummy_hash(a) != _dummy_hash(c)
    assert not c.check_needs_rehash(_dummy_hash(c))


async def test_failing_statements_do_not_put_parameters_into_errors(env: Env) -> None:
    engine = create_engine(env.settings)
    assert engine.sync_engine.hide_parameters is True
    secret = "very-secret-parameter"  # the driver's own message may still quote it: not ours
    try:
        async with engine.connect() as connection:
            with pytest.raises(DBAPIError) as caught:
                await connection.execute(sa.text("SELECT CAST(:x AS integer)"), {"x": secret})
    finally:
        await engine.dispose()
    assert "SQL parameters hidden" in str(caught.value)


async def test_login_response_carries_the_server_epoch(env: Env) -> None:
    body = (await login_response(env)).json()
    assert uuid.UUID(body["server_epoch"]).version == 4
