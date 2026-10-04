"""Synchronised table of Stage 6: ``merchant_category_rules`` (spec stage6_banks.md, section 7)."""

import uuid
from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from tasker.banks.reference import normalize_merchant
from tasker.calendar.ids import namespace
from tasker.sync.registry import (
    ColumnSpec,
    SyncTableSpec,
    define_sync_table,
    enum_column,
    text_column,
    uuid_column,
)
from tasker.tables import metadata

MATCH_TYPES = ("exact", "contains")
RULE_KINDS = ("expense", "income")


def rule_id(kind: str, match_type: str, merchant_key: str) -> uuid.UUID:
    """The deterministic id: one rule per (kind, match type, merchant) on any number of devices."""
    return uuid.uuid5(namespace("merchant_category_rules"), f"{kind}|{match_type}|{merchant_key}")


def _fixed(column: ColumnSpec) -> ColumnSpec:
    return replace(column, immutable=True)


RULE_COLUMNS: tuple[ColumnSpec, ...] = (
    _fixed(text_column("merchant_key", min_length=1, max_length=200)),
    _fixed(enum_column("match_type", MATCH_TYPES)),
    _fixed(enum_column("kind", RULE_KINDS)),
    uuid_column("category_id"),
)


def rule_problem(row: Mapping[str, Any]) -> str | None:
    if normalize_merchant(row["merchant_key"]) != row["merchant_key"]:
        return "merchant_key must be a normalized merchant name"
    return None


def _rule_id_rule(row_id: uuid.UUID, values: Mapping[str, Any]) -> str | None:
    expected = rule_id(values["kind"], values["match_type"], values["merchant_key"])
    return None if row_id == expected else "id must be uuid5(namespace, kind|match_type|key)"


merchant_category_rules: SyncTableSpec = define_sync_table(
    metadata,
    "merchant_category_rules",
    RULE_COLUMNS,
    id_rule=_rule_id_rule,
    validators=(rule_problem,),
)

BANKS_TABLES: tuple[SyncTableSpec, ...] = (merchant_category_rules,)
