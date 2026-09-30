import base64
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from argon2 import PasswordHasher
from cryptography.exceptions import InvalidTag

from tasker.auth import totp
from tasker.auth.crypto import (
    AccessTokenCodec,
    TokenError,
    decrypt_secret,
    derive_key,
    encrypt_secret,
    hash_refresh_token,
    new_refresh_token,
    parse_refresh_token,
)
from tasker.auth.passwords import hash_password, verify_password

RFC_SECRET = base64.b32encode(b"12345678901234567890").decode()


@pytest.mark.parametrize(
    ("unix_time", "code"),
    [
        (59, "287082"),
        (1111111109, "081804"),
        (1111111111, "050471"),
        (1234567890, "005924"),
        (2000000000, "279037"),
        (20000000000, "353130"),
    ],
)
def test_totp_rfc6238_vectors(unix_time: int, code: str) -> None:
    assert totp.code_for_step(RFC_SECRET, totp.current_step(unix_time)) == code
    assert totp.verify(RFC_SECRET, code, unix_time, 0) == totp.current_step(unix_time)


def test_totp_window_and_replay() -> None:
    now = 1_700_000_000.0
    step = totp.current_step(now)
    previous = totp.code_for_step(RFC_SECRET, step - 1)
    assert totp.verify(RFC_SECRET, previous, now, 0) == step - 1
    too_old = totp.code_for_step(RFC_SECRET, step - 2)
    assert totp.verify(RFC_SECRET, too_old, now, 0) is None
    too_new = totp.code_for_step(RFC_SECRET, step + 2)
    assert totp.verify(RFC_SECRET, too_new, now, 0) is None
    current = totp.code_for_step(RFC_SECRET, step)
    assert totp.verify(RFC_SECRET, current, now, step) is None  # replay of a used step


@pytest.mark.parametrize("bad", ["", "12345", "1234567", "12345a", "١٢٣٤٥٦"])
def test_totp_rejects_malformed_codes(bad: str) -> None:
    assert totp.verify(RFC_SECRET, bad, 59, 0) is None


def test_totp_secret_and_uri() -> None:
    secret = totp.generate_secret()
    assert len(secret) == 32
    assert totp.generate_secret() != secret
    uri = totp.otpauth_uri(secret, issuer="My Tasker", account="owner")
    assert uri.startswith("otpauth://totp/My%20Tasker%3Aowner?secret=" + secret)
    assert "issuer=My%20Tasker" in uri


def test_secret_box_roundtrip_and_binding() -> None:
    key = derive_key("m" * 40, "secret-box")
    sealed = encrypt_secret(key, "JBSWY3DPEHPK3PXP", context="totp")
    assert "JBSWY3DPEHPK3PXP" not in sealed
    assert decrypt_secret(key, sealed, context="totp") == "JBSWY3DPEHPK3PXP"
    with pytest.raises(InvalidTag):
        decrypt_secret(key, sealed, context="other")
    with pytest.raises(InvalidTag):
        decrypt_secret(derive_key("x" * 40, "secret-box"), sealed, context="totp")
    assert derive_key("m" * 40, "a") != derive_key("m" * 40, "b")


def test_access_token_lifecycle() -> None:
    codec = AccessTokenCodec(derive_key("m" * 40, "access-token"))
    now = datetime(2026, 10, 1, tzinfo=UTC)
    device = uuid.uuid4()
    token = codec.issue(device, now, now + timedelta(minutes=15))
    assert codec.verify(token, now) == device
    with pytest.raises(TokenError) as expired:
        codec.verify(token, now + timedelta(minutes=15))
    assert expired.value.code == "token_expired"
    prefix, payload, signature = token.split(".")
    for forged in (
        f"{prefix}.{payload}.{signature[:-2]}AA",
        f"{prefix}.{payload}x.{signature}",
        "garbage",
        "at1.a.b.c",
        f"at2.{payload}.{signature}",
    ):
        with pytest.raises(TokenError) as invalid:
            codec.verify(forged, now)
        assert invalid.value.code == "invalid_token"
    other = AccessTokenCodec(derive_key("z" * 40, "access-token"))
    with pytest.raises(TokenError):
        other.verify(token, now)


def test_access_token_with_bad_claims_is_invalid() -> None:
    codec = AccessTokenCodec(derive_key("m" * 40, "access-token"))
    now = datetime(2026, 10, 1, tzinfo=UTC)
    payload = base64.urlsafe_b64encode(b'{"d":"not-a-uuid","e":9999999999}').decode().rstrip("=")
    token = f"at1.{payload}.{codec._sign(payload)}"
    with pytest.raises(TokenError) as exc:
        codec.verify(token, now)
    assert exc.value.code == "invalid_token"


def test_refresh_token_format() -> None:
    device = uuid.uuid4()
    token = new_refresh_token(device)
    assert parse_refresh_token(token) == device
    assert new_refresh_token(device) != token
    assert hash_refresh_token(token) != token
    for bad in (
        "",
        "rt1.zz.abc",
        f"rt1.{'z' * 32}.{'a' * 40}",
        f"rt2.{device.hex}.{'a' * 40}",
        f"rt1.{device.hex}.short",
    ):
        with pytest.raises(TokenError):
            parse_refresh_token(bad)


async def test_password_hashing() -> None:
    hasher = PasswordHasher(time_cost=1, memory_cost=8, parallelism=1)
    hashed = await hash_password(hasher, "correct horse battery")
    assert hashed.startswith("$argon2id$")
    assert await verify_password(hasher, hashed, "correct horse battery")
    assert not await verify_password(hasher, hashed, "wrong")
    assert not await verify_password(hasher, None, "anything")
    assert not await verify_password(hasher, None, "dummy-password-for-timing")
    assert not await verify_password(hasher, "not-a-hash", "x")
