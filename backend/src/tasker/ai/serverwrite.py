"""Server-authored synchronised rows: the server pushes as the virtual ``SERVER_DEVICE_ID``.

A write goes through ``apply_push`` (validation, merge, versions, journal, ``NOTIFY``), exactly
like a client's push, so these rows reach every device through the ordinary ``pull``.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.ai.ids import SERVER_DEVICE_ID
from tasker.clock import to_ms
from tasker.hlc import HlcClock, parse_hlc
from tasker.ids import uuid7
from tasker.sync import engine
from tasker.sync.pull import serialize_change
from tasker.sync.registry import SyncRegistry, SyncTableSpec


class ServerWriteError(Exception):
    """The sync engine refused a server-made operation (a bug or a conflicting invariant)."""

    def __init__(self, table: str, code: str, message: str) -> None:
        super().__init__(f"{table}: {code}: {message}")
        self.table = table
        self.code = code


@dataclass(slots=True)
class WriteOp:
    spec: SyncTableSpec
    row_id: uuid.UUID
    fields: dict[str, Any]
    created: bool = True
    # For updates of an existing row: its current server_version (so nothing is "concurrent").
    base_version: int = 0
    # An update must carry a clock greater than everything stored on the row.
    after_hlc: str | None = None
    created_at: datetime | None = None


def _iso(moment: datetime) -> str:
    return engine.iso(moment) or ""


async def row_clock(
    session: AsyncSession, spec: SyncTableSpec, row_id: uuid.UUID
) -> tuple[int, str] | None:
    """``(server_version, newest clock label)`` of a stored row, or ``None`` if it is absent."""
    row = (
        await session.execute(
            sa.select(
                spec.table.c.server_version, spec.table.c.updated_at, spec.table.c.field_meta
            ).where(spec.table.c.id == row_id)
        )
    ).first()
    if row is None:
        return None
    labels = [entry["h"] for entry in row.field_meta.values()] + [row.updated_at]
    return int(row.server_version), str(max(labels))


def make_raw_ops(ops: list[WriteOp], now: datetime) -> list[dict[str, Any]]:
    clock = HlcClock(SERVER_DEVICE_ID)
    raw: list[dict[str, Any]] = []
    for item in ops:
        if item.after_hlc is not None:
            newest = parse_hlc(item.after_hlc)
            clock.last_ms, clock.counter = max(
                (clock.last_ms, clock.counter), (newest.ms, newest.counter)
            )
        fields = dict(item.fields)
        if item.created:
            fields["created_at"] = _iso(item.created_at or now)
        raw.append(
            {
                "op_id": str(uuid7()),
                "table": item.spec.name,
                "id": str(item.row_id),
                "type": "upsert",
                "fields": fields,
                "base_version": item.base_version,
                "hlc": clock.send(to_ms(now)),
            }
        )
    return raw


async def write_rows(
    session: AsyncSession, registry: SyncRegistry, ops: list[WriteOp], now: datetime
) -> None:
    """Apply ``ops`` as one transaction; any refusal rolls everything back."""
    raw = make_raw_ops(ops, now)
    async with session.begin():
        head, _ = await engine.lock_sync_state(session)
        ctx = engine.SyncContext(session, registry, now, head, SERVER_DEVICE_ID)
        for item, body in zip(ops, raw, strict=True):
            try:
                parsed = engine.parse_op(registry, SERVER_DEVICE_ID, body, now)
                async with session.begin_nested():
                    await engine.apply_op(ctx, parsed)
            except engine.Reject as reject:
                raise ServerWriteError(item.spec.name, reject.code, reject.message) from reject
        await engine.finish_writes(ctx, head)


async def load_changes(
    session: AsyncSession, spec_ids: list[tuple[SyncTableSpec, uuid.UUID]]
) -> list[dict[str, Any]]:
    """The rows as ``pull`` serialises them (for responses that hand rows to the client)."""
    changes: list[dict[str, Any]] = []
    for spec, row_id in spec_ids:
        row = (
            (await session.execute(sa.select(spec.table).where(spec.table.c.id == row_id)))
            .mappings()
            .first()
        )
        if row is not None:
            changes.append(serialize_change(spec, row))
    return changes
