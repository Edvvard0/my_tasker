"""Server side of ``POST /sync/push``: validation, field-level merge, LWW, conflict log.

The rules are specified in ``docs/specs/stage1_sync_and_auth.md`` (sections 3.2-3.5).
"""

import copy
import json
import uuid
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

import sqlalchemy as sa
import structlog
from pydantic import TypeAdapter, ValidationError
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.clock import from_ms, to_ms
from tasker.epoch import read_epoch
from tasker.hlc import HlcError, device_of, hlc_ms, parse_hlc
from tasker.ids import uuid7
from tasker.sync.merge import (
    delete_decision,
    field_decision,
    is_concurrent,
    tombstone_edit_decision,
)
from tasker.sync.registry import SyncRegistry, SyncTableSpec, parse_datetime
from tasker.tables import sync_conflicts, sync_ops, sync_state

log = structlog.get_logger("sync.engine")

BATCH_MAX = 500
MAX_FUTURE_DRIFT_MS = 600_000
NOTIFY_CHANNEL = "sync_changes"
DELETED = "deleted_at"

_DATETIME = TypeAdapter(datetime)  # AwareDatetime enforced by column adapters
_UUID = TypeAdapter(uuid.UUID)


class Reject(Exception):  # noqa: N818 - control-flow signal, not an error class
    """The operation is refused; nothing of it is applied."""

    def __init__(self, code: str, message: str, *, journal: bool = True) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.journal = journal


@dataclass(slots=True)
class ParsedOp:
    op_id: uuid.UUID
    spec: SyncTableSpec
    row_id: uuid.UUID
    type: str
    values: dict[str, Any]
    created_at: datetime | None
    restore: bool
    base_version: int
    hlc: str
    device: str
    ms: int


@dataclass(slots=True)
class OpOutcome:
    status: str = "applied"
    code: str | None = None
    message: str | None = None
    server_version: int | None = None
    conflicts: int = 0

    def stored(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "code": self.code,
            "message": self.message,
            "server_version": self.server_version,
            "conflicts": self.conflicts,
        }


@dataclass(slots=True)
class ConflictDraft:
    field: str
    kind: str
    losing_value: Any
    winning_value: Any
    losing_device: str | None
    winning_device: str | None
    losing_hlc: str | None
    winning_hlc: str | None


@dataclass(slots=True)
class SyncContext:
    session: AsyncSession
    registry: SyncRegistry
    now: datetime
    head: int
    device_id: uuid.UUID
    changed_versions: list[int] = field(default_factory=list)

    def next_version(self) -> int:
        self.head += 1
        self.changed_versions.append(self.head)
        return self.head


# ---------------------------------------------------------------- parsing


def _uuid_from(value: object, what: str) -> uuid.UUID:
    if not isinstance(value, str):
        raise Reject("invalid_id", f"{what} must be a UUID string")
    try:
        parsed = _UUID.validate_python(value)
    except ValidationError as exc:
        raise Reject("invalid_id", f"{what} is not a UUID") from exc
    if str(parsed) != value:
        raise Reject("invalid_id", f"{what} must be lowercase, hyphenated")
    return parsed


def peek_op_id(raw: object) -> uuid.UUID | None:
    if isinstance(raw, dict) and isinstance(raw.get("op_id"), str):
        try:
            return _uuid_from(raw["op_id"], "op_id")
        except Reject:
            return None
    return None


def parse_op(registry: SyncRegistry, device_id: uuid.UUID, raw: object, now: datetime) -> ParsedOp:
    if not isinstance(raw, dict):
        raise Reject("invalid_op", "operation must be an object")
    op_id = _uuid_from(raw.get("op_id"), "op_id")
    op_type = raw.get("type")
    if op_type not in ("upsert", "delete"):
        raise Reject("invalid_op", "type must be 'upsert' or 'delete'")
    table_name = raw.get("table")
    spec = registry.get(table_name) if isinstance(table_name, str) else None
    if spec is None:
        raise Reject("unknown_table", "table is not synchronised by this server")
    row_id = _uuid_from(raw.get("id"), "id")
    try:
        hlc = parse_hlc(raw.get("hlc"))
    except HlcError as exc:
        raise Reject("invalid_hlc", str(exc)) from exc
    if hlc.device != str(device_id):
        raise Reject("hlc_device_mismatch", "hlc device differs from the authenticated device")
    if hlc.ms > to_ms(now) + MAX_FUTURE_DRIFT_MS:
        raise Reject("hlc_in_future", "device clock is ahead of the server", journal=False)
    base = raw.get("base_version")
    if not isinstance(base, int) or isinstance(base, bool) or base < 0:
        raise Reject("invalid_op", "base_version must be a non-negative integer")

    values: dict[str, Any] = {}
    created_at: datetime | None = None
    restore = False
    if op_type == "upsert":
        values, created_at, restore = _parse_fields(spec, raw.get("fields"))
    return ParsedOp(
        op_id,
        spec,
        row_id,
        op_type,
        values,
        created_at,
        restore,
        base,
        str(hlc),
        hlc.device,
        hlc.ms,
    )


def _parse_fields(
    spec: SyncTableSpec, fields: object
) -> tuple[dict[str, Any], datetime | None, bool]:
    if not isinstance(fields, dict):
        raise Reject("invalid_op", "fields must be an object for upsert")
    values: dict[str, Any] = {}
    created_at: datetime | None = None
    restore = False
    for key, value in fields.items():
        if key == "created_at":
            created_at = _validate_created_at(value)
        elif key == DELETED:
            if value is not None:
                raise Reject(
                    "invalid_field", "deleted_at may only be null (restore); use a delete op"
                )
            restore = True
        elif key in spec.by_name:
            values[key] = _validate_value(spec, key, value)
    return values, created_at, restore


def _validate_created_at(value: object) -> datetime:
    if not isinstance(value, str):
        raise Reject("invalid_field", "created_at must be a string")
    try:
        return parse_datetime(value)
    except ValueError as exc:  # includes pydantic's ValidationError
        raise Reject(
            "invalid_field", "created_at must be a datetime with a timezone, 1970..2200"
        ) from exc


def _validate_value(spec: SyncTableSpec, name: str, value: object) -> Any:
    column = spec.by_name[name]
    if value is None:
        if not column.nullable:
            raise Reject("invalid_field", f"{name} must not be null")
        return None
    try:
        return column.adapter.validate_python(value)
    except (ValidationError, ValueError) as exc:
        raise Reject("invalid_field", f"{name} is invalid") from exc


# ---------------------------------------------------------------- helpers


def _normalise(value: Any) -> Any:
    """Bring driver-specific classes to the plain ones, so equality is about values.

    asyncpg returns its own ``UUID`` subclass (and datetimes in UTC), while validated input holds
    ``uuid.UUID`` and datetimes in whatever offset the client wrote.
    """
    if isinstance(value, uuid.UUID):
        return uuid.UUID(int=value.int)
    if isinstance(value, datetime):
        return value if value.tzinfo is None else value.astimezone(UTC)
    return value


def _same(a: Any, b: Any) -> bool:
    if isinstance(a, dict | list) or isinstance(b, dict | list):
        return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
    a, b = _normalise(a), _normalise(b)
    # The exact type still matters after normalising: ``True`` is not ``1`` and ``"1"`` is not 1.
    return type(a) is type(b) and bool(a == b)


def iso(moment: datetime | None) -> str | None:
    return None if moment is None else _DATETIME.dump_python(moment, mode="json")


def dump_value(spec: SyncTableSpec, name: str, value: Any) -> Any:
    if value is None:
        return None
    return spec.by_name[name].adapter.dump_python(value, mode="json")


def dump_values(spec: SyncTableSpec, values: Mapping[str, Any]) -> dict[str, Any]:
    return {name: dump_value(spec, name, value) for name, value in values.items()}


async def _load_row(
    ctx: SyncContext, spec: SyncTableSpec, row_id: uuid.UUID
) -> dict[str, Any] | None:
    result = await ctx.session.execute(sa.select(spec.table).where(spec.table.c.id == row_id))
    row = result.mappings().first()
    if row is None:
        return None
    loaded = dict(row)
    loaded["field_meta"] = copy.deepcopy(loaded["field_meta"])
    return loaded


@dataclass(slots=True)
class _DeletedParent:
    table: str
    row_id: uuid.UUID
    hlc: str
    deleted_at: datetime


async def _deleted_parent(
    ctx: SyncContext, spec: SyncTableSpec, values: Mapping[str, Any], names: Iterable[str]
) -> _DeletedParent | None:
    """Check foreign keys (raises ``parent_not_found``); return the first deleted parent."""
    found: _DeletedParent | None = None
    wanted = set(names)
    for column in spec.parents():
        parent_id = values.get(column.name)
        if column.name not in wanted or parent_id is None or column.parent is None:
            continue
        parent_spec = ctx.registry.get(column.parent)
        assert parent_spec is not None  # noqa: S101 - guaranteed by registration
        table = parent_spec.table
        result = await ctx.session.execute(
            sa.select(table.c.deleted_at, table.c.field_meta).where(table.c.id == parent_id)
        )
        parent = result.first()
        if parent is None:
            raise Reject("parent_not_found", f"{column.name} refers to a missing row")
        if parent.deleted_at is not None and found is None:
            found = _DeletedParent(
                column.parent, parent_id, parent.field_meta[DELETED]["h"], parent.deleted_at
            )
    return found


def _validate_row(spec: SyncTableSpec, row: Mapping[str, Any], now: datetime) -> None:
    for validator in spec.validators:
        problem = validator(row)
        if problem:
            raise Reject("validation_failed", problem)
    for timed in spec.timed_validators:
        problem = timed(row, now)
        if problem:
            raise Reject("validation_failed", problem)


# ---------------------------------------------------------------- cascades


def _deleted_at(ctx: SyncContext, hlc: str) -> datetime:
    """When a deletion counts as having happened: never earlier than its arrival on the server.

    A device that deleted a row while offline for 35 days must not see it fall out of the trash
    at once: the 30 days run from the moment the server got the deletion (spec 3.8).
    """
    return max(from_ms(hlc_ms(hlc)), ctx.now)


async def _cascade_delete(
    ctx: SyncContext,
    spec: SyncTableSpec,
    row_id: uuid.UUID,
    hlc: str,
    device: str,
    deleted_at: datetime,
) -> None:
    for child, column in ctx.registry.children_of(spec.name):
        table = child.table
        rows = (
            await ctx.session.execute(
                sa.select(table.c.id, table.c.updated_at, table.c.field_meta).where(
                    table.c[column.name] == row_id, table.c.deleted_at.is_(None)
                )
            )
        ).all()
        for row in rows:
            version = ctx.next_version()
            meta = copy.deepcopy(row.field_meta)
            meta[DELETED] = {"v": version, "h": hlc, "by": f"{spec.name}:{row_id}"}
            await ctx.session.execute(
                sa.update(table)
                .where(table.c.id == row.id)
                .values(
                    deleted_at=deleted_at,
                    server_version=version,
                    field_meta=meta,
                    updated_at=max(row.updated_at, hlc),
                    origin_device_id=uuid.UUID(device),
                )
            )
            await _cascade_delete(ctx, child, row.id, hlc, device, deleted_at)


async def _cascade_restore(
    ctx: SyncContext, spec: SyncTableSpec, row_id: uuid.UUID, restore_hlc: str, device: str
) -> None:
    owner = f"{spec.name}:{row_id}"
    for child, column in ctx.registry.children_of(spec.name):
        table = child.table
        rows = (
            await ctx.session.execute(
                sa.select(table.c.id, table.c.updated_at, table.c.field_meta).where(
                    table.c[column.name] == row_id, table.c.deleted_at.is_not(None)
                )
            )
        ).all()
        for row in rows:
            if row.field_meta.get(DELETED, {}).get("by") != owner:
                continue  # deleted on its own, not by the parent: stays in the trash
            version = ctx.next_version()
            meta = copy.deepcopy(row.field_meta)
            meta[DELETED] = {"v": version, "h": restore_hlc}
            await ctx.session.execute(
                sa.update(table)
                .where(table.c.id == row.id)
                .values(
                    deleted_at=None,
                    server_version=version,
                    field_meta=meta,
                    updated_at=max(row.updated_at, restore_hlc),
                    origin_device_id=uuid.UUID(device),
                )
            )
            await _cascade_restore(ctx, child, row.id, restore_hlc, device)


# ---------------------------------------------------------------- conflicts


async def _log_conflicts(ctx: SyncContext, op: ParsedOp, drafts: list[ConflictDraft]) -> None:
    for draft in drafts:
        await ctx.session.execute(
            sa.insert(sync_conflicts).values(
                id=uuid7(),
                created_at=ctx.now,
                table_name=op.spec.name,
                row_id=op.row_id,
                field=draft.field,
                kind=draft.kind,
                losing_value=draft.losing_value,
                winning_value=draft.winning_value,
                losing_device_id=_maybe_uuid(draft.losing_device),
                winning_device_id=_maybe_uuid(draft.winning_device),
                losing_hlc=draft.losing_hlc,
                winning_hlc=draft.winning_hlc,
                op_id=op.op_id,
            )
        )


def _maybe_uuid(value: str | None) -> uuid.UUID | None:
    return None if value is None else uuid.UUID(value)


# ---------------------------------------------------------------- apply


async def apply_op(ctx: SyncContext, op: ParsedOp) -> OpOutcome:
    row = await _load_row(ctx, op.spec, op.row_id)
    if op.type == "delete":
        return await _apply_delete(ctx, op, row)
    if row is None:
        return await _apply_create(ctx, op)
    return await _apply_update(ctx, op, row)


async def _apply_create(ctx: SyncContext, op: ParsedOp) -> OpOutcome:
    spec = op.spec
    missing = [c.name for c in spec.columns if c.required and c.name not in op.values]
    if missing or op.created_at is None:
        names = ["created_at"] if op.created_at is None else []
        raise Reject("missing_fields", "missing: " + ", ".join([*names, *missing]))
    problem = spec.id_rule(op.row_id, op.values)
    if problem:
        raise Reject("invalid_id", problem)
    values = {c.name: op.values.get(c.name) for c in spec.columns}
    _validate_row(spec, values, ctx.now)
    parent = await _deleted_parent(ctx, spec, values, [c.name for c in spec.parents()])

    version = ctx.next_version()
    meta: dict[str, Any] = {name: {"v": version, "h": op.hlc} for name in op.values}
    meta[DELETED] = {"v": version, "h": op.hlc}
    deleted_at = None
    drafts: list[ConflictDraft] = []
    if parent is not None:
        meta[DELETED] = {"v": version, "h": parent.hlc, "by": f"{parent.table}:{parent.row_id}"}
        deleted_at = parent.deleted_at
        drafts.append(_parent_deleted_draft(op, parent))
    await ctx.session.execute(
        sa.insert(spec.table).values(
            id=op.row_id,
            created_at=op.created_at,
            updated_at=op.hlc,
            deleted_at=deleted_at,
            server_version=version,
            origin_device_id=uuid.UUID(op.device),
            field_meta=meta,
            **values,
        )
    )
    await _log_conflicts(ctx, op, drafts)
    return OpOutcome(server_version=version, conflicts=len(drafts))


def _parent_deleted_draft(op: ParsedOp, parent: _DeletedParent) -> ConflictDraft:
    return ConflictDraft(
        DELETED,
        "parent_deleted",
        None,
        {"deleted_at": iso(parent.deleted_at), "parent": f"{parent.table}:{parent.row_id}"},
        op.device,
        device_of(parent.hlc),
        op.hlc,
        parent.hlc,
    )


def _merge_fields(
    op: ParsedOp, row: Mapping[str, Any]
) -> tuple[dict[str, Any], set[str], list[ConflictDraft]]:
    """Field-level merge: columns to write, fields whose clock only moves, conflicts to log."""
    spec = op.spec
    meta: dict[str, Any] = row["field_meta"]
    updates: dict[str, Any] = {}
    touched: set[str] = set()
    drafts: list[ConflictDraft] = []
    for name, new in op.values.items():
        current = row[name]
        same = _same(new, current)
        if spec.by_name[name].immutable:
            if not same:
                raise Reject("immutable_field", f"{name} cannot be changed")
            continue
        entry: dict[str, Any] | None = meta.get(name)
        decision = field_decision(
            same_value=same, entry=entry, op_hlc=op.hlc, base_version=op.base_version
        )
        if decision == "touch":
            touched.add(name)
        elif decision == "noop":
            continue
        elif decision == "apply":
            updates[name] = new
        else:
            assert entry is not None  # noqa: S101 - conflicts imply an entry
            wins = decision == "apply_conflict"
            if wins:
                updates[name] = new
            drafts.append(_field_draft(spec, name, current, new, entry, op, op_wins=wins))
    return updates, touched, drafts


async def _plan_restore(
    ctx: SyncContext,
    op: ParsedOp,
    row: Mapping[str, Any],
    merged: Mapping[str, Any],
    drafts: list[ConflictDraft],
) -> str | None:
    """Edit/restore against a tombstone. Returns the hlc of the deletion being undone."""
    if row[DELETED] is None or not (op.restore or op.values):
        return None
    entry_d = row["field_meta"][DELETED]
    decision = tombstone_edit_decision(
        entry_deleted=entry_d, op_hlc=op.hlc, base_version=op.base_version, restore=op.restore
    )
    deleted_iso = iso(row[DELETED])
    restore_from: str | None = None
    if decision == "restore":
        restore_from = entry_d["h"]
    elif decision == "resurrect_conflict":
        restore_from = entry_d["h"]
        drafts.append(_resurrected(op, entry_d, deleted_iso))
    elif decision == "stay_deleted_conflict":
        losing = {DELETED: None} if op.restore else dump_values(op.spec, op.values)
        drafts.append(_edit_vs_delete(op, entry_d, deleted_iso, losing))
    if restore_from is not None and await _any_deleted_parent(ctx, op.spec, merged):
        drafts[:] = [d for d in drafts if d.kind != "resurrected"]
        return None  # the row stays in the trash while its parent is there
    return restore_from


async def _apply_update(ctx: SyncContext, op: ParsedOp, row: dict[str, Any]) -> OpOutcome:
    spec = op.spec
    updates, touched, drafts = _merge_fields(op, row)
    merged = {**row, **updates}
    if updates:
        _validate_row(spec, {c.name: merged[c.name] for c in spec.columns}, ctx.now)
    parent = await _deleted_parent(ctx, spec, merged, [n for n in updates if n in spec.by_name])
    restore_from = await _plan_restore(ctx, op, row, merged, drafts)

    tombstone_by: _DeletedParent | None = None
    if row[DELETED] is None and parent is not None:
        tombstone_by = parent
        drafts.append(_parent_deleted_draft(op, parent))

    # A "touch" (same value, newer clock) also counts: the field's clock moved, so the row's
    # ``updated_at`` must carry it, or a device that only sees the row (pull) would stamp its next
    # write with an older HLC than the field already has and lose to it.
    changed = bool(updates) or bool(touched) or restore_from is not None or tombstone_by is not None
    # Even a no-op gets a new version: the client's local row (its own updated_at, deleted_at)
    # may differ from the server's, and only a fresh version makes the row come back in pull.
    version = ctx.next_version()
    meta: dict[str, Any] = row["field_meta"]
    for name in (*updates, *touched):
        meta[name] = {"v": version, "h": op.hlc}
    values: dict[str, Any] = dict(updates)
    if restore_from is not None:
        meta[DELETED] = {"v": version, "h": op.hlc}
        values[DELETED] = None
    if tombstone_by is not None:
        owner = f"{tombstone_by.table}:{tombstone_by.row_id}"
        meta[DELETED] = {"v": version, "h": tombstone_by.hlc, "by": owner}
        values[DELETED] = tombstone_by.deleted_at
    values.update(server_version=version, field_meta=meta)
    if changed:
        values.update(
            updated_at=max(row["updated_at"], op.hlc), origin_device_id=uuid.UUID(op.device)
        )
    await ctx.session.execute(
        sa.update(spec.table).where(spec.table.c.id == op.row_id).values(**values)
    )
    if restore_from is not None:
        await _cascade_restore(ctx, spec, op.row_id, op.hlc, op.device)
    await _log_conflicts(ctx, op, drafts)
    return OpOutcome(server_version=version, conflicts=len(drafts))


async def _any_deleted_parent(
    ctx: SyncContext, spec: SyncTableSpec, values: Mapping[str, Any]
) -> bool:
    return await _deleted_parent(ctx, spec, values, [c.name for c in spec.parents()]) is not None


def _field_draft(
    spec: SyncTableSpec,
    name: str,
    current: Any,
    incoming: Any,
    entry: Mapping[str, Any],
    op: ParsedOp,
    *,
    op_wins: bool,
) -> ConflictDraft:
    current_json = dump_value(spec, name, current)
    incoming_json = dump_value(spec, name, incoming)
    server_device = device_of(entry["h"])
    if op_wins:
        return ConflictDraft(
            name, "field", current_json, incoming_json, server_device, op.device, entry["h"], op.hlc
        )
    return ConflictDraft(
        name, "field", incoming_json, current_json, op.device, server_device, op.hlc, entry["h"]
    )


def _resurrected(
    op: ParsedOp, entry_d: Mapping[str, Any], deleted_iso: str | None
) -> ConflictDraft:
    return ConflictDraft(
        DELETED,
        "resurrected",
        {"deleted_at": deleted_iso},
        {"deleted_at": None},
        device_of(entry_d["h"]),
        op.device,
        entry_d["h"],
        op.hlc,
    )


def _edit_vs_delete(
    op: ParsedOp, entry_d: Mapping[str, Any], deleted_iso: str | None, losing: dict[str, Any]
) -> ConflictDraft:
    return ConflictDraft(
        DELETED,
        "edit_vs_delete",
        losing,
        {"deleted_at": deleted_iso},
        op.device,
        device_of(entry_d["h"]),
        op.hlc,
        entry_d["h"],
    )


async def _apply_delete(ctx: SyncContext, op: ParsedOp, row: dict[str, Any] | None) -> OpOutcome:
    if row is None:
        return OpOutcome(server_version=None)
    spec = op.spec
    if row[DELETED] is not None:
        # Touch (see _apply_update); a later deletion also refreshes the deletion's clock, so an
        # older concurrent restore cannot beat it.
        version = ctx.next_version()
        touched_meta: dict[str, Any] = row["field_meta"]
        entry = touched_meta[DELETED]
        extra: dict[str, Any] = {}
        if "by" in entry:
            # The row is in the trash only because its parent was deleted. An explicit delete
            # makes it its own deletion: restoring the parent must not bring it back (3.5).
            touched_meta[DELETED] = {"v": version, "h": max(entry["h"], op.hlc)}
        elif op.hlc > entry["h"]:
            touched_meta[DELETED] = {**entry, "v": version, "h": op.hlc}
        if touched_meta[DELETED]["h"] != entry["h"] or "by" in entry:
            # The deletion's clock (or owner) changed: let pull carry the newest clock (see above).
            extra = {
                "updated_at": max(row["updated_at"], op.hlc),
                "origin_device_id": uuid.UUID(op.device),
            }
        await ctx.session.execute(
            sa.update(spec.table)
            .where(spec.table.c.id == op.row_id)
            .values(server_version=version, field_meta=touched_meta, **extra)
        )
        return OpOutcome(server_version=version)
    meta: dict[str, Any] = row["field_meta"]
    decision = delete_decision(
        already_deleted=False,
        field_entries=meta,
        op_hlc=op.hlc,
        base_version=op.base_version,
    )
    concurrent = {
        name: entry
        for name, entry in meta.items()
        if name != DELETED and is_concurrent(entry, op.base_version, op.device)
    }
    newer = concurrent if decision == "delete_lost" else {}
    if decision == "delete_lost":
        newer = {name: entry for name, entry in concurrent.items() if entry["h"] > op.hlc}
    version = ctx.next_version()
    deleted_at = _deleted_at(ctx, op.hlc)
    if newer:
        winner = max(newer.values(), key=lambda e: e["h"])
        draft = ConflictDraft(
            DELETED,
            "resurrected",
            {"deleted_at": iso(deleted_at)},
            {"fields": dump_values(spec, {n: row[n] for n in newer})},
            op.device,
            device_of(winner["h"]),
            op.hlc,
            winner["h"],
        )
        await ctx.session.execute(
            sa.update(spec.table).where(spec.table.c.id == op.row_id).values(server_version=version)
        )
        await _log_conflicts(ctx, op, [draft])
        return OpOutcome(server_version=version, conflicts=1)

    meta[DELETED] = {"v": version, "h": op.hlc}
    await ctx.session.execute(
        sa.update(spec.table)
        .where(spec.table.c.id == op.row_id)
        .values(
            deleted_at=deleted_at,
            server_version=version,
            field_meta=meta,
            updated_at=max(row["updated_at"], op.hlc),
            origin_device_id=uuid.UUID(op.device),
        )
    )
    await _cascade_delete(ctx, spec, op.row_id, op.hlc, op.device, deleted_at)
    drafts: list[ConflictDraft] = []
    if concurrent:
        other = next(iter(concurrent.values()))
        drafts.append(
            ConflictDraft(
                DELETED,
                "edit_vs_delete",
                {"fields": dump_values(spec, {n: row[n] for n in concurrent})},
                {"deleted_at": iso(deleted_at)},
                device_of(other["h"]),
                op.device,
                other["h"],
                op.hlc,
            )
        )
    await _log_conflicts(ctx, op, drafts)
    return OpOutcome(server_version=version, conflicts=len(drafts))


# ---------------------------------------------------------------- batch


@dataclass(slots=True)
class PushResult:
    results: list[dict[str, Any]]
    head_version: int
    server_epoch: str


async def lock_sync_state(session: AsyncSession) -> tuple[int, int]:
    """Serialise writers: the head counter row is locked until commit (gapless versions)."""
    result = await session.execute(
        sa.select(sync_state.c.head_version, sync_state.c.purge_watermark)
        .where(sync_state.c.id == 1)
        .with_for_update()
    )
    head, watermark = result.one()
    return int(head), int(watermark)


async def finish_writes(ctx: SyncContext, start_head: int) -> None:
    """Persist the head counter and announce the commit to ``/events`` listeners."""
    if ctx.head == start_head:
        return
    await ctx.session.execute(
        sa.update(sync_state).where(sync_state.c.id == 1).values(head_version=ctx.head)
    )
    payload = json.dumps({"head": ctx.head, "device": str(ctx.device_id)})
    await ctx.session.execute(
        sa.text("SELECT pg_notify(:channel, :payload)"),
        {
            "channel": NOTIFY_CHANNEL,
            "payload": payload,
        },
    )


async def apply_push(
    session: AsyncSession,
    registry: SyncRegistry,
    device_id: uuid.UUID,
    raw_ops: list[Any],
    now: datetime,
) -> PushResult:
    async with session.begin():
        head, _ = await lock_sync_state(session)
        ctx = SyncContext(session, registry, now, head, device_id)
        journal = await _load_journal(session, raw_ops)
        results: list[dict[str, Any]] = []
        for raw in raw_ops:
            results.append(await _process(ctx, raw, journal))
        await finish_writes(ctx, head)
        return PushResult(results, ctx.head, await read_epoch(session))


async def _load_journal(session: AsyncSession, raw_ops: list[Any]) -> dict[uuid.UUID, Any]:
    ids = [op_id for op_id in (peek_op_id(raw) for raw in raw_ops) if op_id is not None]
    if not ids:
        return {}
    rows = await session.execute(
        sa.select(sync_ops.c.op_id, sync_ops.c.device_id, sync_ops.c.result).where(
            sync_ops.c.op_id.in_(ids)
        )
    )
    return {row.op_id: (row.device_id, row.result) for row in rows}


def _result_dict(op_id: uuid.UUID | None, outcome: OpOutcome, *, duplicate: bool) -> dict[str, Any]:
    return {
        "op_id": None if op_id is None else str(op_id),
        **outcome.stored(),
        "duplicate": duplicate,
    }


async def _process(ctx: SyncContext, raw: Any, journal: dict[uuid.UUID, Any]) -> dict[str, Any]:
    op_id = peek_op_id(raw)
    if op_id is not None and op_id in journal:
        owner, stored = journal[op_id]
        if owner != ctx.device_id:
            outcome = OpOutcome("rejected", "invalid_id", "op_id was used by another device")
            return _result_dict(op_id, outcome, duplicate=False)
        return {"op_id": str(op_id), **stored, "duplicate": True}

    head_before, changed_before = ctx.head, len(ctx.changed_versions)
    journaled = True
    try:
        op = parse_op(ctx.registry, ctx.device_id, raw, ctx.now)
        async with ctx.session.begin_nested():
            outcome = await apply_op(ctx, op)
    except Reject as reject:
        ctx.head = head_before
        del ctx.changed_versions[changed_before:]
        outcome = OpOutcome("rejected", reject.code, reject.message)
        journaled = reject.journal
    except (DBAPIError, UnicodeError, OverflowError, ValueError, RecursionError) as exc:
        # Safety net: whatever the validators missed must cost this operation, not the batch.
        # The savepoint is already rolled back by ``begin_nested``.
        if isinstance(exc, DBAPIError) and exc.connection_invalidated:
            raise  # the connection is gone: the whole request fails and the client retries it
        ctx.head = head_before
        del ctx.changed_versions[changed_before:]
        log.warning("sync_op_failed", error_type=type(exc).__name__)
        outcome = OpOutcome("rejected", "op_failed", "The operation could not be applied")
    if op_id is not None and journaled:
        await ctx.session.execute(
            pg_insert(sync_ops)
            .values(
                op_id=op_id,
                device_id=ctx.device_id,
                result=outcome.stored(),
                created_at=ctx.now,
            )
            .on_conflict_do_nothing()
        )
        journal[op_id] = (ctx.device_id, outcome.stored())
    return _result_dict(op_id, outcome, duplicate=False)
