import uuid
from datetime import timedelta
from typing import Any

import pytest

from tasker.auth import lockout
from tests.api_support import PASSWORD, SCHEMA, Env


def error_code(response: Any) -> str:
    body = response.json()
    assert set(body) == {"error"}
    code: str = body["error"]["code"]
    return code


async def login_response(env: Env, **overrides: Any) -> Any:
    body = env.login_body(code=overrides.get("totp_code"))
    body.update(overrides)
    return await env.client.post("/auth/login", json=body, headers=SCHEMA)


async def test_login_success(env: Env) -> None:
    response = await login_response(env)
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "Bearer"
    assert uuid.UUID(body["device_id"]).version == 7
    assert body["access_token"].startswith("at1.")
    assert body["refresh_token"].startswith("rt1.")
    assert body["access_expires_at"].endswith("Z")
    devices = await env.client.get(
        "/auth/devices", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert devices.status_code == 200
    (device,) = devices.json()["devices"]
    assert device["id"] == body["device_id"]
    assert (device["name"], device["platform"], device["app_version"]) == (
        "Phone",
        "android",
        "0.1.0",
    )
    assert device["is_current"] is True
    assert device["last_pulled_version"] == 0
    assert device["revoked_at"] is None


async def test_each_login_registers_a_new_device(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    assert phone.device_id != pc.device_id
    listed = (await phone.get("/auth/devices")).json()["devices"]
    assert [d["name"] for d in listed] == ["Phone", "PC"]
    assert [d["is_current"] for d in listed] == [True, False]


@pytest.mark.parametrize("bad", ["password", "code", "no_user"])
async def test_login_failures_are_indistinguishable(env: Env, bad: str) -> None:
    if bad == "no_user":
        await env.execute("DELETE FROM users")
        response = await login_response(env)
    elif bad == "password":
        response = await login_response(env, password="wrong password!!", totp_code="000000")
    else:
        response = await login_response(env, totp_code="000000")
    assert response.status_code == 401
    assert error_code(response) == "invalid_credentials"
    assert await env.scalar("SELECT count(*) FROM devices") == 0


async def test_login_rejects_reused_totp_code(env: Env) -> None:
    code = env.next_code()
    assert (await login_response(env, totp_code=code)).status_code == 200
    replay = await login_response(env, totp_code=code)
    assert (replay.status_code, error_code(replay)) == (401, "invalid_credentials")


async def test_login_validation_does_not_echo_secrets(env: Env) -> None:
    response = await env.client.post(
        "/auth/login",
        json={"password": "hunter2-secret-value", "totp_code": "12", "device": {}},
        headers=SCHEMA,
    )
    assert response.status_code == 422
    assert error_code(response) == "validation_error"
    assert "hunter2-secret-value" not in response.text
    assert "input" not in response.text


@pytest.mark.parametrize(
    "device",
    [
        {"name": "", "platform": "android"},
        {"name": "x" * 65, "platform": "android"},
        {"name": "ok", "platform": "playstation"},
        {"name": "ok", "platform": "android", "app_version": "v" * 33},
    ],
)
async def test_login_validates_device(env: Env, device: dict[str, Any]) -> None:
    assert (await login_response(env, device=device)).status_code == 422


@pytest.mark.parametrize("path", ["/auth/login", "/auth/refresh", "/sync/pull", "/events"])
async def test_schema_version_header_is_required_and_checked(env: Env, path: str) -> None:
    device = await env.login()
    auth = {"Authorization": f"Bearer {device.access_token}"}
    method = env.client.get if path in {"/sync/pull", "/events"} else env.client.post
    kwargs: dict[str, Any] = {} if method == env.client.get else {"json": {}}
    missing = await method(path, headers=auth, **kwargs)
    assert (missing.status_code, error_code(missing)) == (400, "schema_version_required")
    garbage = await method(path, headers={**auth, "X-Client-Schema-Version": "abc"}, **kwargs)
    assert error_code(garbage) == "schema_version_required"
    old = await method(path, headers={**auth, "X-Client-Schema-Version": "0"}, **kwargs)
    assert (old.status_code, error_code(old)) == (426, "client_too_old")
    details = old.json()["error"]["details"]
    assert details == {"min_client_schema_version": 1, "api_schema_version": 1}


async def test_lockout_after_repeated_failures_with_backoff(env: Env) -> None:
    for _ in range(lockout.IP_THRESHOLD - 1):
        assert (
            await login_response(env, password="wrong password!!", totp_code="000000")
        ).status_code == 401
    blocked = await login_response(env, password="wrong password!!", totp_code="000000")
    assert blocked.status_code == 401  # the failure that crosses the threshold itself
    locked = await login_response(env)  # even correct credentials are refused now
    assert locked.status_code == 429
    assert error_code(locked) == "too_many_attempts"
    assert locked.headers["Retry-After"] == "30"
    assert locked.json()["error"]["details"]["retry_after_seconds"] == 30

    env.clock.advance(seconds=31)
    again = await login_response(
        env, password="wrong password!!", totp_code="000000"
    )  # 6th failure: 60 s lock
    assert again.status_code == 401
    env.clock.advance(seconds=31)
    assert (await login_response(env)).status_code == 429
    env.clock.advance(seconds=30)
    assert (await login_response(env)).status_code == 200


async def test_lockout_is_capped_and_success_resets(env: Env) -> None:
    for _ in range(lockout.IP_THRESHOLD + 10):
        env.clock.advance(seconds=1000)
        await login_response(env, password="wrong password!!", totp_code="000000")
    row = await env.scalar("SELECT failures FROM login_failures WHERE scope='ip'")
    assert row >= lockout.IP_THRESHOLD
    env.clock.advance(seconds=lockout.MAX_LOCK_SECONDS + 1)
    assert (await login_response(env)).status_code == 200
    assert await env.scalar("SELECT count(*) FROM login_failures WHERE scope='ip'") == 0


async def test_failures_are_forgotten_after_an_hour(env: Env) -> None:
    for _ in range(lockout.IP_THRESHOLD - 1):
        await login_response(env, password="wrong password!!", totp_code="000000")
    env.clock.advance(hours=2)
    await login_response(env, password="wrong password!!", totp_code="000000")
    assert await env.scalar("SELECT failures FROM login_failures WHERE scope='ip'") == 1


async def test_global_lockout_across_addresses(env: Env) -> None:
    env.settings.trust_forwarded_for = True
    for index in range(lockout.GLOBAL_THRESHOLD):
        body = env.login_body(code="000000")
        body["password"] = "wrong password!!"
        headers = {**SCHEMA, "X-Forwarded-For": f"10.0.0.{index}"}
        response = await env.client.post("/auth/login", json=body, headers=headers)
        assert response.status_code == 401
    fresh = {**SCHEMA, "X-Forwarded-For": "192.0.2.77"}
    blocked = await env.client.post("/auth/login", json=env.login_body(), headers=fresh)
    assert blocked.status_code == 429


async def test_forwarded_for_ignored_unless_trusted(env: Env) -> None:
    body = env.login_body()
    body["password"] = "wrong password!!"
    await env.client.post(
        "/auth/login", json=body, headers={**SCHEMA, "X-Forwarded-For": "9.9.9.9"}
    )
    assert await env.scalar("SELECT key FROM login_failures WHERE scope='ip'") != "9.9.9.9"


async def test_refresh_rotates_tokens(env: Env) -> None:
    device = await env.login()
    env.clock.advance(seconds=5)
    response = await env.client.post(
        "/auth/refresh", json={"refresh_token": device.refresh_token}, headers=SCHEMA
    )
    assert response.status_code == 200
    body = response.json()
    assert body["device_id"] == str(device.device_id)
    assert body["refresh_token"] != device.refresh_token
    assert body["access_token"] != device.access_token
    third = await env.client.post(
        "/auth/refresh", json={"refresh_token": body["refresh_token"]}, headers=SCHEMA
    )
    assert third.status_code == 200
    new_access = {"Authorization": f"Bearer {body['access_token']}"}
    assert (await env.client.get("/auth/devices", headers=new_access)).status_code == 200


async def test_refresh_token_reuse_revokes_the_device(env: Env) -> None:
    device = await env.login()
    old = device.refresh_token
    rotated = (
        await env.client.post("/auth/refresh", json={"refresh_token": old}, headers=SCHEMA)
    ).json()
    reuse = await env.client.post("/auth/refresh", json={"refresh_token": old}, headers=SCHEMA)
    assert (reuse.status_code, error_code(reuse)) == (401, "refresh_reuse_detected")
    # The legitimately rotated token and the access token die with the device.
    latest = await env.client.post(
        "/auth/refresh", json={"refresh_token": rotated["refresh_token"]}, headers=SCHEMA
    )
    assert error_code(latest) == "device_revoked"
    access = await device.get("/auth/devices")
    assert (access.status_code, error_code(access)) == (401, "device_revoked")
    assert await env.scalar("SELECT revoked_reason FROM devices") == "refresh_reuse"


@pytest.mark.parametrize(
    "token", ["", "nonsense", "rt1.00000000000000000000000000000000." + "a" * 43]
)
async def test_refresh_rejects_unknown_tokens(env: Env, token: str) -> None:
    response = await env.client.post(
        "/auth/refresh", json={"refresh_token": token or "x"}, headers=SCHEMA
    )
    assert response.status_code == 401
    assert error_code(response) == "invalid_refresh_token"


async def test_refresh_rejects_expired_token(env: Env) -> None:
    device = await env.login()
    env.clock.advance(days=91)
    response = await env.client.post(
        "/auth/refresh", json={"refresh_token": device.refresh_token}, headers=SCHEMA
    )
    assert (response.status_code, error_code(response)) == (401, "refresh_expired")


async def test_refresh_extends_lifetime(env: Env) -> None:
    device = await env.login()
    env.clock.advance(days=60)
    rotated = (
        await env.client.post(
            "/auth/refresh", json={"refresh_token": device.refresh_token}, headers=SCHEMA
        )
    ).json()
    env.clock.advance(days=60)
    again = await env.client.post(
        "/auth/refresh", json={"refresh_token": rotated["refresh_token"]}, headers=SCHEMA
    )
    assert again.status_code == 200


async def test_access_token_errors(env: Env) -> None:
    device = await env.login()
    none = await env.client.get("/auth/devices")
    assert (none.status_code, error_code(none)) == (401, "not_authenticated")
    assert none.headers["WWW-Authenticate"] == "Bearer"
    basic = await env.client.get("/auth/devices", headers={"Authorization": "Basic abc"})
    assert error_code(basic) == "not_authenticated"
    forged = await env.client.get("/auth/devices", headers={"Authorization": "Bearer at1.a.b"})
    assert error_code(forged) == "invalid_token"
    env.clock.advance(minutes=16)
    expired = await device.get("/auth/devices")
    assert (expired.status_code, error_code(expired)) == (401, "token_expired")


async def test_token_of_unknown_device_is_invalid(env: Env) -> None:
    device = await env.login()
    await env.execute("DELETE FROM devices")
    response = await device.get("/auth/devices")
    assert error_code(response) == "invalid_token"


async def test_logout_revokes_current_device_only(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    assert (await phone.post("/auth/logout")).status_code == 204
    assert error_code(await phone.get("/auth/devices")) == "device_revoked"
    assert (await pc.get("/auth/devices")).status_code == 200
    refresh = await env.client.post(
        "/auth/refresh", json={"refresh_token": phone.refresh_token}, headers=SCHEMA
    )
    assert error_code(refresh) == "device_revoked"


async def test_revoke_device_blocks_every_endpoint(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    assert (
        await pc.env.client.delete(f"/auth/devices/{phone.device_id}", headers=pc.headers)
    ).status_code == 204
    for response in (
        await phone.get("/auth/devices"),
        await phone.pull(),
        await phone.push([]),
        await phone.get("/events"),
        await phone.get("/sync/conflicts"),
    ):
        assert response.status_code in {401, 422}
    for response in (
        await phone.get("/auth/devices"),
        await phone.pull(),
        await phone.get("/events"),
    ):
        assert (response.status_code, error_code(response)) == (401, "device_revoked")
    # Idempotent, and hidden by default in the list.
    again = await env.client.delete(f"/auth/devices/{phone.device_id}", headers=pc.headers)
    assert again.status_code == 204
    assert [d["name"] for d in (await pc.get("/auth/devices")).json()["devices"]] == ["PC"]
    everything = (await pc.get("/auth/devices", include_revoked="true")).json()["devices"]
    assert [(d["name"], d["revoked_at"] is not None) for d in everything] == [
        ("Phone", True),
        ("PC", False),
    ]


async def test_revoke_unknown_device_is_404(env: Env) -> None:
    pc = await env.login("PC")
    response = await env.client.delete(f"/auth/devices/{uuid.uuid4()}", headers=pc.headers)
    assert (response.status_code, error_code(response)) == (404, "device_not_found")
    bad = await env.client.delete("/auth/devices/not-a-uuid", headers=pc.headers)
    assert bad.status_code == 422


async def test_revoking_self_is_allowed(env: Env) -> None:
    pc = await env.login("PC")
    response = await env.client.delete(f"/auth/devices/{pc.device_id}", headers=pc.headers)
    assert response.status_code == 204
    assert error_code(await pc.get("/auth/devices")) == "device_revoked"


async def test_last_seen_is_updated_at_most_once_a_minute(env: Env) -> None:
    device = await env.login()
    before = await env.scalar("SELECT last_seen_at FROM devices")
    env.clock.advance(seconds=30)
    await device.get("/auth/devices")
    assert await env.scalar("SELECT last_seen_at FROM devices") == before
    env.clock.advance(seconds=31)
    await device.get("/auth/devices")
    assert await env.scalar("SELECT last_seen_at FROM devices") == before + timedelta(seconds=61)


async def test_credentials_never_reach_logs(env: Env, capsys: pytest.CaptureFixture[str]) -> None:
    device = await env.login()
    await env.client.post(
        "/auth/login",
        json={**env.login_body(), "password": "wrong-but-recognisable"},
        headers=SCHEMA,
    )
    await env.client.post(
        "/auth/refresh", json={"refresh_token": device.refresh_token}, headers=SCHEMA
    )
    output = capsys.readouterr().out
    assert PASSWORD not in output
    assert "wrong-but-recognisable" not in output
    assert device.refresh_token not in output
    assert device.access_token not in output
    assert env.totp_secret not in output


async def test_404_and_405_use_the_error_shape(env: Env) -> None:
    missing = await env.client.get("/nope")
    assert (missing.status_code, error_code(missing)) == (404, "not_found")
    wrong = await env.client.get("/auth/login")
    assert (wrong.status_code, error_code(wrong)) == (405, "method_not_allowed")
