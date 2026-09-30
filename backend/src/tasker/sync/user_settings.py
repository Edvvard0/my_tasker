"""First real synchronised table: key/value settings shared by all devices."""

import uuid
from collections.abc import Mapping
from typing import Any

import sqlalchemy as sa

from tasker.sync.registry import (
    SyncTableSpec,
    define_sync_table,
    json_column,
    text_column,
)
from tasker.tables import metadata

NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "urn:my-tasker:user_settings")
KEY_PATTERN = r"^[a-z0-9][a-z0-9_.-]*$"


def settings_id(key: str) -> uuid.UUID:
    """Deterministic row id, so two devices creating one key offline yield one row."""
    return uuid.uuid5(NAMESPACE, key)


def _id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    return None if row_id == settings_id(values["key"]) else "id must be uuid5(namespace, key)"


user_settings: SyncTableSpec = define_sync_table(
    metadata,
    "user_settings",
    (
        text_column("key", min_length=1, max_length=100, pattern=KEY_PATTERN, immutable=True),
        json_column("value", max_bytes=16384),
    ),
    id_rule=_id_rule,
)
# One row per key (the id is derived from it): also enforced by the database.
sa.Index("user_settings_key", user_settings.table.c.key, unique=True)
