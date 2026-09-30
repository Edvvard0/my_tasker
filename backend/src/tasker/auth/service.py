"""Login, refresh, logout and device registry (single owner account)."""

import hmac
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

import sqlalchemy as sa
import structlog
from cryptography.exceptions import InvalidTag
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.auth import lockout, totp
from tasker.auth.crypto import (
    TokenError,
    decrypt_secret,
    encrypt_secret,
    hash_refresh_token,
    new_refresh_token,
    parse_refresh_token,
)
from tasker.auth.passwords import hash_password, verify_password
from tasker.clock import Clock
from tasker.epoch import read_epoch
from tasker.errors import ApiError
from tasker.ids import uuid7
from tasker.runtime import ACCESS_TTL_SECONDS, REFRESH_TTL_DAYS, Runtime
from tasker.sync.engine import iso
from tasker.tables import devices, users

log = structlog.get_logger("auth")
TOTP_CONTEXT = "totp-secret"
REFRESH_GRACE = timedelta(seconds=60)
PLATFORMS = ("android", "windows", "linux", "macos", "ios", "web", "other")


@dataclass(frozen=True, slots=True)
class DeviceInfo:
    name: str
    platform: str
    app_version: str | None


def _token_pair(
    rt: Runtime, device_id: uuid.UUID, refresh: str, now: datetime, epoch: str
) -> dict[str, Any]:
    access_expires = now + timedelta(seconds=ACCESS_TTL_SECONDS)
    return {
        "device_id": str(device_id),
        "server_epoch": epoch,
        "token_type": "Bearer",
        "access_token": rt.codec.issue(device_id, now, access_expires),
        "access_expires_at": iso(access_expires),
        "refresh_token": refresh,
        "refresh_expires_at": iso(now + timedelta(days=REFRESH_TTL_DAYS)),
    }


def _invalid_credentials() -> ApiError:
    return ApiError(401, "invalid_credentials", "Invalid password or code")


async def login(
    rt: Runtime, session: AsyncSession, *, password: str, code: str, info: DeviceInfo, ip: str
) -> dict[str, Any]:
    now = rt.clock.now()
    try:
        # Counting the attempt and checking the locks is one atomic step, committed before the
        # slow password check: a parallel burst cannot exceed the threshold (spec 1.1).
        async with session.begin():
            reservation = await lockout.reserve(session, now, ip)
    except lockout.LockedError as locked:
        wait = locked.retry_after_seconds
        raise ApiError(
            429,
            "too_many_attempts",
            "Too many failed attempts; try again later",
            details={"retry_after_seconds": wait},
            headers={"Retry-After": str(wait)},
        ) from locked

    async with session.begin():
        user = (await session.execute(sa.select(users))).first()
    step: int | None = None
    ok = await verify_password(rt.hasher, None if user is None else user.password_hash, password)
    if ok and user is not None:
        try:
            secret = decrypt_secret(rt.box_key, user.totp_secret_enc, context=TOTP_CONTEXT)
        except InvalidTag as exc:
            # The password was right, so this is the owner: tell them what to do.
            log.error(
                "totp_secret_undecryptable",
                hint="APP_SECRET_KEY changed since the owner was created; "
                "run `python -m tasker.cli user reset` on the server",
            )
            raise ApiError(
                409,
                "owner_secret_unreadable",
                "The server secret key changed; run `python -m tasker.cli user reset`",
            ) from exc
        step = totp.verify(secret, code, now.timestamp(), int(user.totp_last_step))
    if user is None or step is None:
        log.info("login_failed")  # the attempt was already counted by ``reserve``
        raise _invalid_credentials()

    new_hash = (
        await hash_password(rt.hasher, password)
        if rt.hasher.check_needs_rehash(user.password_hash)
        else None
    )
    device_id = uuid7()
    refresh = new_refresh_token(device_id)
    async with session.begin():
        claimed = await session.execute(
            sa.update(users)
            .where(users.c.id == user.id, users.c.totp_last_step < step)
            .values(totp_last_step=step)
            .returning(users.c.id)
        )
        if claimed.first() is None:  # a concurrent login used this code first: stays counted
            replay = True
            epoch = ""
        else:
            replay = False
            await lockout.release(session, reservation)
            if new_hash is not None:  # cost parameters were raised since the hash was made
                await session.execute(sa.update(users).values(password_hash=new_hash))
            await session.execute(
                sa.insert(devices).values(
                    id=device_id,
                    name=info.name,
                    platform=info.platform,
                    app_version=info.app_version,
                    created_at=now,
                    last_seen_at=now,
                    last_pulled_version=0,
                    refresh_token_hash=hash_refresh_token(refresh),
                    refresh_expires_at=now + timedelta(days=REFRESH_TTL_DAYS),
                )
            )
            epoch = await read_epoch(session)
    if replay:
        raise _invalid_credentials()
    log.info("login_ok", device_id=str(device_id), platform=info.platform)
    return _token_pair(rt, device_id, refresh, now, epoch)


async def refresh(rt: Runtime, session: AsyncSession, token: str) -> dict[str, Any]:
    """Rotate the refresh token (spec 1.3), with a 60 s grace for a lost response.

    The token just replaced is still honoured for ``REFRESH_GRACE`` as long as its successor was
    not used (neither refreshed nor seen on an authenticated request, see ``deps``): the client
    then gets a fresh pair and the unused successor dies. Anything older, or a successor already
    in use, is reuse and revokes the device.
    """
    now = rt.clock.now()
    try:
        device_id = parse_refresh_token(token)
    except TokenError as exc:
        raise ApiError(401, exc.code, "Invalid refresh token") from exc
    presented = hash_refresh_token(token)
    async with session.begin():
        device = (
            await session.execute(
                sa.select(devices).where(devices.c.id == device_id).with_for_update()
            )
        ).first()
        if device is None:
            raise ApiError(401, "invalid_refresh_token", "Invalid refresh token")
        if device.revoked_at is not None:
            raise ApiError(401, "device_revoked", "This device was revoked")
        current = hmac.compare_digest(presented.encode(), device.refresh_token_hash.encode())
        in_grace = (
            not current
            and device.prev_refresh_token_hash is not None
            and device.prev_rotated_at is not None
            and now - device.prev_rotated_at <= REFRESH_GRACE
            and hmac.compare_digest(presented.encode(), device.prev_refresh_token_hash.encode())
        )
        if not current and not in_grace:
            await _revoke(session, device_id, now, "refresh_reuse")
            reuse = True
        elif device.refresh_expires_at <= now:
            raise ApiError(401, "refresh_expired", "Refresh token expired")
        else:
            reuse = False
            new_token = new_refresh_token(device_id)
            values: dict[str, Any] = {
                "refresh_token_hash": hash_refresh_token(new_token),
                "refresh_expires_at": now + timedelta(days=REFRESH_TTL_DAYS),
                "last_seen_at": now,
            }
            if current:  # a normal rotation: remember the replaced token for the grace period
                values.update(
                    prev_refresh_token_hash=device.refresh_token_hash, prev_rotated_at=now
                )
            # In grace: the unused successor is replaced; the grace window keeps running from
            # the original rotation, so retries cannot extend it.
            await session.execute(
                sa.update(devices).where(devices.c.id == device_id).values(**values)
            )
            epoch = await read_epoch(session)
    if reuse:
        log.warning("refresh_reuse_detected", device_id=str(device_id))
        raise ApiError(
            401, "refresh_reuse_detected", "Refresh token reuse detected; the device was revoked"
        )
    return _token_pair(rt, device_id, new_token, now, epoch)


async def _revoke(session: AsyncSession, device_id: uuid.UUID, now: datetime, reason: str) -> None:
    await session.execute(
        sa.update(devices)
        .where(devices.c.id == device_id, devices.c.revoked_at.is_(None))
        .values(revoked_at=now, revoked_reason=reason)
    )


async def revoke_device(
    session: AsyncSession, clock: Clock, device_id: uuid.UUID, reason: str
) -> bool:
    """Revoke a device; ``False`` when it does not exist. Idempotent."""
    async with session.begin():
        exists = (
            await session.execute(sa.select(devices.c.id).where(devices.c.id == device_id))
        ).first()
        if exists is None:
            return False
        await _revoke(session, device_id, clock.now(), reason)
    return True


async def list_devices(
    session: AsyncSession, current: uuid.UUID, *, include_revoked: bool
) -> list[dict[str, Any]]:
    query = sa.select(devices).order_by(devices.c.created_at)
    if not include_revoked:
        query = query.where(devices.c.revoked_at.is_(None))
    rows = (await session.execute(query)).all()
    return [
        {
            "id": str(row.id),
            "name": row.name,
            "platform": row.platform,
            "app_version": row.app_version,
            "created_at": iso(row.created_at),
            "last_seen_at": iso(row.last_seen_at),
            "last_pulled_version": int(row.last_pulled_version),
            "revoked_at": iso(row.revoked_at),
            "is_current": row.id == current,
        }
        for row in rows
    ]


@dataclass(frozen=True, slots=True)
class OwnerEnrollment:
    otpauth_uri: str
    totp_secret: str


async def upsert_owner(
    rt: Runtime, session: AsyncSession, *, password: str, replace: bool
) -> OwnerEnrollment:
    """Create the single owner (``replace=False``) or reset password+TOTP and revoke all devices."""
    now = rt.clock.now()
    secret = totp.generate_secret()
    password_hash = await hash_password(rt.hasher, password)
    encrypted = encrypt_secret(rt.box_key, secret, context=TOTP_CONTEXT)
    async with session.begin():
        existing = (await session.execute(sa.select(users.c.id).with_for_update())).first()
        if existing is None and replace:
            raise LookupError("no owner exists; use `user create`")
        if existing is not None and not replace:
            raise FileExistsError("the owner already exists; use `user reset`")
        if existing is None:
            await session.execute(
                sa.insert(users).values(
                    id=uuid7(),
                    password_hash=password_hash,
                    totp_secret_enc=encrypted,
                    totp_last_step=0,
                    created_at=now,
                    updated_at=now,
                )
            )
        else:
            await session.execute(
                sa.update(users).values(
                    password_hash=password_hash,
                    totp_secret_enc=encrypted,
                    totp_last_step=0,
                    updated_at=now,
                )
            )
            await session.execute(
                sa.update(devices)
                .where(devices.c.revoked_at.is_(None))
                .values(revoked_at=now, revoked_reason="password_reset")
            )
            await lockout.clear_all(session)  # a locked-out owner resets to get back in
    return OwnerEnrollment(totp.otpauth_uri(secret), secret)
