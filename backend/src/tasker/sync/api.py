import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from tasker.auth.deps import DeviceDep, RuntimeDep, SchemaDep, require_schema_version
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.sync import conflicts, engine
from tasker.sync.events import event_stream
from tasker.sync.pull import PULL_DEFAULT, PULL_MAX, pull_changes

router = APIRouter(tags=["sync"], dependencies=[Depends(require_schema_version)])


class PushIn(BaseModel):
    # Operations are validated one by one so a bad one cannot fail the whole batch.
    ops: Annotated[list[Any], Field(min_length=1)]


class OpResultOut(BaseModel):
    op_id: str | None
    status: Literal["applied", "rejected"]
    code: str | None
    message: str | None
    server_version: int | None
    conflicts: int
    duplicate: bool


class PushOut(BaseModel):
    results: list[OpResultOut]
    head_version: int
    server_epoch: str
    server_time: str


class ChangeOut(BaseModel):
    table: str
    id: str
    server_version: int
    row: dict[str, Any]


class PullOut(BaseModel):
    changes: list[ChangeOut]
    next_since: int
    has_more: bool
    head_version: int
    purge_watermark: int
    server_epoch: str
    server_time: str


class ConflictOut(BaseModel):
    id: str
    created_at: str
    table: str
    row_id: str
    field: str
    kind: str
    losing_value: Any
    winning_value: Any
    losing_device_id: str | None
    winning_device_id: str | None
    losing_hlc: str | None
    winning_hlc: str | None
    reverted_at: str | None


class ConflictsOut(BaseModel):
    conflicts: list[ConflictOut]
    next_before: str | None


class RevertOut(BaseModel):
    conflict: ConflictOut
    change: ChangeOut


@router.post("/sync/push")
async def push(body: PushIn, device: DeviceDep, session: SessionDep, rt: RuntimeDep) -> PushOut:
    if len(body.ops) > engine.BATCH_MAX:
        raise ApiError(
            413,
            "batch_too_large",
            f"At most {engine.BATCH_MAX} operations per push",
            details={"max": engine.BATCH_MAX},
        )
    now = rt.clock.now()
    result = await engine.apply_push(session, rt.registry, device.id, body.ops, now)
    return PushOut(
        results=[OpResultOut(**item) for item in result.results],
        head_version=result.head_version,
        server_epoch=result.server_epoch,
        server_time=engine.iso(now) or "",
    )


@router.get("/sync/pull")
async def pull(
    device: DeviceDep,
    session: SessionDep,
    rt: RuntimeDep,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=PULL_MAX)] = PULL_DEFAULT,
) -> PullOut:
    data = await pull_changes(
        session, rt.registry, device.id, since=since, limit=limit, now=rt.clock.now()
    )
    return PullOut(**data)


@router.get("/sync/conflicts")
async def get_conflicts(
    _: DeviceDep,
    session: SessionDep,
    reverted: Annotated[Literal["true", "false", "all"], Query()] = "all",
    limit: Annotated[int, Query(ge=1, le=conflicts.LIST_MAX)] = 50,
    before: uuid.UUID | None = None,
) -> ConflictsOut:
    data = await conflicts.list_conflicts(session, reverted=reverted, limit=limit, before=before)
    return ConflictsOut(**data)


@router.post("/sync/conflicts/{conflict_id}/revert")
async def revert(
    conflict_id: uuid.UUID, device: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> RevertOut:
    data = await conflicts.revert_conflict(
        session, rt.registry, device.id, conflict_id, rt.clock.now()
    )
    return RevertOut(**data)


@router.get("/events")
async def events(device: DeviceDep, rt: RuntimeDep) -> StreamingResponse:
    return StreamingResponse(
        event_stream(rt, device.id),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


__all__ = ["SchemaDep", "router"]
