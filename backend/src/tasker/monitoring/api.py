"""HTTP surface of Stage 9 (spec stage9_monitoring.md, section 8): the "Pulse" data for the client.

Read-mostly and authenticated like every other endpoint. Nothing here returns the Telegram token,
the chat id or an engine address.
"""

import json
import uuid
from typing import Annotated, Any

import sqlalchemy as sa
from fastapi import APIRouter, Depends, Query, Request, Response

from tasker.auth.deps import DeviceDep, RuntimeDep, require_schema_version
from tasker.calendar.timefmt import UTC_PATTERN, format_utc, parse_utc
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.monitoring import messages, service
from tasker.monitoring.runtime import MonitoringRuntime
from tasker.monitoring.storage import monitor_incidents, monitor_outbox
from tasker.monitoring.tables import monitor_services
from tasker.runtime import Runtime

router = APIRouter(tags=["monitoring"], dependencies=[Depends(require_schema_version)])


def _monitoring(request: Request) -> MonitoringRuntime:
    runtime: MonitoringRuntime = request.app.state.monitoring
    return runtime


async def _snapshot(session: SessionDep, request: Request, rt: Runtime) -> dict[str, Any]:
    mon = _monitoring(request)
    async with session.begin():
        return await service.pulse_snapshot(
            session, mon.settings, rt.clock, telegram_configured=mon.notifier.configured
        )


@router.get("/monitoring/pulse")
async def pulse(request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep) -> Response:
    """The whole dashboard in one answer. ``ETag`` is the same while nothing changed (a
    conditional request answers ``304``), so a client can keep the last snapshot for offline."""
    snapshot = await _snapshot(session, request, rt)
    etag = service.snapshot_etag(snapshot)
    headers = {"ETag": etag, "Cache-Control": "private, no-cache"}
    if service.etag_matches(request.headers.get("if-none-match"), etag):
        return Response(status_code=304, headers=headers)
    return Response(
        json.dumps(snapshot, ensure_ascii=False), media_type="application/json", headers=headers
    )


@router.post("/monitoring/refresh")
async def refresh(
    request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> dict[str, Any]:
    """The "Check now" button: read the engine right away (at most once per
    ``REFRESH_MIN_SECONDS``) and answer with the new snapshot. The engine keeps its own schedule:
    this refreshes what is known, it does not make the engine run checks out of turn."""
    mon = _monitoring(request)
    if mon.engine is None:
        raise ApiError(503, "monitoring_not_configured", "The check engine is not configured")
    async with session.begin():
        last = await service.get_meta(session, service.META_LAST_POLL)
    parsed = parse_utc(last) if last else None
    if parsed is None or (rt.clock.now() - parsed).total_seconds() >= service.REFRESH_MIN_SECONDS:
        await service.poll_cycle(rt.sessionmaker, mon.engine, mon.settings, rt.clock)
    return await _snapshot(session, request, rt)


@router.get("/monitoring/incidents")
async def incidents(
    _: DeviceDep,
    session: SessionDep,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    before: Annotated[str | None, Query(pattern=UTC_PATTERN)] = None,
    before_id: uuid.UUID | None = None,
    service_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    """Incidents, newest first. The next page is asked with ``next_before`` and ``next_before_id``
    (the pair is the cursor: several incidents can start in the same second)."""
    start = parse_utc(before) if before else None
    if before and start is None:
        raise ApiError(422, "validation_error", "before must be a real UTC moment")
    if before_id is not None and start is None:
        raise ApiError(422, "validation_error", "before_id needs before")
    i, s = monitor_incidents, monitor_services.table
    query = (
        sa.select(i, s.c.name.label("service_name"))
        .join(s, s.c.id == i.c.service_id, isouter=True)
        .order_by(i.c.started_at.desc(), i.c.id.desc())
        .limit(limit + 1)
    )
    if start is not None and before_id is not None:
        query = query.where(sa.tuple_(i.c.started_at, i.c.id) < sa.tuple_(start, before_id))
    elif start is not None:
        query = query.where(i.c.started_at < start)
    if service_id is not None:
        query = query.where(i.c.service_id == service_id)
    async with session.begin():
        rows = (await session.execute(query)).mappings().all()
    page = rows[:limit]

    def card(row: Any) -> dict[str, Any]:
        started, ended = row["started_at"], row["ended_at"]
        return {
            "id": str(row["id"]),
            "service_id": str(row["service_id"]),
            "service_name": row["service_name"],
            "started_at": format_utc(started),
            "ended_at": format_utc(ended) if ended is not None else None,
            "duration_seconds": int((ended - started).total_seconds())
            if ended is not None
            else None,
            "reason": row["reason"],
            "check_ids": row["check_ids"],
        }

    more = len(rows) > limit
    last = page[-1] if more and page else None
    return {
        "incidents": [card(r) for r in page],
        "next_before": format_utc(last["started_at"]) if last is not None else None,
        "next_before_id": str(last["id"]) if last is not None else None,
    }


@router.get("/monitoring/self-check")
async def self_check(
    request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> dict[str, Any]:
    """The state of the monitoring itself: the engine, the generated configuration (which checks
    were accepted and which refused, and why), the Telegram queue. Never a secret."""
    mon = _monitoring(request)
    now = rt.clock.now()
    out = monitor_outbox
    async with session.begin():
        last_poll = await service.get_meta(session, service.META_LAST_POLL)
        error = await service.get_meta(session, service.META_LAST_ERROR) or None
        config = await service.get_meta(session, service.META_CONFIG)
        sent_at = await service.get_meta(session, service.META_TG_SUCCESS)
        tg_error = await service.get_meta(session, service.META_TG_ERROR) or None
        queued = (
            await session.execute(
                sa.select(sa.func.count()).where(out.c.sent_at.is_(None), out.c.expires_at > now)
            )
        ).scalar_one()
    polled = parse_utc(last_poll) if last_poll else None
    report = json.loads(config) if config else {}
    return {
        "engine": {
            "configured": mon.engine is not None,
            "last_poll_at": last_poll,
            "lag_seconds": int((now - polled).total_seconds()) if polled is not None else None,
            "error": error,
        },
        "config": {
            "synced_at": report.get("synced_at"),
            "checks_active": len(report.get("active", [])),
            "checks_rejected": report.get("rejected", []),
        },
        "telegram": {
            "configured": mon.notifier.configured,
            "last_success_at": sent_at,
            "last_error": tg_error,
            "queued": queued,
        },
    }


@router.post("/monitoring/telegram/test")
async def telegram_test(
    request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> dict[str, Any]:
    """Send one test message (the "Self-check" button), at most once per
    ``TELEGRAM_TEST_MIN_SECONDS`` (too soon: ``rate_limited``, nothing is sent). The answer says
    whether it went through, with an error code, never the reason text of the provider."""
    now = rt.clock.now()
    async with session.begin():
        # the lock serialises two requests at once; the stamp is written before sending
        await session.execute(
            sa.select(sa.func.pg_advisory_xact_lock(service.TELEGRAM_TEST_LOCK_KEY))
        )
        last = await service.get_meta(session, service.META_TG_TEST)
        parsed = parse_utc(last) if last else None
        wait = service.TELEGRAM_TEST_MIN_SECONDS
        if parsed is not None and (now - parsed).total_seconds() < wait:
            return {"ok": False, "error": "rate_limited"}
        await service.set_meta(session, service.META_TG_TEST, format_utc(now))
    result = await _monitoring(request).notifier.send(messages.TEST_MESSAGE)
    return {"ok": result.ok, "error": result.error}
