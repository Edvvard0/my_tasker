"""Reference implementation of the client sync algorithm (spec stage1 section 5).

The Flutter client is written from the spec; this executable version is what the property
tests drive, and its pure functions (``collapse``, ``rebase_row``) are checked against the
shared vectors in ``shared-test-vectors/sync/outbox.json``.
"""

import copy
import uuid
from datetime import UTC, datetime
from typing import Any, Protocol

from tasker.clock import from_ms
from tasker.hlc import HlcClock, hlc_ms
from tasker.ids import uuid7

Op = dict[str, Any]
Row = dict[str, Any]
BATCH = 500


class NetworkError(Exception):
    """The request or its response was lost."""


class ServerPort(Protocol):
    async def push(self, device_id: uuid.UUID, ops: list[Op]) -> list[dict[str, Any]]: ...

    async def pull(self, device_id: uuid.UUID, since: int, limit: int) -> dict[str, Any]: ...


def ms_iso(ms: int) -> str:
    return from_ms(ms).astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


def _state(op: Op) -> str:
    return str(op.get("state", "pending"))


def collapse(outbox: list[Op], new: Op) -> list[Op]:
    """Add ``new`` to the outbox, merging into the row's last op when it is still ``pending``."""
    result = copy.deepcopy(outbox)
    new = copy.deepcopy(new)
    last = next(
        (i for i in range(len(result) - 1, -1, -1)
         if (result[i]["table"], result[i]["id"]) == (new["table"], new["id"])),
        None,
    )  # fmt: skip
    if last is None or _state(result[last]) != "pending":
        return [*result, new]
    prev = result[last]
    if prev["type"] == "upsert" and new["type"] == "upsert":
        prev["fields"] = {**prev["fields"], **new["fields"]}
        prev["hlc"] = new["hlc"]
        return result
    if prev["type"] == "upsert" and new["type"] == "delete" and prev["base_version"] > 0:
        result[last] = {
            **{k: v for k, v in prev.items() if k != "fields"},
            "type": "delete",
            "hlc": new["hlc"],
        }
        return result
    return [*result, new]


def apply_ops_to_row(row: Row, ops: list[Op]) -> Row:
    """Lay non-rejected ops over ``row`` in order (the rebase step)."""
    merged = copy.deepcopy(row)
    for op in ops:
        if _state(op) == "rejected":
            continue
        if op["type"] == "upsert":
            merged.update(copy.deepcopy(op["fields"]))
        else:
            merged["deleted_at"] = ms_iso(hlc_ms(op["hlc"]))
        merged["updated_at"] = max(merged["updated_at"], op["hlc"])
    return merged


def rebase_row(server_row: Row, outbox: list[Op]) -> Row:
    same = [op for op in outbox if op["id"] == server_row["id"]]
    return apply_ops_to_row(server_row, same)


class SimClient:
    """A device: local store, outbox, HLC and the push-then-pull loop."""

    def __init__(self, device_id: uuid.UUID, now_ms: Any) -> None:
        self.device_id = device_id
        self.now_ms = now_ms  # callable returning this device's wall clock in ms
        self.hlc = HlcClock(device_id)
        self.rows: dict[tuple[str, str], Row] = {}
        self.outbox: list[Op] = []
        self.cursor = 0
        self.rejected: list[tuple[Op, str]] = []
        self.written: list[tuple[str, str, str, Any, str, int]] = []  # provenance for the checks

    # ---- local writes (one "transaction": row + outbox) -------------------------------

    def _stamp(self) -> str:
        return self.hlc.send(self.now_ms())

    def _emit(
        self,
        table: str,
        row_id: str,
        op_type: str,
        fields: dict[str, Any] | None,
        base: int,
        stamp: str,
    ) -> None:
        op: Op = {
            "op_id": str(uuid7()),
            "table": table,
            "id": row_id,
            "type": op_type,
            "base_version": base,
            "hlc": stamp,
        }
        if op_type == "upsert":
            op["fields"] = fields or {}
        self.outbox = collapse(self.outbox, op)

    def create(self, table: str, row_id: str, fields: dict[str, Any]) -> None:
        stamp = self._stamp()
        created = ms_iso(hlc_ms(stamp))
        row: Row = {
            "id": row_id, "created_at": created, "updated_at": stamp, "deleted_at": None,
            "server_version": 0, "origin_device_id": str(self.device_id), **fields,
        }  # fmt: skip
        self.rows[(table, row_id)] = row
        self._emit(table, row_id, "upsert", {**fields, "created_at": created}, 0, stamp)
        for name, value in fields.items():
            self.written.append((table, row_id, name, value, stamp, 0))

    def edit(self, table: str, row_id: str, fields: dict[str, Any]) -> None:
        row = self.rows[(table, row_id)]
        stamp = self._stamp()
        base = row["server_version"]
        row.update(fields)
        row["updated_at"] = stamp
        self._emit(table, row_id, "upsert", fields, base, stamp)
        for name, value in fields.items():
            self.written.append((table, row_id, name, value, stamp, base))

    def delete(self, table: str, row_id: str) -> None:
        row = self.rows[(table, row_id)]
        stamp = self._stamp()
        base = row["server_version"]
        row["deleted_at"] = ms_iso(hlc_ms(stamp))
        row["updated_at"] = stamp
        self._emit(table, row_id, "delete", None, base, stamp)

    def restore(self, table: str, row_id: str) -> None:
        row = self.rows[(table, row_id)]
        stamp = self._stamp()
        base = row["server_version"]
        row["deleted_at"] = None
        row["updated_at"] = stamp
        self._emit(table, row_id, "upsert", {"deleted_at": None}, base, stamp)

    # ---- sync --------------------------------------------------------------------------

    async def push(self, server: ServerPort) -> None:
        while True:
            batch = [op for op in self.outbox if _state(op) in ("pending", "in_flight")][:BATCH]
            if not batch:
                return
            for op in batch:
                op["state"] = "in_flight"
            wire = [{k: v for k, v in op.items() if k != "state"} for op in batch]
            results = await server.push(self.device_id, wire)  # NetworkError: ops stay in_flight
            by_id = {op["op_id"]: op for op in batch}
            for result in results:
                op = by_id[result["op_id"]]
                if result["status"] == "applied":
                    self.outbox = [o for o in self.outbox if o["op_id"] != op["op_id"]]
                else:
                    op["state"] = "rejected"
                    self.rejected.append((op, result["code"]))

    async def pull(self, server: ServerPort, limit: int = 1000) -> None:
        while True:
            page = await server.pull(self.device_id, self.cursor, limit)
            for change in page["changes"]:
                row = change["row"]
                self.hlc.receive(row["updated_at"], self.now_ms())
                self.rows[(change["table"], row["id"])] = rebase_row(row, self.outbox)
            self.cursor = page["next_since"]
            if not page["has_more"]:
                return

    async def sync(self, server: ServerPort) -> None:
        await self.push(server)
        await self.pull(server)

    async def full_resync(self, server: ServerPort) -> None:
        """Spec 5.3: fetch everything from 0, then replace the store and rebase the outbox."""
        staged: dict[tuple[str, str], Row] = {}
        since = 0
        while True:
            page = await server.pull(self.device_id, since, 1000)
            for change in page["changes"]:
                self.hlc.receive(change["row"]["updated_at"], self.now_ms())
                staged[(change["table"], change["row"]["id"])] = change["row"]
            since = page["next_since"]
            if not page["has_more"]:
                break
        self.rows = {key: rebase_row(row, self.outbox) for key, row in staged.items()}
        self.cursor = since

    def purge_old_tombstones(self, now_ms: int, days: int = 30) -> None:
        """Spec 3.8: drop local tombstones older than the trash period (nothing pending)."""
        limit = datetime.fromtimestamp(now_ms / 1000 - days * 86400, UTC).isoformat()
        busy = {op["id"] for op in self.outbox}
        for key, row in list(self.rows.items()):
            deleted = row["deleted_at"]
            if deleted and row["id"] not in busy and deleted.replace("Z", "+00:00") < limit:
                del self.rows[key]

    def visible(self, parents: dict[str, str] | None = None) -> dict[tuple[str, str], Row]:
        return {key: row for key, row in self.rows.items() if row["deleted_at"] is None}
