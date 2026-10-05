"""The worker's and the API's logic of Stage 9: configuration of the engine, the polling cycle
(results -> state machine -> incidents -> outbox), the Telegram delivery and the Pulse numbers.
Spec: ``docs/specs/stage9_monitoring.md``. The pure rules live in ``alerts``, ``stats``,
``targets`` and ``messages``; this module is the glue to PostgreSQL.
"""

import asyncio
import hashlib
import json
import os
import uuid
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import sqlalchemy as sa
import structlog
from sqlalchemy.dialects.postgresql import UUID as PG_UUID
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tasker.calendar.ids import namespace
from tasker.calendar.timefmt import format_utc, parse_utc
from tasker.clock import Clock
from tasker.monitoring import alerts, messages, stats
from tasker.monitoring.config_gen import CheckSpec, ConfigResult, Resolver, build_config
from tasker.monitoring.engine import EngineClient, EngineError, EngineResult
from tasker.monitoring.storage import (
    monitor_incidents,
    monitor_outbox,
    monitor_results,
    monitor_rollups,
    monitor_state,
)
from tasker.monitoring.tables import monitor_checks, monitor_servers, monitor_services
from tasker.monitoring.telegram import MAX_RETRY_AFTER, MIN_RETRY_AFTER, Notifier, SendResult
from tasker.tables import app_meta

log = structlog.get_logger("monitoring")

LOCK_KEY = 90_009_001
TELEGRAM_TEST_LOCK_KEY = 90_009_002
RESULTS_KEPT = timedelta(hours=48)
ROLLUPS_KEPT = timedelta(days=180)
OUTBOX_KEPT = timedelta(days=30)
MESSAGE_LIFETIME = timedelta(hours=6)
ENGINE_STALE_SECONDS = 300
HEALTHY_POLL_SECONDS = 60
SPARK_POINTS = 30
MAX_ATTEMPTS = 20
PERMANENT_RETRY_SECONDS = 600
REFRESH_MIN_SECONDS = 5
TELEGRAM_TEST_MIN_SECONDS = 10
INSERT_CHUNK = 5000  # rows per INSERT: 5 columns each, far below PostgreSQL's 32 767 parameters
LEASE_SECONDS = 120  # how long a message being sent is invisible to another worker

META_LAST_POLL = "monitor.last_poll_at"
META_LAST_ERROR = "monitor.last_error"
META_CONFIG = "monitor.config"
META_ENGINE_ALERTED = "monitor.engine_alerted"
META_ENGINE_WAIT = "monitor.engine_wait_since"
META_TG_SUCCESS = "monitor.telegram.last_success_at"
META_TG_ERROR = "monitor.telegram.last_error"
META_TG_TEST = "monitor.telegram.last_test_at"


@dataclass(frozen=True, slots=True)
class MonitorSettings:
    """What the logic needs from ``Settings`` (no secrets)."""

    engine_url: str | None
    config_path: str | None
    dns_resolver: str
    timezone: str
    quiet_start: str | None
    quiet_end: str | None


@dataclass(slots=True)
class CycleReport:
    polled: bool = False
    skipped: bool = False
    error: str | None = None
    new_results: int = 0
    messages: int = 0
    events: dict[str, list[dict[str, Any]]] = field(default_factory=dict)


def _utc(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, UTC)


def incident_id(service_id: str, n: int) -> uuid.UUID:
    return uuid.uuid5(namespace("monitor_incidents"), f"{service_id}|{n}")


# ------------------------------------------------------------------ meta (app_meta)


async def get_meta(session: AsyncSession, key: str) -> str | None:
    found = await session.execute(sa.select(app_meta.c.value).where(app_meta.c.key == key))
    return found.scalar_one_or_none()


async def set_meta(session: AsyncSession, key: str, value: str) -> None:
    stmt = pg_insert(app_meta).values(key=key, value=value)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[app_meta.c.key], set_={"value": value, "updated_at": sa.func.now()}
        )
    )


# ------------------------------------------------------------------ the owner's data


@dataclass(frozen=True, slots=True)
class LiveCheck:
    spec: CheckSpec
    service_name: str
    server_name: str
    critical: bool
    check_name: str
    server_id: str


async def load_live_checks(session: AsyncSession) -> list[LiveCheck]:
    """Checks that are alive with a live service and a live server (the rest is in the trash)."""
    c, s, v = monitor_checks.table, monitor_services.table, monitor_servers.table
    query = (
        sa.select(
            c,
            s.c.name.label("service_name"),
            s.c.critical,
            s.c.server_id,
            v.c.name.label("server_name"),
        )
        .join(s, s.c.id == c.c.service_id)
        .join(v, v.c.id == s.c.server_id)
        .where(c.c.deleted_at.is_(None), s.c.deleted_at.is_(None), v.c.deleted_at.is_(None))
        .order_by(c.c.id)
    )
    rows = (await session.execute(query)).mappings().all()
    return [
        LiveCheck(
            CheckSpec(
                id=str(r["id"]),
                service_id=str(r["service_id"]),
                kind=r["kind"],
                interval_seconds=r["interval_seconds"],
                timeout_seconds=r["timeout_seconds"],
                url=r["url"],
                host=r["host"],
                port=r["port"],
                dns_record_type=r["dns_record_type"],
                expected_status=r["expected_status"],
                expected_value=r["expected_value"],
                keyword=r["keyword"],
                ssl_min_days=r["ssl_min_days"],
            ),
            r["service_name"],
            r["server_name"],
            bool(r["critical"]),
            r["name"],
            str(r["server_id"]),
        )
        for r in rows
    ]


# ------------------------------------------------------------------ engine configuration


def _write_atomic(path: Path, text: str) -> bool:
    """Write ``text`` unless the file already has it; returns whether it was written."""
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)
    return True


async def sync_config(
    sessionmaker: async_sessionmaker[AsyncSession],
    cfg: MonitorSettings,
    clock: Clock,
    resolve: Resolver,
) -> ConfigResult | None:
    """Regenerate the engine file from the owner's data; ``None`` when no path is configured."""
    if not cfg.config_path:
        return None
    async with sessionmaker() as session, session.begin():
        live = await load_live_checks(session)
    result = await build_config([x.spec for x in live], resolve, cfg.dns_resolver)
    written = await asyncio.to_thread(_write_atomic, Path(cfg.config_path), result.text)
    report = {
        "synced_at": format_utc(clock.now()),
        "hash": result.digest,
        "active": result.active,
        "rejected": result.rejected,
    }
    async with sessionmaker() as session, session.begin():
        await set_meta(session, META_CONFIG, json.dumps(report))
    if written:
        log.info("monitor_config_written", checks=len(result.active), rejected=len(result.rejected))
    for item in result.rejected:
        log.warning("monitor_check_rejected", check_id=item["check_id"], reason=item["reason"])
    return result


# ------------------------------------------------------------------ the polling cycle


def _names(live: Sequence[LiveCheck]) -> dict[str, messages.ServiceInfo]:
    grouped: dict[str, dict[str, str]] = {}
    infos: dict[str, tuple[str, str]] = {}
    for item in live:
        sid = item.spec.service_id
        infos[sid] = (item.service_name, item.server_name)
        grouped.setdefault(sid, {})[item.spec.id] = item.check_name
    return {sid: messages.ServiceInfo(n, srv, grouped[sid]) for sid, (n, srv) in infos.items()}


async def _ingest(
    session: AsyncSession, results: Sequence[EngineResult], known: set[uuid.UUID]
) -> list[EngineResult]:
    """Store the results not seen yet (per check: newer than what is stored) and fold them into
    the hourly rollups; returns exactly the stored ones, oldest first."""
    mine = [r for r in results if r.check_id in known]
    if not mine:
        return []
    newest = await session.execute(
        sa.select(monitor_results.c.check_id, sa.func.max(monitor_results.c.at)).group_by(
            monitor_results.c.check_id
        )
    )
    latest: dict[uuid.UUID, datetime] = {row[0]: row[1] for row in newest}
    fresh = sorted(
        (r for r in mine if r.check_id not in latest or r.at > latest[r.check_id]),
        key=lambda r: (r.at, str(r.check_id)),
    )
    if not fresh:
        return []
    kept: set[tuple[uuid.UUID, datetime]] = set()
    for start in range(0, len(fresh), INSERT_CHUNK):
        stored = await session.execute(
            pg_insert(monitor_results)
            .values(
                [
                    {
                        "check_id": r.check_id,
                        "at": r.at,
                        "ok": r.ok,
                        "duration_ms": r.duration_ms,
                        "error": r.error,
                    }
                    for r in fresh[start : start + INSERT_CHUNK]
                ]
            )
            .on_conflict_do_nothing()
            .returning(monitor_results.c.check_id, monitor_results.c.at)
        )
        kept.update((cid, at) for cid, at in stored)
    inserted = [r for r in fresh if (r.check_id, r.at) in kept]
    buckets: dict[tuple[uuid.UUID, datetime], list[int]] = {}
    for r in inserted:
        hour = _utc(stats.hour_floor(int(r.at.timestamp())))
        bucket = buckets.setdefault((r.check_id, hour), [0, 0, 0, 0])
        bucket[0] += 1
        bucket[1] += 1 if r.ok else 0
        if r.ok and r.duration_ms is not None:
            bucket[2] += r.duration_ms
            bucket[3] += 1
    for (check_id, hour), (total, ok, ms_sum, ms_count) in buckets.items():
        stmt = pg_insert(monitor_rollups).values(
            check_id=check_id, hour_start=hour, total=total, ok=ok, ms_sum=ms_sum, ms_count=ms_count
        )
        await session.execute(
            stmt.on_conflict_do_update(
                index_elements=["check_id", "hour_start"],
                set_={
                    "total": monitor_rollups.c.total + stmt.excluded.total,
                    "ok": monitor_rollups.c.ok + stmt.excluded.ok,
                    "ms_sum": monitor_rollups.c.ms_sum + stmt.excluded.ms_sum,
                    "ms_count": monitor_rollups.c.ms_count + stmt.excluded.ms_count,
                },
            )
        )
    return inserted


def _queue(kind: str, key: str, text: str, now: datetime) -> dict[str, Any]:
    return {
        "dedup_key": key[:500],
        "kind": kind,
        "text": text,
        "created_at": now,
        "expires_at": now + MESSAGE_LIFETIME,
        "next_attempt_at": now,
    }


async def _watch_engine(
    session: AsyncSession, now: datetime, active_checks: int, queued: list[dict[str, Any]]
) -> None:
    """Silence is not health: when no check produced a result for ``ENGINE_STALE_SECONDS`` the
    engine is considered gone, one message says so, and one more when it is back."""
    stamp = format_utc(now)
    if active_checks == 0:
        # nobody is waiting for the engine: the clock of the next wait starts afresh
        await set_meta(session, META_ENGINE_WAIT, stamp)
        stale = False
    else:
        waiting = await get_meta(session, META_ENGINE_WAIT)
        since = parse_utc(waiting) if waiting else None
        if since is None:  # (a check the owner has just added must not look like a dead engine)
            since = now
            await set_meta(session, META_ENGINE_WAIT, stamp)
        newest = (await session.execute(sa.select(sa.func.max(monitor_results.c.at)))).scalar()
        reference = max(newest, since) if newest is not None else since
        stale = (now - reference).total_seconds() > ENGINE_STALE_SECONDS
    alerted = await get_meta(session, META_ENGINE_ALERTED) == "1"
    if stale and not alerted:
        queued.append(_queue("engine_down", f"engine_down:{stamp}", messages.ENGINE_DOWN, now))
        await set_meta(session, META_ENGINE_ALERTED, "1")
    elif not stale and alerted:
        if active_checks > 0:  # with no checks nothing has come back: no "restored" message
            queued.append(_queue("engine_up", f"engine_up:{stamp}", messages.ENGINE_UP, now))
        await set_meta(session, META_ENGINE_ALERTED, "0")


async def poll_cycle(
    sessionmaker: async_sessionmaker[AsyncSession],
    engine: EngineClient,
    cfg: MonitorSettings,
    clock: Clock,
    policy: alerts.Policy | None = None,
) -> CycleReport:
    """One pass: read the engine, store new results, advance every service's alert state, write
    incidents and queue the messages — all in ONE transaction, so a crash never half-applies a
    cycle. Two passes at once (worker and "Check now") are serialised by an advisory lock."""
    policy = policy or alerts.Policy()
    report = CycleReport()
    results: list[EngineResult] = []
    try:
        results = await engine.fetch()
        report.polled = True
    except EngineError as exc:
        report.error = exc.code
        log.warning("monitor_engine_failed", code=exc.code)
    now = clock.now()
    now_ts = int(now.timestamp())
    zone = ZoneInfo(cfg.timezone)
    async with sessionmaker() as session, session.begin():
        locked = (
            await session.execute(sa.select(sa.func.pg_try_advisory_xact_lock(LOCK_KEY)))
        ).scalar()
        if not locked:
            report.skipped = True
            return report
        live = await load_live_checks(session)
        by_check = {uuid.UUID(x.spec.id): x for x in live}
        inserted = await _ingest(session, results, set(by_check))
        report.new_results = len(inserted)
        observations: dict[str, list[dict[str, Any]]] = {}
        for r in inserted:
            service = by_check[r.check_id].spec.service_id
            observations.setdefault(service, []).append(
                {
                    "check": str(r.check_id),
                    "at": int(r.at.timestamp()),
                    "ok": r.ok,
                    "reason": r.error,
                }
            )
        services: dict[str, dict[str, Any]] = {}
        for x in live:
            entry = services.setdefault(x.spec.service_id, {"critical": x.critical, "checks": []})
            entry["checks"].append(x.spec.id)
        stored = {
            str(sid): state
            for sid, state in (
                await session.execute(sa.select(monitor_state.c.service_id, monitor_state.c.state))
            )
        }
        await _seed_incident_numbers(session, stored, services)
        quiet = alerts.is_quiet(now_ts, cfg.timezone, cfg.quiet_start, cfg.quiet_end)
        new_states, events, composed = alerts.run_cycle(
            stored, services, observations, now_ts, quiet, policy
        )
        report.events = events
        for sid, state in new_states.items():
            stmt = pg_insert(monitor_state).values(
                service_id=uuid.UUID(sid), state=state, updated_at=now
            )
            await session.execute(
                stmt.on_conflict_do_update(
                    index_elements=["service_id"], set_={"state": state, "updated_at": now}
                )
            )
        gone = [uuid.UUID(sid) for sid in stored if sid not in new_states]
        if gone:
            await session.execute(
                sa.delete(monitor_state).where(monitor_state.c.service_id.in_(gone))
            )
        await _close_orphan_incidents(session, [uuid.UUID(sid) for sid in services], now)
        await _write_incidents(session, events)
        names = _names(live)
        queued = [
            _queue(
                m["kind"],
                f"{m['kind']}:{','.join(m['refs'])}",
                messages.render(m, names, zone, now_ts),
                now,
            )
            for m in composed
        ]
        await _watch_engine(session, now, len(live), queued)
        if queued:
            await session.execute(
                pg_insert(monitor_outbox)
                .values(queued)
                .on_conflict_do_nothing(index_elements=["dedup_key"])
            )
        report.messages = len(queued)
        if report.polled:
            await set_meta(session, META_LAST_POLL, format_utc(now))
        await set_meta(session, META_LAST_ERROR, report.error or "")
    return report


async def _seed_incident_numbers(
    session: AsyncSession, stored: dict[str, Any], services: Mapping[str, Any]
) -> None:
    """A service without a stored state (new, or its state was erased while it had no live
    checks) continues the numbering of its incident journal: ``n`` is never reused, so the
    ``dedup_key`` of its alerts and the id of its incident are always new."""
    fresh = [uuid.UUID(sid) for sid in services if sid not in stored]
    if not fresh:
        return
    found = await session.execute(
        sa.select(monitor_incidents.c.service_id, sa.func.max(monitor_incidents.c.n))
        .where(monitor_incidents.c.service_id.in_(fresh))
        .group_by(monitor_incidents.c.service_id)
    )
    for sid, last in found:
        stored[str(sid)] = {**alerts.new_state(), "seq": int(last)}


async def _close_orphan_incidents(
    session: AsyncSession, live_services: Sequence[uuid.UUID], now: datetime
) -> None:
    """An incident of a service that is no longer live (trashed, or without live checks) cannot
    end by itself: it ends when the service leaves the picture."""
    stmt = sa.update(monitor_incidents).where(monitor_incidents.c.ended_at.is_(None))
    if live_services:
        stmt = stmt.where(monitor_incidents.c.service_id.not_in(live_services))
    await session.execute(stmt.values(ended_at=now))


async def _write_incidents(
    session: AsyncSession, events: Mapping[str, Sequence[Mapping[str, Any]]]
) -> None:
    for sid, items in events.items():
        for event in items:
            if event["type"] == "opened":
                reasons = event["reasons"]
                first = next((str(v) for v in reasons.values() if v), None)
                await session.execute(
                    pg_insert(monitor_incidents)
                    .values(
                        id=incident_id(sid, event["n"]),
                        service_id=uuid.UUID(sid),
                        n=event["n"],
                        started_at=_utc(event["started_at"]),
                        reason=messages.short_reason(first) if first else None,
                        check_ids=sorted(reasons),
                    )
                    .on_conflict_do_nothing()
                )
            elif event["type"] == "closed":
                await session.execute(
                    sa.update(monitor_incidents)
                    .where(monitor_incidents.c.id == incident_id(sid, event["n"]))
                    .values(ended_at=_utc(event["ended_at"]))
                )


# ------------------------------------------------------------------ Telegram delivery


def clamp_retry_after(value: int | None) -> int:
    """Seconds to wait after a 429: 30 when Telegram named none, else within 1..3600."""
    if value is None:
        return 30
    return min(max(value, MIN_RETRY_AFTER), MAX_RETRY_AFTER)


@dataclass(slots=True)
class DeliveryReport:
    sent: int = 0
    failed: int = 0
    error: str | None = None


async def deliver_outbox(
    sessionmaker: async_sessionmaker[AsyncSession],
    notifier: Notifier,
    clock: Clock,
    *,
    batch: int = 20,
    pause: float = 1.0,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> DeliveryReport:
    """Send what is due, oldest first, about one message per second. A 429 postpones by its
    ``retry_after``; a network or server error backs off; a rejection that will not change
    (wrong token, wrong chat) is retried every ten minutes so a fixed ``.env`` heals itself.
    Nothing here ever puts the token or the chat id into a log line."""
    report = DeliveryReport()
    if not notifier.configured:
        report.error = "not_configured"
        async with sessionmaker() as session, session.begin():
            await set_meta(session, META_TG_ERROR, "not_configured")
        return report
    out = monitor_outbox
    for turn in range(batch):
        now = clock.now()
        async with sessionmaker() as session, session.begin():
            row = (
                await session.execute(
                    sa.select(out.c.id, out.c.text, out.c.attempts)
                    .where(
                        out.c.sent_at.is_(None),
                        out.c.next_attempt_at <= now,
                        out.c.expires_at > now,
                        out.c.attempts < MAX_ATTEMPTS,
                    )
                    .order_by(out.c.id)
                    .limit(1)
                    .with_for_update(skip_locked=True)
                )
            ).first()
            if row is not None:
                # a lease: another worker will not pick the message up while it is being sent
                await session.execute(
                    sa.update(out)
                    .where(out.c.id == row.id)
                    .values(next_attempt_at=now + timedelta(seconds=LEASE_SECONDS))
                )
        if row is None:
            break
        outcome: SendResult = await notifier.send(row.text)
        async with sessionmaker() as session, session.begin():
            if outcome.ok:
                await session.execute(
                    sa.update(out).where(out.c.id == row.id).values(sent_at=now, last_error=None)
                )
                await set_meta(session, META_TG_SUCCESS, format_utc(now))
                await set_meta(session, META_TG_ERROR, "")
                report.sent += 1
            else:
                attempts = row.attempts + (0 if outcome.error == "rate_limited" else 1)
                if outcome.error == "rate_limited":
                    wait = clamp_retry_after(outcome.retry_after)
                elif outcome.permanent:
                    wait = PERMANENT_RETRY_SECONDS
                else:
                    wait = min(300, 5 * 2**attempts)
                await session.execute(
                    sa.update(out)
                    .where(out.c.id == row.id)
                    .values(
                        attempts=attempts,
                        next_attempt_at=now + timedelta(seconds=wait),
                        last_error=outcome.error,
                    )
                )
                if outcome.error == "rate_limited":
                    # the limit is the chat's, not the message's: everything waits
                    await session.execute(
                        sa.update(out)
                        .where(
                            out.c.sent_at.is_(None),
                            out.c.next_attempt_at < now + timedelta(seconds=wait),
                        )
                        .values(next_attempt_at=now + timedelta(seconds=wait))
                    )
                await set_meta(session, META_TG_ERROR, outcome.error or "unknown")
                report.failed += 1
                report.error = outcome.error
        if not outcome.ok:
            log.warning("telegram_send_failed", code=outcome.error)
            break
        if turn + 1 < batch:
            await sleep(pause)
    return report


# ------------------------------------------------------------------ housekeeping


async def cleanup(sessionmaker: async_sessionmaker[AsyncSession], clock: Clock) -> None:
    now = clock.now()
    async with sessionmaker() as session, session.begin():
        await session.execute(
            sa.delete(monitor_results).where(monitor_results.c.at < now - RESULTS_KEPT)
        )
        await session.execute(
            sa.delete(monitor_rollups).where(monitor_rollups.c.hour_start < now - ROLLUPS_KEPT)
        )
        await session.execute(
            sa.delete(monitor_outbox).where(monitor_outbox.c.created_at < now - OUTBOX_KEPT)
        )


# ------------------------------------------------------------------ the Pulse snapshot

STATUS_ORDER = {alerts.DOWN: 0, alerts.UNKNOWN: 1, alerts.UP: 2}


def _iso(moment: datetime | None) -> str | None:
    return format_utc(moment) if moment is not None else None


async def pulse_snapshot(
    session: AsyncSession, cfg: MonitorSettings, clock: Clock, *, telegram_configured: bool
) -> dict[str, Any]:
    now = clock.now()
    now_ts = int(now.timestamp())
    live = await load_live_checks(session)
    ids = [uuid.UUID(x.spec.id) for x in live]
    states = {
        str(sid): state
        for sid, state in (
            await session.execute(sa.select(monitor_state.c.service_id, monitor_state.c.state))
        )
    }
    buckets: dict[str, list[dict[str, int]]] = {}
    if ids:
        rows = await session.execute(
            sa.select(
                monitor_rollups.c.check_id,
                monitor_rollups.c.hour_start,
                monitor_rollups.c.total,
                monitor_rollups.c.ok,
            ).where(
                monitor_rollups.c.check_id.in_(ids),
                monitor_rollups.c.hour_start
                >= _utc(stats.hour_floor(now_ts) - 29 * 24 * 3600 - 23 * 3600),
            )
        )
        for check_id, hour_start, total, ok in rows:
            buckets.setdefault(str(check_id), []).append(
                {"hour": int(hour_start.timestamp()), "total": total, "ok": ok}
            )
    recent: dict[str, list[Any]] = {}
    if ids:
        # the last SPARK_POINTS results of every check: one index range scan per check
        wanted = sa.values(sa.column("check_id", PG_UUID(as_uuid=True)), name="wanted").data(
            [(i,) for i in ids]
        )
        newest = (
            sa.select(monitor_results.c.at, monitor_results.c.ok, monitor_results.c.duration_ms)
            .where(monitor_results.c.check_id == wanted.c.check_id)
            .order_by(monitor_results.c.at.desc())
            .limit(SPARK_POINTS)
            .lateral("newest")
        )
        for r in (
            await session.execute(
                sa.select(wanted.c.check_id, newest.c.at, newest.c.ok, newest.c.duration_ms)
                .select_from(wanted.join(newest, sa.true()))
                .order_by(wanted.c.check_id, newest.c.at)
            )
        ).mappings():
            recent.setdefault(str(r["check_id"]), []).append(r)
    open_incidents = {
        str(r["service_id"]): r
        for r in (
            await session.execute(
                sa.select(monitor_incidents).where(monitor_incidents.c.ended_at.is_(None))
            )
        ).mappings()
    }

    def availability(rows: Sequence[Mapping[str, int]]) -> dict[str, int | None]:
        return {
            name: stats.availability_bp(rows, now_ts, hours)
            for name, hours in stats.WINDOW_HOURS.items()
        }

    report = await get_meta(session, META_CONFIG)
    refused: dict[str, str] = {}
    if report:
        for item in json.loads(report).get("rejected", []):
            refused[str(item["check_id"])] = str(item["reason"])
    by_service: dict[str, list[LiveCheck]] = {}
    for item in live:
        by_service.setdefault(item.spec.service_id, []).append(item)
    services = []
    for sid, items in by_service.items():
        state = states.get(sid) or alerts.new_state()
        check_cards = []
        service_buckets: list[dict[str, int]] = []
        responses: list[int] = []
        for item in items:
            cid = item.spec.id
            series = recent.get(cid, [])
            last = series[-1] if series else None
            response = last["duration_ms"] if last is not None and last["ok"] else None
            if response is not None:
                responses.append(response)
            service_buckets.extend(buckets.get(cid, []))
            check_cards.append(
                {
                    "id": cid,
                    "kind": item.spec.kind,
                    "name": item.check_name,
                    "status": state["checks"].get(cid, {}).get("status", alerts.UNKNOWN),
                    "problem": refused.get(cid),
                    "last_at": _iso(last["at"]) if last is not None else None,
                    "response_ms": response,
                    "availability": availability(buckets.get(cid, [])),
                    "spark": [(r["duration_ms"] or 0) if r["ok"] else -1 for r in series],
                }
            )
        incident = open_incidents.get(sid)
        services.append(
            {
                "id": sid,
                "server_id": items[0].server_id,
                "name": items[0].service_name,
                "server": items[0].server_name,
                "critical": items[0].critical,
                "status": state["status"],
                "down_since": _iso(incident["started_at"]) if incident is not None else None,
                "availability": availability(service_buckets),
                "response_ms": stats.mean_ms(sum(responses), len(responses)),
                "open_incident": str(incident["id"]) if incident is not None else None,
                "checks": sorted(check_cards, key=lambda c: (c["name"].casefold(), c["id"])),
            }
        )
    services.sort(key=lambda s: (STATUS_ORDER[s["status"]], s["name"].casefold(), s["id"]))
    counts = {
        k: sum(1 for s in services if s["status"] == k)
        for k in (alerts.DOWN, alerts.UP, alerts.UNKNOWN)
    }
    last_poll = await get_meta(session, META_LAST_POLL)
    last_error = await get_meta(session, META_LAST_ERROR) or None
    polled = datetime.fromisoformat(last_poll.replace("Z", "+00:00")) if last_poll else None
    healthy = (
        polled is not None
        and last_error is None
        and (now - polled).total_seconds() <= HEALTHY_POLL_SECONDS
    )
    return {
        "generated_at": format_utc(now),
        "engine": {
            "configured": cfg.engine_url is not None,
            "last_poll_at": last_poll,
            "healthy": healthy,
            "error": last_error,
            "telegram_configured": telegram_configured,
        },
        "summary": {"services": len(services), **counts},
        "services": services,
    }


def snapshot_etag(snapshot: Mapping[str, Any]) -> str:
    """Same data -> same tag: the moments of the poll (``generated_at``, ``engine.last_poll_at``)
    change every few seconds without the picture changing, so they are not part of it."""
    stable = {k: v for k, v in snapshot.items() if k != "generated_at"}
    engine = stable.get("engine")
    if isinstance(engine, dict):
        stable["engine"] = {k: v for k, v in engine.items() if k != "last_poll_at"}
    digest = hashlib.sha256(
        json.dumps(stable, sort_keys=True, ensure_ascii=False).encode()
    ).hexdigest()
    return f'"{digest[:32]}"'


def etag_matches(header: str | None, etag: str) -> bool:
    """``If-None-Match``: a list of tags (weak ones, ``W/"…"``, count too) or ``*``."""
    if not header:
        return False
    for item in header.split(","):
        candidate = item.strip()
        if candidate == "*" or candidate.removeprefix("W/") == etag:
            return True
    return False
