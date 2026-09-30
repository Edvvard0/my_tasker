"""Request dependencies: schema-version negotiation and bearer-token authentication."""

import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Annotated

import sqlalchemy as sa
from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.auth.crypto import TokenError
from tasker.clock import to_ms
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.runtime import Runtime, get_runtime
from tasker.tables import devices
from tasker.version import API_SCHEMA_VERSION, MIN_CLIENT_SCHEMA_VERSION

SCHEMA_HEADER = "X-Client-Schema-Version"
LAST_SEEN_GRANULARITY = timedelta(seconds=60)

RuntimeDep = Annotated[Runtime, Depends(get_runtime)]


async def require_schema_version(request: Request) -> int:
    raw = request.headers.get(SCHEMA_HEADER, "")
    if not raw.isascii() or not raw.isdigit():
        raise ApiError(400, "schema_version_required", f"{SCHEMA_HEADER} header is required")
    version = int(raw)
    if version < MIN_CLIENT_SCHEMA_VERSION:
        raise ApiError(
            426,
            "client_too_old",
            "The app must be updated",
            details={
                "min_client_schema_version": MIN_CLIENT_SCHEMA_VERSION,
                "api_schema_version": API_SCHEMA_VERSION,
            },
        )
    return version


SchemaDep = Annotated[int, Depends(require_schema_version)]


@dataclass(frozen=True, slots=True)
class AuthDevice:
    id: uuid.UUID
    name: str


def client_ip(request: Request, trust_forwarded_for: bool) -> str:
    if trust_forwarded_for:
        forwarded = request.headers.get("x-forwarded-for", "")
        if forwarded:
            return _clean_ip(forwarded.split(",")[-1])
    return _clean_ip(request.client.host) if request.client else "unknown"


def _clean_ip(raw: str) -> str:
    """The address as a database-safe key (no NUL, bounded)."""
    return raw.replace("\x00", "").strip()[:64] or "unknown"


def _unauthorized(code: str, message: str) -> ApiError:
    return ApiError(401, code, message, headers={"WWW-Authenticate": "Bearer"})


async def _authenticate(request: Request, session: AsyncSession, rt: Runtime) -> AuthDevice:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise _unauthorized("not_authenticated", "Authentication required")
    now = rt.clock.now()
    try:
        claims = rt.codec.verify_claims(token.strip(), now)
    except TokenError as exc:
        raise _unauthorized(exc.code, "Access token is not valid") from exc
    device_id = claims.device_id
    async with session.begin():
        device = (
            await session.execute(
                sa.select(
                    devices.c.id,
                    devices.c.name,
                    devices.c.revoked_at,
                    devices.c.last_seen_at,
                    devices.c.prev_refresh_token_hash,
                    devices.c.prev_rotated_at,
                ).where(devices.c.id == device_id)
            )
        ).first()
        if device is None:
            raise _unauthorized("invalid_token", "Access token is not valid")
        if device.revoked_at is not None:
            raise _unauthorized("device_revoked", "This device was revoked")
        if device.prev_rotated_at is not None and claims.issued_ms >= to_ms(device.prev_rotated_at):
            # An access token from the successor refresh token is in use: the previous refresh
            # token loses its grace period (spec 1.3).
            await session.execute(
                sa.update(devices)
                .where(devices.c.id == device_id)
                .values(prev_refresh_token_hash=None, prev_rotated_at=None)
            )
        if now - device.last_seen_at >= LAST_SEEN_GRANULARITY:
            await session.execute(
                sa.update(devices).where(devices.c.id == device_id).values(last_seen_at=now)
            )
    return AuthDevice(device.id, device.name)


async def current_device(request: Request, session: SessionDep, rt: RuntimeDep) -> AuthDevice:
    return await _authenticate(request, session, rt)


DeviceDep = Annotated[AuthDevice, Depends(current_device)]
