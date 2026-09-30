"""``GET /sync/pull``: ordered changes after a cursor, as one consistent snapshot."""

import uuid
from datetime import datetime
from typing import Any

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.errors import ApiError
from tasker.sync.engine import dump_value, iso
from tasker.sync.registry import SyncRegistry, SyncTableSpec
from tasker.tables import devices, sync_state

PULL_MAX = 1000
PULL_DEFAULT = 500


def serialize_row(spec: SyncTableSpec, row: Any) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(row["id"]),
        "created_at": iso(row["created_at"]),
        "updated_at": row["updated_at"],
        "deleted_at": iso(row["deleted_at"]),
        "server_version": int(row["server_version"]),
        "origin_device_id": str(row["origin_device_id"]),
    }
    for column in spec.columns:
        out[column.name] = dump_value(spec, column.name, row[column.name])
    return out


def serialize_change(spec: SyncTableSpec, row: Any) -> dict[str, Any]:
    return {
        "table": spec.name,
        "id": str(row["id"]),
        "server_version": int(row["server_version"]),
        "row": serialize_row(spec, row),
    }


async def pull_changes(
    session: AsyncSession,
    registry: SyncRegistry,
    device_id: uuid.UUID,
    *,
    since: int,
    limit: int,
    now: datetime,
) -> dict[str, Any]:
    await session.connection(execution_options={"isolation_level": "REPEATABLE READ"})
    state = (
        await session.execute(
            sa.select(sync_state.c.head_version, sync_state.c.purge_watermark).where(
                sync_state.c.id == 1
            )
        )
    ).one()
    head, watermark = int(state.head_version), int(state.purge_watermark)
    if 0 < since < watermark:
        await session.rollback()
        raise ApiError(
            410,
            "resync_required",
            "The device is behind purged data; perform a full resync",
            details={"purge_watermark": watermark},
        )
    found: list[tuple[int, SyncTableSpec, Any]] = []
    for spec in registry.tables():
        table = spec.table
        rows = await session.execute(
            sa.select(table)
            .where(table.c.server_version > since, table.c.server_version <= head)
            .order_by(table.c.server_version)
            .limit(limit + 1)
        )
        found.extend((row["server_version"], spec, row) for row in rows.mappings())
    found.sort(key=lambda item: item[0])
    has_more = len(found) > limit
    page = found[:limit]
    changes = [serialize_change(spec, row) for _, spec, row in page]
    next_since = int(page[-1][0]) if has_more else head
    await session.rollback()  # end the read-only snapshot

    async with session.begin():
        await session.execute(
            sa.update(devices)
            .where(devices.c.id == device_id)
            .values(last_pulled_version=since, last_seen_at=now)
        )
    return {
        "changes": changes,
        "next_since": next_since,
        "has_more": has_more,
        "head_version": head,
        "purge_watermark": watermark,
        "server_time": iso(now),
    }
