"""Physical removal of old tombstones and other housekeeping (worker job)."""

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tasker.sync.engine import lock_sync_state
from tasker.sync.registry import SyncRegistry
from tasker.tables import devices, login_failures, sync_conflicts, sync_ops, sync_state

TRASH_DAYS = 30
INACTIVE_DEVICE_DAYS = 30
JOURNAL_DAYS = 60
CONFLICT_DAYS = 180


# Called after the commit with (table name, ids of the rows that were physically removed): the
# place where a module cleans up what lives outside the database (files of attachments).
PurgeHook = Callable[[str, list[uuid.UUID]], Awaitable[None]]


async def purge_tombstones(
    sessionmaker: async_sessionmaker[AsyncSession],
    registry: SyncRegistry,
    now: datetime,
    on_purged: PurgeHook | None = None,
) -> int:
    """Delete tombstones older than 30 days that every active device has already pulled."""
    cutoff = now - timedelta(days=TRASH_DAYS)
    purged = 0
    removed: dict[str, list[uuid.UUID]] = {}
    async with sessionmaker() as session, session.begin():
        await lock_sync_state(session)
        cursor_row = (
            await session.execute(
                sa.select(sa.func.min(devices.c.last_pulled_version), sa.func.count()).where(
                    devices.c.revoked_at.is_(None),
                    devices.c.last_seen_at >= now - timedelta(days=INACTIVE_DEVICE_DAYS),
                )
            )
        ).one()
        min_cursor = None if cursor_row[1] == 0 else int(cursor_row[0])
        watermark = 0
        for spec in registry.purge_order():
            table = spec.table
            conditions = [table.c.deleted_at.is_not(None), table.c.deleted_at < cutoff]
            if min_cursor is not None:
                conditions.append(table.c.server_version <= min_cursor)
            for child, column in registry.children_of(spec.name):
                conditions.append(~sa.exists().where(child.table.c[column.name] == table.c.id))
            result = await session.execute(
                sa.delete(table).where(*conditions).returning(table.c.server_version, table.c.id)
            )
            rows = result.all()
            versions: list[int] = [int(row[0]) for row in rows]
            purged += len(versions)
            watermark = max([watermark, *versions])
            if rows:
                removed[spec.name] = [row[1] for row in rows]
        if watermark:
            await session.execute(
                sa.update(sync_state)
                .where(sync_state.c.id == 1)
                .values(purge_watermark=sa.func.greatest(sync_state.c.purge_watermark, watermark))
            )
    if on_purged is not None:
        for name, ids in removed.items():
            await on_purged(name, ids)
    return purged


async def cleanup_records(sessionmaker: async_sessionmaker[AsyncSession], now: datetime) -> None:
    """Trim the processed-op journal, the conflict log and stale login counters."""
    async with sessionmaker() as session, session.begin():
        await session.execute(
            sa.delete(sync_ops).where(sync_ops.c.created_at < now - timedelta(days=JOURNAL_DAYS))
        )
        await session.execute(
            sa.delete(sync_conflicts).where(
                sync_conflicts.c.created_at < now - timedelta(days=CONFLICT_DAYS)
            )
        )
        await session.execute(
            sa.delete(login_failures).where(
                login_failures.c.last_failure_at < now - timedelta(days=1),
                sa.or_(
                    login_failures.c.locked_until.is_(None), login_failures.c.locked_until < now
                ),
            )
        )
