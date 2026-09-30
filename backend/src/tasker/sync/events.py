"""SSE stream: tells a device that another device committed changes."""

import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from typing import Any

import sqlalchemy as sa

from tasker.runtime import Runtime
from tasker.tables import devices, sync_state


def sse_frame(event: str, data: dict[str, Any]) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()


async def _head(rt: Runtime) -> int:
    async with rt.sessionmaker() as session:
        result = await session.execute(
            sa.select(sync_state.c.head_version).where(sync_state.c.id == 1)
        )
        return int(result.scalar_one())


async def _active(rt: Runtime, device_id: uuid.UUID) -> bool:
    async with rt.sessionmaker() as session:
        revoked = (
            await session.execute(sa.select(devices.c.revoked_at).where(devices.c.id == device_id))
        ).first()
        return revoked is not None and revoked.revoked_at is None


async def event_stream(rt: Runtime, device_id: uuid.UUID) -> AsyncIterator[bytes]:
    async with rt.hub.subscribe(device_id) as subscription:
        yield b"retry: 3000\n\n"
        yield sse_frame("hello", {"head_version": await _head(rt)})
        while not rt.hub.closed.is_set():
            try:
                await asyncio.wait_for(subscription.event.wait(), timeout=rt.sse_ping_seconds)
            except TimeoutError:
                if not await _active(rt, device_id):
                    yield sse_frame("revoked", {})
                    return
                yield sse_frame("ping", {})
                continue
            if rt.hub.closed.is_set():
                return
            subscription.event.clear()
            if not await _active(rt, device_id):
                yield sse_frame("revoked", {})
                return
            yield sse_frame("changes", {"head_version": await _head(rt)})
