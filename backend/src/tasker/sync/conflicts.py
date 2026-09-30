"""Conflict log: listing and "return mine" (``POST /sync/conflicts/{id}/revert``)."""

import uuid
from datetime import datetime
from typing import Any

import sqlalchemy as sa
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.clock import to_ms
from tasker.errors import ApiError
from tasker.hlc import HlcClock, parse_hlc
from tasker.ids import uuid7
from tasker.sync.engine import (
    DELETED,
    ParsedOp,
    Reject,
    SyncContext,
    apply_op,
    finish_writes,
    iso,
    lock_sync_state,
)
from tasker.sync.pull import serialize_change
from tasker.sync.registry import SyncRegistry
from tasker.tables import sync_conflicts

LIST_MAX = 200


def serialize_conflict(row: Any) -> dict[str, Any]:
    return {
        "id": str(row.id),
        "created_at": iso(row.created_at),
        "table": row.table_name,
        "row_id": str(row.row_id),
        "field": row.field,
        "kind": row.kind,
        "losing_value": row.losing_value,
        "winning_value": row.winning_value,
        "losing_device_id": None if row.losing_device_id is None else str(row.losing_device_id),
        "winning_device_id": None if row.winning_device_id is None else str(row.winning_device_id),
        "losing_hlc": row.losing_hlc,
        "winning_hlc": row.winning_hlc,
        "reverted_at": iso(row.reverted_at),
    }


async def list_conflicts(
    session: AsyncSession, *, reverted: str, limit: int, before: uuid.UUID | None
) -> dict[str, Any]:
    query = sa.select(sync_conflicts).order_by(sync_conflicts.c.id.desc()).limit(limit + 1)
    if reverted == "true":
        query = query.where(sync_conflicts.c.reverted_at.is_not(None))
    elif reverted == "false":
        query = query.where(sync_conflicts.c.reverted_at.is_(None))
    if before is not None:
        query = query.where(sync_conflicts.c.id < before)
    rows = list((await session.execute(query)).all())
    page = rows[:limit]
    return {
        "conflicts": [serialize_conflict(row) for row in page],
        "next_before": str(page[-1].id) if len(rows) > limit and page else None,
    }


def _fresh_hlc(row: dict[str, Any], device: uuid.UUID, now: datetime) -> str:
    """A label greater than every label already stored on the row."""
    labels = [entry["h"] for entry in row["field_meta"].values()] + [row["updated_at"]]
    newest = max(parse_hlc(label) for label in labels)
    return HlcClock(device, newest.ms, newest.counter).send(to_ms(now))


async def revert_conflict(
    session: AsyncSession,
    registry: SyncRegistry,
    device_id: uuid.UUID,
    conflict_id: uuid.UUID,
    now: datetime,
) -> dict[str, Any]:
    async with session.begin():
        head, _ = await lock_sync_state(session)
        found = (
            await session.execute(
                sa.select(sync_conflicts)
                .where(sync_conflicts.c.id == conflict_id)
                .with_for_update()
            )
        ).first()
        if found is None:
            raise ApiError(404, "conflict_not_found", "No such conflict")
        if found.reverted_at is not None:
            raise ApiError(409, "conflict_already_reverted", "This conflict was already reverted")
        spec = registry.get(found.table_name)
        if spec is None or found.kind == "parent_deleted":
            raise ApiError(409, "not_revertable", "This conflict cannot be reverted")
        ctx = SyncContext(session, registry, now, head, device_id)
        row = await _load(ctx, spec.table, found.row_id)
        if row is None:
            raise ApiError(409, "row_not_found", "The row no longer exists")

        values: dict[str, Any] = {}
        restore = False
        op_type = "upsert"
        if found.kind == "field":
            column = spec.by_name.get(found.field)
            if column is None:
                raise ApiError(409, "not_revertable", "The column no longer exists")
            try:
                values[found.field] = (
                    None
                    if found.losing_value is None and column.nullable
                    else column.adapter.validate_python(found.losing_value)
                )
            except (ValidationError, ValueError) as exc:
                raise ApiError(422, "revert_rejected", "The value is no longer valid") from exc
        elif found.kind == "resurrected":
            op_type = "delete"
        else:  # edit_vs_delete
            restore = True
        hlc = _fresh_hlc(row, device_id, now)
        op = ParsedOp(
            uuid7(), spec, found.row_id, op_type, values, None, restore,
            int(row["server_version"]), hlc, str(device_id), parse_hlc(hlc).ms,
        )  # fmt: skip
        try:
            async with session.begin_nested():
                await apply_op(ctx, op)
        except Reject as reject:
            raise ApiError(422, "revert_rejected", reject.message) from reject
        await session.execute(
            sa.update(sync_conflicts)
            .where(sync_conflicts.c.id == conflict_id)
            .values(reverted_at=now)
        )
        await finish_writes(ctx, head)
        updated = await _load(ctx, spec.table, found.row_id)
        conflict = (
            await session.execute(
                sa.select(sync_conflicts).where(sync_conflicts.c.id == conflict_id)
            )
        ).one()
        assert updated is not None  # noqa: S101 - the row was just read
        return {"conflict": serialize_conflict(conflict), "change": serialize_change(spec, updated)}


async def _load(ctx: SyncContext, table: sa.Table, row_id: uuid.UUID) -> dict[str, Any] | None:
    result = await ctx.session.execute(sa.select(table).where(table.c.id == row_id))
    row = result.mappings().first()
    return None if row is None else dict(row)


__all__ = ["DELETED", "list_conflicts", "revert_conflict", "serialize_conflict"]
