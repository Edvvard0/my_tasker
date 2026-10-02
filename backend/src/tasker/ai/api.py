"""HTTP surface of Stage 3 (spec stage3, section 3)."""

import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from typing import Annotated, Any
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from tasker.ai import agents, builtin, spend
from tasker.ai.catalog import ModelInfo
from tasker.ai.chat import ChatRequest, prepare
from tasker.ai.runner import ChatRun
from tasker.ai.runtime import AiRuntime, get_ai
from tasker.ai.tools import TOOLS
from tasker.ai.upstream import UpstreamError
from tasker.auth.deps import DeviceDep, RuntimeDep, require_schema_version
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.sync.registry import SyncRegistry

_ = builtin  # importing registers the built-in tools

router = APIRouter(tags=["ai"], dependencies=[Depends(require_schema_version)])
AiDep = Annotated[AiRuntime, Depends(get_ai)]


class AgentOut(BaseModel):
    seed_key: str
    id: str
    name: str


class BootstrapOut(BaseModel):
    agents: list[AgentOut]
    tools: list[dict[str, Any]]
    seed_prompt_version: int


class ChangesOut(BaseModel):
    changes: list[dict[str, Any]]


class ModelsOut(BaseModel):
    models: list[dict[str, Any]]
    fetched_at: str
    stale: bool


class CancelOut(BaseModel):
    cancelled: bool


@router.post("/ai/bootstrap")
async def bootstrap(_: DeviceDep, session: SessionDep, rt: RuntimeDep) -> BootstrapOut:
    await agents.ensure_seeded(session, rt.registry, rt.clock.now())
    return BootstrapOut(
        agents=[AgentOut(**item) for item in await agents.list_agents(session)],
        tools=[spec.public() for spec in TOOLS.all()],
        seed_prompt_version=agents.SEED_PROMPT_VERSION,
    )


@router.post("/ai/agents/{seed_key}/reset")
async def reset_agent(
    seed_key: str, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> ChangesOut:
    registry: SyncRegistry = rt.registry
    changes = await agents.reset_agent(session, registry, rt.clock.now(), seed_key)
    return ChangesOut(changes=changes)


@router.get("/ai/models")
async def models(
    _: DeviceDep,
    ai: AiDep,
    refresh: bool = False,
    q: Annotated[str | None, Query(max_length=200)] = None,
    tools: bool = False,
) -> ModelsOut:
    try:
        catalog = await ai.catalog.get(refresh=refresh)
    except UpstreamError as error:
        status = 504 if error.code == "upstream_timeout" else 502
        raise ApiError(status, error.code, error.message) from error
    found: list[ModelInfo] = list(catalog.models.values())
    if q:
        needle = q.lower()
        found = [m for m in found if needle in m.id.lower() or needle in m.name.lower()]
    if tools:
        found = [m for m in found if m.supports_tools]
    return ModelsOut(
        models=[m.public() for m in found],
        fetched_at=catalog.fetched_at.isoformat().replace("+00:00", "Z"),
        stale=catalog.stale,
    )


@router.get("/ai/usage")
async def usage(
    _: DeviceDep, session: SessionDep, rt: RuntimeDep, month: str | None = None
) -> dict[str, object]:
    zone = ZoneInfo(rt.settings.ai_billing_timezone)
    chosen = spend.parse_month(month, zone) if month else spend.month_of(rt.clock.now(), zone)
    async with session.begin():
        return await spend.summary(session, chosen)


def sse_frame(event: str, data: dict[str, Any]) -> bytes:
    body = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {body}\n\n".encode()


async def event_stream(run: ChatRun, ping_seconds: float) -> AsyncIterator[bytes]:
    """Relay the run's events. Whatever ends this generator (client gone, error) cancels the run."""
    task = run.start()
    try:
        while True:
            try:
                item = await asyncio.wait_for(run.queue.get(), timeout=ping_seconds)
            except TimeoutError:
                yield sse_frame("ping", {})
                continue
            if item is None:
                return
            yield sse_frame(item.name, item.data)
    finally:
        if not task.done():
            task.cancel()


@router.post("/ai/chat/completions")
async def completions(
    body: ChatRequest, _: DeviceDep, rt: RuntimeDep, ai: AiDep
) -> StreamingResponse:
    chat = await prepare(rt, ai, body)
    run = ChatRun(rt, ai, chat)
    return StreamingResponse(
        event_stream(run, rt.settings.ai_sse_ping_seconds),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/ai/chat/{message_id}/cancel")
async def cancel(message_id: uuid.UUID, _: DeviceDep, ai: AiDep) -> CancelOut:
    run = ai.runs.get(message_id)
    return CancelOut(cancelled=run.cancel() if run is not None else False)
