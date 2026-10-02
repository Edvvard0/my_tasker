"""Builds ``shared-test-vectors/finance/*.json``: inputs are written here, expected values come
from the reference implementation (``tasker.finance.reference``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.finance_vectors_gen``. A test checks that the
files on disk are exactly this output.
"""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

from tasker.finance import reference as ref
from tasker.finance.presets import PRESETS, category_id
from tasker.work import reference as work

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "finance"
Case = tuple[str, dict[str, Any]]  # (name, input)
RUB = 100  # kopecks


def acc(aid: str, opening: int = 0, day: str = "2026-01-01", **over: Any) -> dict[str, Any]:
    return {
        "id": aid,
        "kind": "debit_card",
        "opening_balance": opening,
        "opening_date": day,
        "include_in_total": True,
        "archived": False,
        **over,
    }


def tx(tid: str, kind: str, account: str, amount: int, at: str, **over: Any) -> dict[str, Any]:
    return {
        "id": tid,
        "kind": kind,
        "account_id": account,
        "to_account_id": None,
        "amount": amount,
        "occurred_at": at,
        "category_id": None,
        "merchant": None,
        "status": "confirmed",
        "external_id": None,
        "dedup_hash": None,
        "work_payment_id": None,
        "debt_id": None,
        **over,
    }


def transfer(tid: str, src: str, dst: str, amount: int, at: str, **over: Any) -> dict[str, Any]:
    return tx(tid, "transfer", src, amount, at, to_account_id=dst, **over)


def cp(cid: str, account: str, at: str, actual: int) -> dict[str, Any]:
    return {"id": cid, "account_id": account, "checked_at": at, "actual_balance": actual}


def cat(cid: str, kind: str = "expense", parent: str | None = None) -> dict[str, Any]:
    return {"id": cid, "kind": kind, "parent_id": parent}


def debt(did: str, direction: str, amount: int, due: str | None = None) -> dict[str, Any]:
    return {"id": did, "direction": direction, "amount": amount, "due_date": due}


def repay(rid: str, debt_id: str, amount: int, transaction: str | None = None) -> dict[str, Any]:
    return {"id": rid, "debt_id": debt_id, "amount": amount, "transaction_id": transaction}


def proj(pid: str, base: int, client: str | None = None, **over: Any) -> dict[str, Any]:
    return {"id": pid, "base_amount": base, "status": "active", "client_id": client, **over}


def goal(target: int, *terms: dict[str, Any]) -> dict[str, Any]:
    return {"id": "g", "target_amount": target, "formula": list(terms)}


def term(kind: str, sign: str = "+", **extra: Any) -> dict[str, Any]:
    return {"kind": kind, "sign": sign, **extra}


# ------------------------------------------------------------------ scalars

T = "2026-10-05T09:00:00Z"
SCALARS: list[Case] = [
    ("progress_zero_have", {"op": "progress_bp", "have": 0, "target": 400_000 * RUB}),
    ("progress_negative_have", {"op": "progress_bp", "have": -5, "target": 100}),
    ("progress_half", {"op": "progress_bp", "have": 50_000, "target": 100_000}),
    ("progress_third_floors", {"op": "progress_bp", "have": 1, "target": 3}),
    (
        "progress_excel_over_target",
        {"op": "progress_bp", "have": 454_600 * RUB, "target": 400_000 * RUB},
    ),
    ("progress_almost_not_100", {"op": "progress_bp", "have": 99_999, "target": 100_000}),
    ("progress_zero_target", {"op": "progress_bp", "have": 10, "target": 0}),
    (
        "progress_huge",
        {"op": "progress_bp", "have": 99_999_999_999_998, "target": 99_999_999_999_999},
    ),
    ("opening_instant_plain", {"op": "opening_instant", "date": "2026-10-01"}),
    ("opening_instant_new_year", {"op": "opening_instant", "date": "2026-01-01"}),
    ("opening_instant_leap_day", {"op": "opening_instant", "date": "2028-02-29"}),
    ("end_of_day_plain", {"op": "end_of_day", "date": "2026-10-01"}),
    ("end_of_day_new_year_eve", {"op": "end_of_day", "date": "2026-12-31"}),
    ("month_end_february", {"op": "month_end", "month": "2026-02"}),
    ("month_end_leap_february", {"op": "month_end", "month": "2028-02"}),
    ("month_end_april", {"op": "month_end", "month": "2026-04"}),
    ("month_end_december", {"op": "month_end", "month": "2026-12"}),
    ("month_end_january", {"op": "month_end", "month": "2026-01"}),
    ("moscow_month_last_second_of_september", {"op": "moscow_month", "at": "2026-09-30T20:59:59Z"}),
    ("moscow_month_first_second_of_october", {"op": "moscow_month", "at": "2026-09-30T21:00:00Z"}),
    ("fold_merchant_trims_and_collapses", {"op": "fold_merchant", "text": "  Пятёрочка   №12 "}),
    ("fold_merchant_cyrillic_capitals", {"op": "fold_merchant", "text": "ЛЕНТА Ёлки"}),
    ("fold_merchant_nbsp_and_tab", {"op": "fold_merchant", "text": "Яндекс Go\t Такси"}),
    ("fold_merchant_ascii", {"op": "fold_merchant", "text": "McDonald's"}),
    ("fold_merchant_other_scripts_untouched", {"op": "fold_merchant", "text": "ÄB ΣΑΣ"}),
    (
        "dedup_key_external_id",
        {"op": "dedup_key", "transaction": tx("t", "expense", "a1", 1, T, external_id="X-1")},
    ),
    (
        "dedup_key_hash",
        {"op": "dedup_key", "transaction": tx("t", "expense", "a1", 1, T, dedup_hash="ab" * 16)},
    ),
    (
        "dedup_key_external_id_wins_over_hash",
        {
            "op": "dedup_key",
            "transaction": tx("t", "expense", "a1", 1, T, external_id="X", dedup_hash="ab" * 16),
        },
    ),
    ("dedup_key_none", {"op": "dedup_key", "transaction": tx("t", "expense", "a1", 1, T)}),
    (
        "effect_expense",
        {"op": "effect", "transaction": tx("t", "expense", "a1", 500, T), "account_id": "a1"},
    ),
    (
        "effect_expense_other_account",
        {"op": "effect", "transaction": tx("t", "expense", "a1", 500, T), "account_id": "a2"},
    ),
    (
        "effect_income",
        {"op": "effect", "transaction": tx("t", "income", "a1", 500, T), "account_id": "a1"},
    ),
    (
        "effect_transfer_source",
        {"op": "effect", "transaction": transfer("t", "a1", "a2", 500, T), "account_id": "a1"},
    ),
    (
        "effect_transfer_destination",
        {"op": "effect", "transaction": transfer("t", "a1", "a2", 500, T), "account_id": "a2"},
    ),
    (
        "effect_transfer_third_account",
        {"op": "effect", "transaction": transfer("t", "a1", "a2", 500, T), "account_id": "a3"},
    ),
    (
        "effect_draft_is_nothing",
        {
            "op": "effect",
            "transaction": tx("t", "income", "a1", 500, T, status="draft"),
            "account_id": "a1",
        },
    ),
    (
        "effect_needs_review_is_nothing",
        {
            "op": "effect",
            "transaction": tx("t", "expense", "a1", 500, T, status="needs_review"),
            "account_id": "a1",
        },
    ),
]


def _stamp(moment: Any) -> str:
    return str(moment.strftime("%Y-%m-%dT%H:%M:%SZ"))


SCALAR_OPS: dict[str, Callable[[dict[str, Any]], Any]] = {
    "progress_bp": lambda g: ref.progress_basis_points(g["have"], g["target"]),
    "opening_instant": lambda g: _stamp(ref.opening_instant(g["date"])),
    "end_of_day": lambda g: _stamp(ref.end_of_day(g["date"])),
    "month_end": lambda g: ref.month_end(g["month"]),
    "moscow_month": lambda g: work.moscow_month(g["at"]),
    "fold_merchant": lambda g: ref.fold_merchant(g["text"]),
    "dedup_key": lambda g: ref.dedup_key(g["transaction"]),
    "effect": lambda g: ref.effect(g["transaction"], g["account_id"]),
}


def run_scalar(given: dict[str, Any]) -> Any:
    return SCALAR_OPS[given["op"]](given)


# ------------------------------------------------------------------ balances

A1, A2 = acc("a1", 100_000), acc("a2", 50_000)
BALANCES: list[Case] = [
    (
        "opening_only",
        {"accounts": [acc("a1", 100_000)], "transactions": [], "checkpoints": [], "at": None},
    ),
    (
        "income_and_expense",
        {
            "accounts": [A1],
            "transactions": [
                tx("t1", "income", "a1", 30_000, "2026-03-01T09:00:00Z"),
                tx("t2", "expense", "a1", 12_345, "2026-03-02T09:00:00Z"),
            ],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "transfer_moves_money_between_accounts",
        {
            "accounts": [A1, A2],
            "transactions": [transfer("t1", "a1", "a2", 40_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "transfer_to_an_account_outside_the_total",
        {
            "accounts": [A1, acc("a2", 50_000, include_in_total=False, kind="savings")],
            "transactions": [transfer("t1", "a1", "a2", 40_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "draft_is_not_in_the_balance",
        {
            "accounts": [A1],
            "transactions": [
                tx("t1", "income", "a1", 30_000, "2026-03-01T09:00:00Z", status="draft")
            ],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "needs_review_is_not_in_the_balance",
        {
            "accounts": [A1],
            "transactions": [
                tx("t1", "expense", "a1", 30_000, "2026-03-01T09:00:00Z", status="needs_review")
            ],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "checkpoint_replaces_what_came_before",
        {
            "accounts": [A1],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 77_000)],
            "at": None,
        },
    ),
    (
        "transactions_after_a_checkpoint_count",
        {
            "accounts": [A1],
            "transactions": [
                tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z"),
                tx("t2", "expense", "a1", 2_000, "2026-03-06T09:00:00Z"),
                transfer("t3", "a2", "a1", 500, "2026-03-07T09:00:00Z"),
            ],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 77_000)],
            "at": None,
        },
    ),
    (
        "transaction_at_the_checkpoint_instant_is_already_in_it",
        {
            "accounts": [A1],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-03-05T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 77_000)],
            "at": None,
        },
    ),
    (
        "transaction_before_the_opening_is_ignored",
        {
            "accounts": [acc("a1", 100_000, day="2026-10-01")],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-09-30T20:59:59Z")],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "transaction_at_the_opening_instant_counts",
        {
            "accounts": [acc("a1", 100_000, day="2026-10-01")],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-09-30T21:00:00Z")],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "before_the_opening_the_account_holds_nothing",
        {
            "accounts": [acc("a1", 100_000, day="2026-10-01")],
            "transactions": [],
            "checkpoints": [],
            "at": "2026-09-30T20:59:59Z",
        },
    ),
    (
        "as_of_a_moment_in_the_middle",
        {
            "accounts": [A1],
            "transactions": [
                tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z"),
                tx("t2", "expense", "a1", 5_000, "2026-03-10T09:00:00Z"),
            ],
            "checkpoints": [],
            "at": "2026-03-05T00:00:00Z",
        },
    ),
    (
        "as_of_ignores_a_later_checkpoint",
        {
            "accounts": [A1],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-10T09:00:00Z", 1)],
            "at": "2026-03-05T00:00:00Z",
        },
    ),
    (
        "latest_checkpoint_wins",
        {
            "accounts": [A1],
            "transactions": [tx("t1", "income", "a1", 100, "2026-03-20T09:00:00Z")],
            "checkpoints": [
                cp("c2", "a1", "2026-03-15T09:00:00Z", 60_000),
                cp("c1", "a1", "2026-03-05T09:00:00Z", 77_000),
            ],
            "at": None,
        },
    ),
    (
        "checkpoints_at_one_instant_the_greater_id_wins",
        {
            "accounts": [A1],
            "transactions": [],
            "checkpoints": [
                cp("c1", "a1", "2026-03-05T09:00:00Z", 11),
                cp("c2", "a1", "2026-03-05T09:00:00Z", 22),
            ],
            "at": None,
        },
    ),
    (
        "checkpoint_before_the_opening_is_ignored",
        {
            "accounts": [acc("a1", 100_000, day="2026-10-01")],
            "transactions": [],
            "checkpoints": [cp("c1", "a1", "2026-09-01T09:00:00Z", 5)],
            "at": None,
        },
    ),
    (
        "checkpoint_of_another_account_is_ignored",
        {
            "accounts": [A1, A2],
            "transactions": [],
            "checkpoints": [cp("c1", "a2", "2026-03-05T09:00:00Z", 5)],
            "at": None,
        },
    ),
    (
        "credit_card_is_a_balance_and_may_go_negative",
        {
            "accounts": [acc("cc", 0, kind="credit_card", credit_limit=300_000 * RUB)],
            "transactions": [
                tx("t1", "expense", "cc", 150_000, "2026-03-01T09:00:00Z"),
                tx("t2", "income", "cc", 40_000, "2026-03-02T09:00:00Z"),
            ],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "total_skips_accounts_outside_it_but_lists_them",
        {
            "accounts": [A1, acc("a2", 50_000, include_in_total=False)],
            "transactions": [],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "archived_account_still_counts",
        {
            "accounts": [A1, acc("a2", 50_000, archived=True)],
            "transactions": [],
            "checkpoints": [],
            "at": None,
        },
    ),
    (
        "negative_opening_balance",
        {"accounts": [acc("a1", -25_000)], "transactions": [], "checkpoints": [], "at": None},
    ),
    (
        "fractions_of_a_second_do_not_move_a_transaction_across_the_checkpoint",
        {
            "accounts": [A1],
            "transactions": [tx("t1", "expense", "a1", 1_000, "2026-03-05T09:00:00.900Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 50_000)],
            "at": None,
        },
    ),
]


def run_balances(g: dict[str, Any]) -> Any:
    return ref.account_balances(g["accounts"], g["transactions"], g["checkpoints"], g["at"])


# ------------------------------------------------------------------ adjustments

ADJUSTMENTS: list[Case] = [
    ("no_checkpoints", {"account": A1, "transactions": [], "checkpoints": []}),
    (
        "checkpoint_matches_the_books",
        {
            "account": A1,
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 90_000)],
        },
    ),
    (
        "bank_shows_more_than_the_books",
        {
            "account": acc("a1", 174_000 * RUB - 800 * RUB),
            "transactions": [],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 174_000 * RUB)],
        },
    ),
    (
        "bank_shows_less_than_the_books",
        {
            "account": A1,
            "transactions": [],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 99_000)],
        },
    ),
    (
        "second_checkpoint_starts_from_the_first",
        {
            "account": A1,
            "transactions": [
                tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z"),
                tx("t2", "income", "a1", 3_000, "2026-03-08T09:00:00Z"),
                tx("t3", "expense", "a1", 500, "2026-03-20T09:00:00Z"),
            ],
            "checkpoints": [
                cp("c2", "a1", "2026-03-10T09:00:00Z", 94_000),
                cp("c1", "a1", "2026-03-05T09:00:00Z", 91_000),
            ],
        },
    ),
    (
        "draft_does_not_explain_a_gap",
        {
            "account": A1,
            "transactions": [
                tx("t1", "expense", "a1", 10_000, "2026-03-01T09:00:00Z", status="draft")
            ],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 90_000)],
        },
    ),
    (
        "checkpoint_before_the_opening_is_not_listed",
        {
            "account": acc("a1", 100_000, day="2026-10-01"),
            "transactions": [],
            "checkpoints": [cp("c1", "a1", "2026-09-01T09:00:00Z", 5)],
        },
    ),
    (
        "checkpoints_at_one_instant_are_ordered_by_id",
        {
            "account": A1,
            "transactions": [],
            "checkpoints": [
                cp("c2", "a1", "2026-03-05T09:00:00Z", 95_000),
                cp("c1", "a1", "2026-03-05T09:00:00Z", 90_000),
            ],
        },
    ),
    (
        "transfer_in_explains_the_gap",
        {
            "account": A1,
            "transactions": [transfer("t1", "a2", "a1", 7_000, "2026-03-01T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-03-05T09:00:00Z", 107_000)],
        },
    ),
]


def run_adjustments(g: dict[str, Any]) -> Any:
    return ref.adjustments(g["account"], g["transactions"], g["checkpoints"])


# ------------------------------------------------------------------ monthly

MONTHLY: list[Case] = [
    ("empty", {"transactions": [], "account_ids": None, "period": None}),
    (
        "income_and_expense_in_one_month",
        {
            "transactions": [
                tx("t1", "income", "a1", 100_000, "2026-10-02T09:00:00Z"),
                tx("t2", "expense", "a1", 30_000, "2026-10-03T09:00:00Z"),
                tx("t3", "expense", "a1", 5_050, "2026-10-04T09:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "transfers_are_never_income_or_expense",
        {
            "transactions": [
                transfer("t1", "a1", "a2", 90_000, "2026-10-02T09:00:00Z"),
                tx("t2", "expense", "a1", 1_000, "2026-10-03T09:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "a_month_of_transfers_only_is_absent",
        {
            "transactions": [transfer("t1", "a1", "a2", 90_000, "2026-10-02T09:00:00Z")],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "drafts_and_needs_review_are_excluded",
        {
            "transactions": [
                tx("t1", "expense", "a1", 1_000, "2026-10-02T09:00:00Z", status="draft"),
                tx("t2", "income", "a1", 2_000, "2026-10-02T09:00:00Z", status="needs_review"),
                tx("t3", "expense", "a1", 300, "2026-10-02T09:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "debt_movements_are_not_income_or_expense",
        {
            "transactions": [
                tx("t1", "expense", "a1", 50_000, "2026-10-02T09:00:00Z", debt_id="d1"),
                tx("t2", "income", "a1", 20_000, "2026-10-05T09:00:00Z", debt_id="d1"),
                tx("t3", "expense", "a1", 300, "2026-10-06T09:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "month_boundary_in_moscow_september",
        {
            "transactions": [tx("t1", "expense", "a1", 100, "2026-09-30T20:59:59Z")],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "month_boundary_in_moscow_october",
        {
            "transactions": [tx("t1", "expense", "a1", 100, "2026-09-30T21:00:00Z")],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "year_boundary",
        {
            "transactions": [
                tx("t1", "expense", "a1", 100, "2026-12-31T20:59:59Z"),
                tx("t2", "expense", "a1", 200, "2026-12-31T21:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "months_come_ascending_whatever_the_input_order",
        {
            "transactions": [
                tx("t1", "income", "a1", 100, "2026-11-10T09:00:00Z"),
                tx("t2", "income", "a1", 200, "2026-08-10T09:00:00Z"),
                tx("t3", "expense", "a1", 50, "2026-10-10T09:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
    (
        "account_filter",
        {
            "transactions": [
                tx("t1", "expense", "a1", 100, "2026-10-02T09:00:00Z"),
                tx("t2", "expense", "a2", 700, "2026-10-02T09:00:00Z"),
                tx("t3", "income", "a3", 5_000, "2026-10-02T09:00:00Z"),
            ],
            "account_ids": ["a1", "a2"],
            "period": None,
        },
    ),
    (
        "period_cuts_a_month_in_the_middle",
        {
            "transactions": [
                tx("t1", "expense", "a1", 100, "2026-10-09T20:59:59Z"),
                tx("t2", "expense", "a1", 700, "2026-10-09T21:00:00Z"),
                tx("t3", "expense", "a1", 5_000, "2026-10-20T09:00:00Z"),
            ],
            "account_ids": None,
            "period": {"from": "2026-10-10", "to": "2026-10-20"},
        },
    ),
    (
        "net_may_be_negative",
        {
            "transactions": [
                tx("t1", "income", "a1", 100, "2026-10-09T09:00:00Z"),
                tx("t2", "expense", "a1", 700, "2026-10-09T10:00:00Z"),
            ],
            "account_ids": None,
            "period": None,
        },
    ),
]


def run_monthly(g: dict[str, Any]) -> Any:
    return ref.monthly_totals(g["transactions"], g["account_ids"], g["period"])


# ------------------------------------------------------------------ categories

FOOD, CAFE, TAXI, CAR, SALARY = "c-food", "c-cafe", "c-taxi", "c-car", "c-salary"
CATS = [
    cat(FOOD),
    cat(CAFE, parent=FOOD),
    cat(CAR),
    cat(TAXI, parent=CAR),
    cat(SALARY, "income"),
]


def spend(tid: str, amount: int, category: str | None, at: str = "2026-10-05T09:00:00Z") -> Any:
    return tx(tid, "expense", "a1", amount, at, category_id=category)


CATEGORY_CASES: list[Case] = [
    ("empty", {"transactions": [], "categories": CATS, "kind": "expense", "period": None}),
    (
        "children_roll_up_into_the_parent",
        {
            "transactions": [
                spend("t1", 1_000, FOOD),
                spend("t2", 400, CAFE),
                spend("t3", 250, CAFE),
            ],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "groups_are_ordered_by_total_then_children_by_total",
        {
            "transactions": [
                spend("t1", 100, FOOD),
                spend("t2", 900, CAR),
                spend("t3", 300, TAXI),
                spend("t4", 200, CAFE),
                spend("t5", 700, TAXI),
            ],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "uncategorised_is_its_own_group_and_goes_last_on_a_tie",
        {
            "transactions": [spend("t1", 500, None), spend("t2", 500, FOOD)],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "unknown_or_deleted_category_counts_as_uncategorised",
        {
            "transactions": [spend("t1", 300, "c-gone"), spend("t2", 200, None)],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "child_without_a_live_parent_stands_alone",
        {
            "transactions": [spend("t1", 300, CAFE)],
            "categories": [cat(CAFE, parent=FOOD)],
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "equal_totals_are_ordered_by_id",
        {
            "transactions": [spend("t1", 100, CAR), spend("t2", 100, FOOD)],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "income_kind",
        {
            "transactions": [
                tx("t1", "income", "a1", 5_000, "2026-10-05T09:00:00Z", category_id=SALARY),
                spend("t2", 100, FOOD),
            ],
            "categories": CATS,
            "kind": "income",
            "period": None,
        },
    ),
    (
        "transfers_drafts_and_debt_movements_are_left_out",
        {
            "transactions": [
                transfer("t1", "a1", "a2", 9_000, "2026-10-05T09:00:00Z"),
                tx(
                    "t2",
                    "expense",
                    "a1",
                    800,
                    "2026-10-05T09:00:00Z",
                    category_id=FOOD,
                    status="draft",
                ),
                tx(
                    "t3",
                    "expense",
                    "a1",
                    700,
                    "2026-10-05T09:00:00Z",
                    category_id=FOOD,
                    debt_id="d",
                ),
                spend("t4", 10, FOOD),
            ],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
    (
        "period_in_moscow_dates",
        {
            "transactions": [
                spend("t1", 1, FOOD, "2026-10-09T20:59:59Z"),
                spend("t2", 10, FOOD, "2026-10-09T21:00:00Z"),
                spend("t3", 100, FOOD, "2026-10-10T20:59:59Z"),
                spend("t4", 1_000, FOOD, "2026-10-10T21:00:00Z"),
            ],
            "categories": CATS,
            "kind": "expense",
            "period": {"from": "2026-10-10", "to": "2026-10-10"},
        },
    ),
    (
        "category_of_the_other_kind_is_grouped_as_recorded",
        {
            "transactions": [spend("t1", 100, SALARY)],
            "categories": CATS,
            "kind": "expense",
            "period": None,
        },
    ),
]


def run_categories(g: dict[str, Any]) -> Any:
    return ref.category_breakdown(g["transactions"], g["categories"], g["kind"], g["period"])


# ------------------------------------------------------------------ merchants


def shop(tid: str, amount: int, merchant: str | None, at: str = "2026-10-05T09:00:00Z") -> Any:
    return tx(tid, "expense", "a1", amount, at, merchant=merchant)


MERCHANTS: list[Case] = [
    ("empty", {"transactions": [], "kind": "expense", "period": None, "limit": 10}),
    (
        "same_shop_in_different_spellings_is_one",
        {
            "transactions": [
                shop("t1", 100, "Пятёрочка"),
                shop("t2", 250, "ПЯТЁРОЧКА", "2026-10-06T09:00:00Z"),
                shop("t3", 50, "  пятёрочка  ", "2026-10-07T09:00:00Z"),
            ],
            "kind": "expense",
            "period": None,
            "limit": 10,
        },
    ),
    (
        "shown_spelling_is_the_earliest",
        {
            "transactions": [
                shop("t2", 1, "ЛЕНТА", "2026-10-06T09:00:00Z"),
                shop("t1", 1, "Лента", "2026-10-05T09:00:00Z"),
            ],
            "kind": "expense",
            "period": None,
            "limit": 10,
        },
    ),
    (
        "blank_and_missing_merchants_are_skipped",
        {
            "transactions": [shop("t1", 100, None), shop("t2", 100, "   "), shop("t3", 5, "Кофе")],
            "kind": "expense",
            "period": None,
            "limit": 10,
        },
    ),
    (
        "limit_keeps_the_biggest",
        {
            "transactions": [shop("t1", 100, "A"), shop("t2", 300, "B"), shop("t3", 200, "C")],
            "kind": "expense",
            "period": None,
            "limit": 2,
        },
    ),
    (
        "tie_on_total_goes_to_more_purchases_then_name",
        {
            "transactions": [
                shop("t1", 100, "Бета"),
                shop("t2", 50, "Альфа"),
                shop("t3", 50, "Альфа"),
                shop("t4", 100, "Аз"),
            ],
            "kind": "expense",
            "period": None,
            "limit": 10,
        },
    ),
    (
        "period_filter",
        {
            "transactions": [
                shop("t1", 100, "A", "2026-10-09T20:59:59Z"),
                shop("t2", 200, "A", "2026-10-09T21:00:00Z"),
            ],
            "kind": "expense",
            "period": {"from": "2026-10-10", "to": None},
            "limit": 10,
        },
    ),
    (
        "income_kind",
        {
            "transactions": [
                tx("t1", "income", "a1", 700, "2026-10-05T09:00:00Z", merchant="ООО Ромашка"),
                shop("t2", 100, "Лента"),
            ],
            "kind": "income",
            "period": None,
            "limit": 10,
        },
    ),
    (
        "transfers_and_drafts_do_not_count",
        {
            "transactions": [
                transfer("t1", "a1", "a2", 500, "2026-10-05T09:00:00Z", merchant="Сбер"),
                tx(
                    "t2",
                    "expense",
                    "a1",
                    500,
                    "2026-10-05T09:00:00Z",
                    merchant="Сбер",
                    status="draft",
                ),
            ],
            "kind": "expense",
            "period": None,
            "limit": 10,
        },
    ),
]


def run_merchants(g: dict[str, Any]) -> Any:
    return ref.top_merchants(g["transactions"], g["kind"], g["period"], g["limit"])


# ------------------------------------------------------------------ dynamics

DYNAMICS: list[Case] = [
    (
        "month_ends_with_an_account_opened_later",
        {
            "accounts": [acc("a1", 100_000, day="2026-01-01"), acc("a2", 50_000, day="2026-03-15")],
            "transactions": [tx("t1", "expense", "a1", 10_000, "2026-02-10T09:00:00Z")],
            "checkpoints": [],
            "dates": ["2026-01-31", "2026-02-28", "2026-03-31"],
        },
    ),
    (
        "a_transaction_on_the_last_evening_belongs_to_that_day",
        {
            "accounts": [acc("a1", 100_000)],
            "transactions": [
                tx("t1", "expense", "a1", 1_000, "2026-01-31T20:59:59Z"),
                tx("t2", "expense", "a1", 20_000, "2026-01-31T21:00:00Z"),
            ],
            "checkpoints": [],
            "dates": ["2026-01-31", "2026-02-28"],
        },
    ),
    (
        "a_checkpoint_in_the_middle_resets_the_line",
        {
            "accounts": [acc("a1", 100_000)],
            "transactions": [tx("t1", "expense", "a1", 1_000, "2026-02-10T09:00:00Z")],
            "checkpoints": [cp("c1", "a1", "2026-02-15T09:00:00Z", 70_000)],
            "dates": ["2026-01-31", "2026-02-14", "2026-02-15", "2026-02-28"],
        },
    ),
    (
        "accounts_outside_the_total_are_not_summed",
        {
            "accounts": [acc("a1", 100_000), acc("a2", 50_000, include_in_total=False)],
            "transactions": [transfer("t1", "a1", "a2", 40_000, "2026-02-10T09:00:00Z")],
            "checkpoints": [],
            "dates": ["2026-01-31", "2026-02-28"],
        },
    ),
    (
        "no_dates",
        {"accounts": [acc("a1", 100_000)], "transactions": [], "checkpoints": [], "dates": []},
    ),
]


def run_dynamics(g: dict[str, Any]) -> Any:
    return ref.balance_dynamics(g["accounts"], g["transactions"], g["checkpoints"], g["dates"])


# ------------------------------------------------------------------ debts

DEBTS: list[Case] = [
    ("no_debts", {"debts": [], "repayments": [], "today": "2026-10-05"}),
    (
        "open_debt",
        {
            "debts": [debt("d1", "owed_to_me", 10_000)],
            "repayments": [],
            "today": "2026-10-05",
        },
    ),
    (
        "partly_repaid",
        {
            "debts": [debt("d1", "owed_to_me", 10_000)],
            "repayments": [repay("r1", "d1", 3_000), repay("r2", "d1", 1_500)],
            "today": "2026-10-05",
        },
    ),
    (
        "fully_repaid_is_closed",
        {
            "debts": [debt("d1", "i_owe", 10_000)],
            "repayments": [repay("r1", "d1", 6_000), repay("r2", "d1", 4_000)],
            "today": "2026-10-05",
        },
    ),
    (
        "over_repaid_is_closed_with_a_surplus",
        {
            "debts": [debt("d1", "i_owe", 10_000)],
            "repayments": [repay("r1", "d1", 10_001)],
            "today": "2026-10-05",
        },
    ),
    (
        "due_yesterday_is_overdue",
        {
            "debts": [debt("d1", "owed_to_me", 10_000, "2026-10-04")],
            "repayments": [],
            "today": "2026-10-05",
        },
    ),
    (
        "due_today_is_not_overdue",
        {
            "debts": [debt("d1", "owed_to_me", 10_000, "2026-10-05")],
            "repayments": [],
            "today": "2026-10-05",
        },
    ),
    (
        "a_closed_debt_is_never_overdue",
        {
            "debts": [debt("d1", "owed_to_me", 10_000, "2026-01-01")],
            "repayments": [repay("r1", "d1", 10_000)],
            "today": "2026-10-05",
        },
    ),
    (
        "no_today_means_no_overdue",
        {
            "debts": [debt("d1", "owed_to_me", 10_000, "2026-01-01")],
            "repayments": [],
            "today": None,
        },
    ),
    (
        "totals_per_direction_and_foreign_repayments_ignored",
        {
            "debts": [
                debt("d1", "owed_to_me", 750_000),
                debt("d2", "owed_to_me", 260_000),
                debt("d3", "owed_to_me", 300_000),
                debt("d4", "i_owe", 1_000_000),
            ],
            "repayments": [
                repay("r1", "d2", 60_000),
                repay("r2", "d4", 250_000),
                repay("r3", "gone", 999_999),
            ],
            "today": "2026-10-05",
        },
    ),
]


def run_debts(g: dict[str, Any]) -> Any:
    return ref.debts_summary(g["debts"], g["repayments"], g["today"])


# ------------------------------------------------------------------ goals

R = RUB
EXCEL_ACCOUNTS = [
    acc("a-cash", 54_000 * R, kind="cash"),
    acc("a-card", 174_000 * R),
    acc("a-save", 8_000 * R, kind="savings"),
    acc("a-credit", 125_000 * R, kind="credit_card", credit_limit=300_000 * R),
]
EXCEL_DEBTS = [
    debt("d1", "owed_to_me", 7_500 * R),
    debt("d2", "owed_to_me", 2_600 * R),
    debt("d3", "owed_to_me", 3_000 * R),
]
EXCEL_PROJECTS = [proj("p1", 20_000 * R, "roma"), proj("p2", 60_500 * R, "roma")]
DEFAULT_FORMULA = (term("all_accounts"), term("debts_to_me"), term("receivables", client_ids=None))


def goal_case(
    target: int,
    *terms: dict[str, Any],
    accounts: list[dict[str, Any]] | None = None,
    debts_: list[dict[str, Any]] | None = None,
    repayments: list[dict[str, Any]] | None = None,
    projects: list[dict[str, Any]] | None = None,
    allocations: list[dict[str, Any]] | None = None,
    transactions: list[dict[str, Any]] | None = None,
    checkpoints: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "goal": goal(target, *terms),
        "accounts": EXCEL_ACCOUNTS if accounts is None else accounts,
        "transactions": transactions or [],
        "checkpoints": checkpoints or [],
        "debts": EXCEL_DEBTS if debts_ is None else debts_,
        "repayments": repayments or [],
        "projects": EXCEL_PROJECTS if projects is None else projects,
        "change_requests": [],
        "allocations": allocations or [],
    }


GOALS: list[Case] = [
    (
        "excel_have_329600_without_the_credit_card",
        goal_case(
            400_000 * R,
            term("accounts", account_ids=["a-cash", "a-card", "a-save"]),
            term("debts_to_me"),
            term("receivables", client_ids=None),
        ),
    ),
    (
        "excel_default_formula_with_the_credit_card_have_454600_missing_minus_54600",
        goal_case(400_000 * R, *DEFAULT_FORMULA),
    ),
    (
        "excel_credit_card_outside_the_total_gives_329600_again",
        goal_case(
            400_000 * R,
            *DEFAULT_FORMULA,
            accounts=[*EXCEL_ACCOUNTS[:3], {**EXCEL_ACCOUNTS[3], "include_in_total": False}],
        ),
    ),
    (
        "excel_credit_card_added_as_its_own_term",
        goal_case(
            400_000 * R,
            term("accounts", account_ids=["a-cash", "a-card", "a-save"]),
            term("accounts", account_ids=["a-credit"]),
            term("debts_to_me"),
            term("receivables", client_ids=["roma"]),
        ),
    ),
    ("target_exactly_reached", goal_case(454_600 * R, *DEFAULT_FORMULA)),
    ("one_kopeck_short", goal_case(454_600 * R + 1, *DEFAULT_FORMULA)),
    (
        "my_debts_are_subtracted",
        goal_case(
            400_000 * R,
            *DEFAULT_FORMULA,
            term("my_debts", "-"),
            debts_=[*EXCEL_DEBTS, debt("d4", "i_owe", 10_000 * R)],
        ),
    ),
    (
        "repayments_shrink_debts_to_me",
        goal_case(
            400_000 * R,
            term("debts_to_me"),
            debts_=EXCEL_DEBTS,
            repayments=[repay("r1", "d1", 5_000 * R)],
        ),
    ),
    (
        "receivables_of_selected_customers_only",
        goal_case(
            100_000 * R,
            term("receivables", client_ids=["elena"]),
            projects=[*EXCEL_PROJECTS, proj("p3", 15_000 * R, "elena")],
        ),
    ),
    (
        "receivables_of_all_include_projects_without_a_customer",
        goal_case(
            100_000 * R,
            term("receivables", client_ids=None),
            projects=[proj("p1", 20_000 * R, "roma"), proj("p9", 5_000 * R, None)],
        ),
    ),
    (
        "receivables_follow_work_payments",
        goal_case(
            100_000 * R,
            term("receivables", client_ids=None),
            projects=[proj("p1", 20_000 * R, "roma")],
            allocations=[
                {
                    "id": "al1",
                    "payment_id": "pay1",
                    "project_id": "p1",
                    "change_request_id": None,
                    "amount": 12_000 * R,
                }
            ],
        ),
    ),
    (
        "an_account_listed_twice_in_one_term_counts_once",
        goal_case(
            100_000 * R,
            term("accounts", account_ids=["a-cash", "a-cash"]),
        ),
    ),
    (
        "a_deleted_account_in_a_term_counts_nothing",
        goal_case(100_000 * R, term("accounts", account_ids=["a-cash", "a-gone"])),
    ),
    (
        "minus_sign_on_accounts",
        goal_case(
            100_000 * R,
            term("accounts", account_ids=["a-cash"]),
            term("accounts", "-", account_ids=["a-save"]),
        ),
    ),
    (
        "have_below_zero_gives_zero_progress",
        goal_case(
            100_000 * R,
            term("accounts", "-", account_ids=["a-cash"]),
        ),
    ),
    (
        "balances_follow_transactions_and_checkpoints",
        goal_case(
            100_000 * R,
            term("all_accounts"),
            accounts=[acc("a1", 1_000 * R), acc("a2", 0)],
            transactions=[
                transfer("t1", "a1", "a2", 400 * R, "2026-03-01T09:00:00Z"),
                tx("t2", "income", "a2", 50 * R, "2026-03-02T09:00:00Z"),
                tx("t3", "income", "a2", 99_999 * R, "2026-03-02T09:00:00Z", status="draft"),
            ],
            checkpoints=[cp("c1", "a1", "2026-03-10T09:00:00Z", 500 * R)],
            debts_=[],
            projects=[],
        ),
    ),
]


def run_goals(g: dict[str, Any]) -> Any:
    return ref.goal_progress(
        g["goal"],
        g["accounts"],
        g["transactions"],
        g["checkpoints"],
        g["debts"],
        g["repayments"],
        g["projects"],
        g["change_requests"],
        g["allocations"],
    )


# ------------------------------------------------------------------ work links


def wpay(pid: str, amount: int) -> dict[str, Any]:
    return {"id": pid, "amount": amount, "paid_at": T}


def linked(tid: str, payment: str, amount: int, **over: Any) -> dict[str, Any]:
    return tx(
        tid,
        "income",
        "a1",
        amount,
        T,
        source="work_payment",
        work_payment_id=payment,
        **over,
    )


WORK_LINKS: list[Case] = [
    ("no_links", {"payments": [wpay("p1", 70_000)], "transactions": []}),
    (
        "fully_reflected",
        {"payments": [wpay("p1", 70_000)], "transactions": [linked("t1", "p1", 70_000)]},
    ),
    (
        "partly_reflected",
        {"payments": [wpay("p1", 70_000)], "transactions": [linked("t1", "p1", 20_000)]},
    ),
    (
        "split_over_two_accounts",
        {
            "payments": [wpay("p1", 70_000)],
            "transactions": [
                linked("t1", "p1", 50_000),
                {**linked("t2", "p1", 20_000), "account_id": "a2"},
            ],
        },
    ),
    (
        "over_linked_is_negative",
        {
            "payments": [wpay("p1", 70_000)],
            "transactions": [linked("t1", "p1", 70_000), linked("t2", "p1", 1)],
        },
    ),
    (
        "a_draft_is_not_yet_reflected",
        {
            "payments": [wpay("p1", 70_000)],
            "transactions": [linked("t1", "p1", 70_000, status="draft")],
        },
    ),
    (
        "other_payments_keep_their_own_numbers",
        {
            "payments": [wpay("p1", 10), wpay("p2", 20)],
            "transactions": [linked("t1", "p2", 20), tx("t2", "income", "a1", 5, T)],
        },
    ),
]


def run_work_links(g: dict[str, Any]) -> Any:
    return ref.work_payment_coverage(g["payments"], g["transactions"])


# ------------------------------------------------------------------ integrity


def integrity_case(**given: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "categories": [],
        "transactions": [],
        "debts": [],
        "repayments": [],
        "payments": [],
    }
    return {**base, **given}


INTEGRITY: list[Case] = [
    ("clean", integrity_case(categories=CATS, transactions=[spend("t1", 1, FOOD)])),
    (
        "duplicate_external_id_flags_the_later_ones",
        integrity_case(
            transactions=[
                tx("t3", "expense", "a1", 100, "2026-10-07T09:00:00Z", external_id="B1"),
                tx("t1", "expense", "a1", 100, "2026-10-05T09:00:00Z", external_id="B1"),
                tx("t2", "expense", "a1", 100, "2026-10-06T09:00:00Z", external_id="B1"),
            ]
        ),
    ),
    (
        "same_external_id_on_two_accounts_is_fine",
        integrity_case(
            transactions=[
                tx("t1", "expense", "a1", 100, T, external_id="B1"),
                tx("t2", "expense", "a2", 100, T, external_id="B1"),
            ]
        ),
    ),
    (
        "duplicate_hash",
        integrity_case(
            transactions=[
                tx("t1", "expense", "a1", 100, T, dedup_hash="cd" * 16),
                tx("t2", "expense", "a1", 100, T, dedup_hash="cd" * 16),
            ]
        ),
    ),
    (
        "external_id_and_hash_are_separate_keys",
        integrity_case(
            transactions=[
                tx("t1", "expense", "a1", 100, T, external_id="X"),
                tx("t2", "expense", "a1", 100, T, dedup_hash="cd" * 16),
            ]
        ),
    ),
    (
        "equal_amounts_without_ids_are_not_duplicates",
        integrity_case(
            transactions=[tx("t1", "expense", "a1", 100, T), tx("t2", "expense", "a1", 100, T)]
        ),
    ),
    (
        "category_of_the_other_kind",
        integrity_case(categories=CATS, transactions=[spend("t1", 1, SALARY)]),
    ),
    (
        "subcategory_of_a_subcategory",
        integrity_case(categories=[cat("a"), cat("b", parent="a"), cat("c", parent="b")]),
    ),
    (
        "subcategory_of_the_other_kind",
        integrity_case(categories=[cat("a"), cat("b", "income", parent="a")]),
    ),
    (
        "repayment_points_to_a_transaction_of_another_debt",
        integrity_case(
            transactions=[tx("t1", "income", "a1", 100, T, debt_id="d2")],
            debts=[debt("d1", "owed_to_me", 100), debt("d2", "owed_to_me", 100)],
            repayments=[repay("r1", "d1", 100, "t1"), repay("r2", "d2", 100, "t1")],
        ),
    ),
    (
        "repayment_with_a_transaction_without_a_debt",
        integrity_case(
            transactions=[tx("t1", "income", "a1", 100, T)],
            debts=[debt("d1", "owed_to_me", 100)],
            repayments=[repay("r1", "d1", 100, "t1")],
        ),
    ),
    (
        "over_repaid_debt",
        integrity_case(
            debts=[debt("d1", "i_owe", 100)],
            repayments=[repay("r1", "d1", 70), repay("r2", "d1", 70)],
        ),
    ),
    (
        "work_payment_over_linked",
        integrity_case(
            payments=[wpay("p1", 100)],
            transactions=[linked("t1", "p1", 100), linked("t2", "p1", 5)],
        ),
    ),
    (
        "problems_are_sorted_by_code_then_id",
        integrity_case(
            categories=CATS,
            transactions=[
                spend("t2", 1, SALARY),
                spend("t1", 1, SALARY),
                tx("t4", "expense", "a1", 100, "2026-10-06T09:00:00Z", external_id="E"),
                tx("t3", "expense", "a1", 100, "2026-10-05T09:00:00Z", external_id="E"),
            ],
            debts=[debt("d1", "i_owe", 100)],
            repayments=[repay("r1", "d1", 101)],
        ),
    ),
]


def run_integrity(g: dict[str, Any]) -> Any:
    return ref.integrity_problems(
        g["categories"], g["transactions"], g["debts"], g["repayments"], g["payments"]
    )


# ------------------------------------------------------------------ category ids

CATEGORY_IDS: list[Case] = [(f"id_of_{p.key}", {"system_key": p.key}) for p in PRESETS]


def run_category_ids(g: dict[str, Any]) -> Any:
    return str(category_id(g["system_key"]))


FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "scalars": (
        "Scalar rules (input.op selects the function): progress_bp, opening_instant, end_of_day, "
        "month_end, moscow_month, fold_merchant, dedup_key, effect",
        SCALARS,
        run_scalar,
    ),
    "balances": (
        "account_balances(accounts, transactions, checkpoints, at)",
        BALANCES,
        run_balances,
    ),
    "adjustments": (
        "adjustments(account, transactions, checkpoints)",
        ADJUSTMENTS,
        run_adjustments,
    ),
    "monthly": ("monthly_totals(transactions, account_ids, period)", MONTHLY, run_monthly),
    "categories": (
        "category_breakdown(transactions, categories, kind, period)",
        CATEGORY_CASES,
        run_categories,
    ),
    "merchants": ("top_merchants(transactions, kind, period, limit)", MERCHANTS, run_merchants),
    "dynamics": (
        "balance_dynamics(accounts, transactions, checkpoints, dates)",
        DYNAMICS,
        run_dynamics,
    ),
    "debts": ("debts_summary(debts, repayments, today)", DEBTS, run_debts),
    "goals": (
        "goal_progress(goal, accounts, transactions, checkpoints, debts, repayments, projects, "
        "change_requests, allocations)",
        GOALS,
        run_goals,
    ),
    "work_links": (
        "work_payment_coverage(payments, transactions)",
        WORK_LINKS,
        run_work_links,
    ),
    "integrity": (
        "integrity_problems(categories, transactions, debts, repayments, payments)",
        INTEGRITY,
        run_integrity,
    ),
    "category_ids": (
        "category_id(system_key): uuid5 of the preset categories",
        CATEGORY_IDS,
        run_category_ids,
    ),
}


def build() -> dict[str, str]:
    """File name -> exact text of the file."""
    files = {}
    for name, (description, cases, run) in FILES.items():
        names = [case_name for case_name, _ in cases]
        assert len(names) == len(set(names)), f"duplicate case names in {name}"
        document = {
            "description": description,
            "cases": [{"name": n, "input": given, "expected": run(given)} for n, given in cases],
        }
        files[f"{name}.json"] = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    return files


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for file_name, text in build().items():
        (OUT / file_name).write_text(text, encoding="utf-8")
    print(f"wrote {len(FILES)} files to {OUT}")  # noqa: T201


if __name__ == "__main__":
    main()
