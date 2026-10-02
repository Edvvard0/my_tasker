"""Columns and validators of the Stage 5 tables (spec: ``docs/specs/stage5_finance.md``)."""

import uuid
from collections.abc import Mapping
from typing import Any

from tasker.calendar.tables import COLOR_PATTERN
from tasker.calendar.timefmt import DATE_PATTERN, parse_date
from tasker.finance.presets import PRESET_KEYS, category_id
from tasker.money import MAX_KOPECKS
from tasker.sync.registry import (
    ColumnSpec,
    bool_column,
    datetime_column,
    enum_column,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid7_id_rule,
    uuid_column,
)
from tasker.work.schema import moment_ok

Row = Mapping[str, Any]

ACCOUNT_KINDS = ("cash", "debit_card", "credit_card", "savings", "deposit", "other")
CARD_KINDS = ("debit_card", "credit_card")
CATEGORY_KINDS = ("expense", "income")
TRANSACTION_KINDS = ("expense", "income", "transfer")
TRANSACTION_SOURCES = ("manual", "notification", "statement", "work_payment")
TRANSACTION_STATUSES = ("confirmed", "draft", "needs_review")
CHECKPOINT_SOURCES = ("manual", "notification", "statement")
DEBT_DIRECTIONS = ("owed_to_me", "i_owe")
GOAL_TERM_KINDS = ("accounts", "all_accounts", "debts_to_me", "my_debts", "receivables")
GOAL_SIGNS = ("+", "-")

MAX_GOAL_TERMS = 30
MAX_TERM_IDS = 50
CATEGORY_KEY_PATTERN = r"^[a-z][a-z0-9_.]{0,47}$"
HASH_PATTERN = r"^[0-9a-f]{16,64}$"


def _date(name: str, *, required: bool = False) -> ColumnSpec:
    return text_column(
        name,
        min_length=10,
        max_length=10,
        pattern=DATE_PATTERN,
        nullable=not required,
        required=required,
    )


def _money(
    name: str, *, positive: bool = False, signed: bool = False, required: bool = False
) -> ColumnSpec:
    low = -MAX_KOPECKS if signed else (1 if positive else 0)
    return int_column(name, ge=low, le=MAX_KOPECKS, nullable=not required, required=required)


def _blank(value: object) -> bool:
    return not str(value).strip()


# ------------------------------------------------------------------ accounts

ACCOUNT_COLUMNS: tuple[ColumnSpec, ...] = (
    text_column("name", min_length=1, max_length=100),
    enum_column("kind", ACCOUNT_KINDS),
    text_column("bank", max_length=100, nullable=True, required=False),
    text_column(
        "card_last4",
        min_length=4,
        max_length=4,
        pattern=r"^[0-9]{4}$",
        nullable=True,
        required=False,
    ),
    _money("opening_balance", signed=True, required=True),
    _date("opening_date", required=True),
    bool_column("include_in_total"),
    _money("credit_limit"),
    bool_column("archived"),
)


def account_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    if parse_date(row["opening_date"]) is None:
        return "opening_date must be a real date"
    if row["credit_limit"] is not None and row["kind"] != "credit_card":
        return "credit_limit is only for a credit card"
    if row["card_last4"] is not None and row["kind"] not in CARD_KINDS:
        return "card_last4 is only for a card"
    return None


# ------------------------------------------------------------------ categories

CATEGORY_COLUMNS: tuple[ColumnSpec, ...] = (
    text_column("name", min_length=1, max_length=100),
    enum_column("kind", CATEGORY_KINDS),
    uuid_column("parent_id", nullable=True, required=False),
    text_column("icon", min_length=1, max_length=50, nullable=True, required=False),
    text_column("color", max_length=7, pattern=COLOR_PATTERN, nullable=True, required=False),
    text_column(
        "system_key",
        max_length=48,
        pattern=CATEGORY_KEY_PATTERN,
        nullable=True,
        required=False,
        immutable=True,
    ),
)


def category_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    key = row["system_key"]
    if key is not None and key not in PRESET_KEYS:
        return "unknown system_key"
    return None


def category_id_rule(row_id: uuid.UUID, values: Row) -> str | None:
    key = values.get("system_key")
    if key in PRESET_KEYS:
        return None if row_id == category_id(key) else "id must be uuid5(namespace, system_key)"
    return uuid7_id_rule(row_id, values)


# ------------------------------------------------------------------ transactions

TRANSACTION_COLUMNS: tuple[ColumnSpec, ...] = (
    enum_column("kind", TRANSACTION_KINDS),
    reference_column("account_id", "accounts"),
    reference_column("to_account_id", "accounts", nullable=True, required=False),
    _money("amount", positive=True, required=True),
    datetime_column("occurred_at"),
    uuid_column("category_id", nullable=True, required=False),
    text_column("merchant", max_length=200, nullable=True, required=False),
    text_column("comment", max_length=2000, nullable=True, required=False),
    enum_column("source", TRANSACTION_SOURCES),
    enum_column("status", TRANSACTION_STATUSES),
    text_column("external_id", min_length=1, max_length=200, nullable=True, required=False),
    text_column(
        "dedup_hash",
        min_length=16,
        max_length=64,
        pattern=HASH_PATTERN,
        nullable=True,
        required=False,
    ),
    uuid_column("work_payment_id", nullable=True, required=False),
    uuid_column("debt_id", nullable=True, required=False),
)


def transaction_problem(row: Row) -> str | None:
    if not moment_ok(row["occurred_at"]):
        return "occurred_at must not be before 2015-01-01"
    kind = row["kind"]
    if kind == "transfer":
        if row["to_account_id"] is None:
            return "a transfer needs to_account_id"
        if row["to_account_id"] == row["account_id"]:
            return "a transfer needs two different accounts"
        for name in ("category_id", "work_payment_id", "debt_id"):
            if row[name] is not None:
                return f"a transfer cannot have {name}"
    elif row["to_account_id"] is not None:
        return "only a transfer has to_account_id"
    if row["work_payment_id"] is not None and kind != "income":
        return "a work payment link is only for an income"
    if (row["source"] == "work_payment") != (row["work_payment_id"] is not None):
        return "source work_payment and work_payment_id go together"
    return None


# ------------------------------------------------------------------ balance_checkpoints

CHECKPOINT_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("account_id", "accounts", immutable=True),
    datetime_column("checked_at"),
    _money("actual_balance", signed=True, required=True),
    enum_column("source", CHECKPOINT_SOURCES),
    text_column("note", max_length=500, nullable=True, required=False),
)


def checkpoint_problem(row: Row) -> str | None:
    if not moment_ok(row["checked_at"]):
        return "checked_at must not be before 2015-01-01"
    return None


# ------------------------------------------------------------------ debts, repayments

DEBT_COLUMNS: tuple[ColumnSpec, ...] = (
    enum_column("direction", DEBT_DIRECTIONS),
    uuid_column("person_id", nullable=True, required=False),
    text_column("counterparty", max_length=200, nullable=True, required=False),
    _money("amount", positive=True, required=True),
    _date("debt_date", required=True),
    _date("due_date"),
    text_column("comment", max_length=2000, nullable=True, required=False),
)


def debt_problem(row: Row) -> str | None:
    if row["person_id"] is None and (row["counterparty"] is None or _blank(row["counterparty"])):
        return "a debt needs person_id or a counterparty"
    if parse_date(row["debt_date"]) is None:
        return "debt_date must be a real date"
    if row["due_date"] is not None:
        if parse_date(row["due_date"]) is None:
            return "due_date must be a real date"
        if row["due_date"] < row["debt_date"]:
            return "due_date must not be before debt_date"
    return None


REPAYMENT_COLUMNS: tuple[ColumnSpec, ...] = (
    reference_column("debt_id", "debts", immutable=True),
    _money("amount", positive=True, required=True),
    _date("repaid_on", required=True),
    uuid_column("transaction_id", nullable=True, required=False),
    text_column("note", max_length=500, nullable=True, required=False),
)


def repayment_problem(row: Row) -> str | None:
    if parse_date(row["repaid_on"]) is None:
        return "repaid_on must be a real date"
    return None


# ------------------------------------------------------------------ goals

GOAL_COLUMNS: tuple[ColumnSpec, ...] = (
    text_column("name", min_length=1, max_length=200),
    _money("target_amount", positive=True, required=True),
    _date("deadline_date"),
    json_column("formula", max_bytes=8192),
    bool_column("archived"),
)

_TERM_KEYS = {
    "accounts": {"kind", "sign", "account_ids"},
    "all_accounts": {"kind", "sign"},
    "debts_to_me": {"kind", "sign"},
    "my_debts": {"kind", "sign"},
    "receivables": {"kind", "sign", "client_ids"},
}


def _ids_problem(name: str, value: object, *, nullable: bool) -> str | None:
    if value is None:
        return None if nullable else f"{name} is required"
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_TERM_IDS:
        return f"{name} must be a list of 1..{MAX_TERM_IDS} ids"
    for item in value:
        try:
            canonical = isinstance(item, str) and str(uuid.UUID(item)) == item
        except ValueError:
            canonical = False
        if not canonical:
            return f"{name} must hold lowercase uuids"
    return None


def formula_problem(value: object) -> str | None:
    """A formula is a list of 1..30 terms ``{"kind", "sign", [account_ids | client_ids]}``."""
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_GOAL_TERMS:
        return f"formula must be a list of 1..{MAX_GOAL_TERMS} terms"
    for term in value:
        if not isinstance(term, dict) or term.get("kind") not in GOAL_TERM_KINDS:
            return "a term needs a known kind"
        if set(term) - _TERM_KEYS[term["kind"]] or term.get("sign") not in GOAL_SIGNS:
            return "a term has only its own keys and a sign of + or -"
        if term["kind"] == "accounts":
            problem = _ids_problem("account_ids", term.get("account_ids"), nullable=False)
        elif term["kind"] == "receivables":
            problem = _ids_problem("client_ids", term.get("client_ids"), nullable=True)
        else:
            problem = None
        if problem:
            return problem
    return None


def goal_problem(row: Row) -> str | None:
    if _blank(row["name"]):
        return "name must not be blank"
    if row["deadline_date"] is not None and parse_date(row["deadline_date"]) is None:
        return "deadline_date must be a real date"
    return formula_problem(row["formula"])
