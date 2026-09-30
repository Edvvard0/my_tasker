"""Pure merge decisions (spec 3.4). Shared with the client through ``shared-test-vectors/sync``.

``entry`` is the server's per-field record ``{"v": server_version, "h": hlc}``.
"""

from collections.abc import Mapping
from typing import Any

from tasker.hlc import device_of

DELETED = "deleted_at"


def is_concurrent(entry: Mapping[str, Any] | None, base_version: int, device: str) -> bool:
    """A field changed after the client's base by *another* device."""
    return entry is not None and entry["v"] > base_version and device_of(entry["h"]) != device


def field_decision(
    *, same_value: bool, entry: Mapping[str, Any] | None, op_hlc: str, base_version: int
) -> str:
    """One field of an upsert: ``noop | touch | apply | apply_conflict | keep_conflict``.

    ``touch``: the value is already there, but this write is newer than the recorded one, so the
    field's clock is refreshed (otherwise an older concurrent write could later win over it).
    """
    if same_value:
        return "touch" if entry is None or op_hlc > entry["h"] else "noop"
    if not is_concurrent(entry, base_version, device_of(op_hlc)):
        return "apply"
    assert entry is not None  # noqa: S101 - concurrency implies an entry
    return "apply_conflict" if op_hlc > entry["h"] else "keep_conflict"


def delete_decision(
    *,
    already_deleted: bool,
    field_entries: Mapping[str, Mapping[str, Any]],
    op_hlc: str,
    base_version: int,
) -> str:
    """A delete op: ``noop | delete | delete_edit_conflict | delete_lost``."""
    if already_deleted:
        return "noop"
    device = device_of(op_hlc)
    concurrent = [
        entry
        for name, entry in field_entries.items()
        if name != DELETED and is_concurrent(entry, base_version, device)
    ]
    if not concurrent:
        return "delete"
    if any(entry["h"] > op_hlc for entry in concurrent):
        return "delete_lost"
    return "delete_edit_conflict"


def tombstone_edit_decision(
    *, entry_deleted: Mapping[str, Any], op_hlc: str, base_version: int, restore: bool
) -> str:
    """Edit or restore aimed at a tombstone.

    ``restore | stay_deleted | resurrect_conflict | stay_deleted_conflict``.
    """
    if not is_concurrent(entry_deleted, base_version, device_of(op_hlc)):
        return "restore" if restore else "stay_deleted"
    return "resurrect_conflict" if op_hlc > entry_deleted["h"] else "stay_deleted_conflict"
