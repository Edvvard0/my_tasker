import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import BaseModel, Field

from tasker.auth import service
from tasker.auth.deps import DeviceDep, RuntimeDep, SchemaDep, client_ip, require_schema_version
from tasker.db import SessionDep
from tasker.errors import ApiError

router = APIRouter(prefix="/auth", tags=["auth"])


class DeviceIn(BaseModel):
    name: Annotated[str, Field(min_length=1, max_length=64)]
    platform: Literal["android", "windows", "linux", "macos", "ios", "web", "other"]
    app_version: Annotated[str, Field(max_length=32)] | None = None


class LoginIn(BaseModel):
    password: Annotated[str, Field(min_length=1, max_length=256)]
    totp_code: Annotated[str, Field(pattern=r"^[0-9]{6}$")]
    device: DeviceIn


class RefreshIn(BaseModel):
    refresh_token: Annotated[str, Field(min_length=1, max_length=512)]


class TokenPairOut(BaseModel):
    device_id: str
    token_type: str
    access_token: str
    access_expires_at: str
    refresh_token: str
    refresh_expires_at: str


class DeviceOut(BaseModel):
    id: str
    name: str
    platform: str
    app_version: str | None
    created_at: str
    last_seen_at: str
    last_pulled_version: int
    revoked_at: str | None
    is_current: bool


class DevicesOut(BaseModel):
    devices: list[DeviceOut]


@router.post("/login", dependencies=[Depends(require_schema_version)])
async def login(
    body: LoginIn, request: Request, session: SessionDep, rt: RuntimeDep
) -> TokenPairOut:
    info = service.DeviceInfo(body.device.name, body.device.platform, body.device.app_version)
    ip = client_ip(request, rt.settings.trust_forwarded_for)
    pair = await service.login(
        rt, session, password=body.password, code=body.totp_code, info=info, ip=ip
    )
    return TokenPairOut(**pair)


@router.post("/refresh", dependencies=[Depends(require_schema_version)])
async def refresh(body: RefreshIn, session: SessionDep, rt: RuntimeDep) -> TokenPairOut:
    return TokenPairOut(**await service.refresh(rt, session, body.refresh_token))


@router.post("/logout", status_code=204)
async def logout(device: DeviceDep, session: SessionDep, rt: RuntimeDep) -> Response:
    await service.revoke_device(session, rt.clock, device.id, "logout")
    return Response(status_code=204)


@router.get("/devices")
async def get_devices(
    device: DeviceDep, session: SessionDep, include_revoked: Annotated[bool, Query()] = False
) -> DevicesOut:
    rows: list[dict[str, Any]] = await service.list_devices(
        session, device.id, include_revoked=include_revoked
    )
    return DevicesOut(devices=[DeviceOut(**row) for row in rows])


@router.delete("/devices/{device_id}", status_code=204)
async def delete_device(
    device_id: uuid.UUID, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> Response:
    if not await service.revoke_device(session, rt.clock, device_id, "user"):
        raise ApiError(404, "device_not_found", "No such device")
    return Response(status_code=204)


__all__ = ["SchemaDep", "router"]
