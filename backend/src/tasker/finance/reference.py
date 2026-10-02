"""Reference calculations of the Finance module (spec: ``docs/specs/stage5_finance.md``).

Pure functions over JSON-shaped rows (dicts with the table column names, instants as
``YYYY-MM-DDTHH:MM:SSZ``, dates as ``YYYY-MM-DD``, ids as lowercase strings). The shared vectors,
the AI tools and the Dart client run the same rules. Money is integer kopecks and is never
rounded; the only division (``progress_bp``) rounds down. Calendar rules use the Moscow helpers
of Stage 4 (``tasker.work.reference``).
"""

import re
from collections import defaultdict
from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime, timedelta
from typing import Any

from tasker.calendar.ids import fold_tag_name
from tasker.work import reference as work

Row = Mapping[str, Any]
Rows = Sequence[Row]

MOSCOW_OFFSET = work.MOSCOW_OFFSET
_SPACES = re.compile(r"[ \t\n\r\u00a0]+")


# ------------------------------------------------------------------ time


def opening_instant(day: str) -> datetime:
    """The first instant of a Moscow date: 00:00 at UTC+3 = 21:00Z of the previous day."""
    return datetime.fromisoformat(day).replace(tzinfo=UTC) - MOSCOW_OFFSET


def end_of_day(day: str) -> datetime:
    """The last whole second of a Moscow date (23:59:59 at UTC+3)."""
    return opening_instant(day) + timedelta(days=1, seconds=-1)


def month_end(month: str) -> str:
    """The last date of a ``YYYY-MM`` month."""
    year, number = int(month[:4]), int(month[5:7])
    first_of_next = date(year + (number == 12), number % 12 + 1, 1)
    return (first_of_next - timedelta(days=1)).isoformat()


def _when(text: str) -> datetime:
    return work.parse_instant(text)


# ------------------------------------------------------------------ text


def fold_merchant(text: str) -> str:
    """Merchant key: spaces collapsed and trimmed, ASCII and Cyrillic capitals lowered (the
    cross-runtime-safe fold of tags; ``str.lower`` differs between runtimes)."""
    return fold_tag_name(_SPACES.sub(" ", text).strip(" "))


def dedup_key(tx: Row) -> str | None:
    """The key under which a bank operation must be unique per account (spec 7), or ``None``."""
    if tx.get("external_id") is not None:
        return f"ext|{tx['account_id']}|{tx['external_id']}"
    if tx.get("dedup_hash") is not None:
        return f"hash|{tx['account_id']}|{tx['dedup_hash']}"
    return None


def progress_basis_points(have: int, target: int) -> int:
    """Share of the goal reached in 1/100 of a percent, rounded down; 0 for ``have <= 0``."""
    return 0 if target <= 0 or have <= 0 else have * 10_000 // target


# ------------------------------------------------------------------ balances


def _confirmed(tx: Row) -> bool:
    return bool(tx["status"] == "confirmed")


def effect(tx: Row, account_id: str) -> int:
    """What a confirmed transaction does to the balance of one account (signed kopecks)."""
    if not _confirmed(tx):
        return 0
    amount = int(tx["amount"])
    if tx["kind"] == "income":
        return amount if tx["account_id"] == account_id else 0
    if tx["kind"] == "expense":
        return -amount if tx["account_id"] == account_id else 0
    total = 0  # transfer: out of ``account_id``, into ``to_account_id``
    if tx["account_id"] == account_id:
        total -= amount
    if tx.get("to_account_id") == account_id:
        total += amount
    return total


def _checkpoint_key(cp: Row) -> tuple[datetime, str]:
    return (_when(cp["checked_at"]), cp["id"])


def balance_at(account: Row, transactions: Rows, checkpoints: Rows, at: str | None = None) -> int:
    """Balance of an account at the instant ``at`` (``None`` = now, all data).

    Baseline = the latest of the opening (start of the Moscow day ``opening_date``) and the
    checkpoints of this account up to ``at``; at an equal instant the checkpoint wins, and among
    checkpoints the greater ``(checked_at, id)``. Balance = baseline amount + effects of confirmed
    transactions after the baseline (strictly after a checkpoint, from the opening instant on)
    up to ``at`` inclusive. Before the opening the account holds 0.
    """
    limit = None if at is None else _when(at)
    opened = opening_instant(account["opening_date"])
    if limit is not None and limit < opened:
        return 0
    mine = [
        cp
        for cp in checkpoints
        if cp["account_id"] == account["id"] and (limit is None or _when(cp["checked_at"]) <= limit)
    ]
    start, amount, strict = opened, int(account["opening_balance"]), False
    if mine:
        best = max(mine, key=_checkpoint_key)
        moment = _when(best["checked_at"])
        if moment >= opened:
            start, amount, strict = moment, int(best["actual_balance"]), True
    balance = amount
    for tx in transactions:
        when = _when(tx["occurred_at"])
        if (when <= start if strict else when < start) or (limit is not None and when > limit):
            continue
        balance += effect(tx, account["id"])
    return balance


def account_balances(
    accounts: Rows, transactions: Rows, checkpoints: Rows, at: str | None = None
) -> dict[str, Any]:
    """Balance per account (input order) and ``total`` over accounts with ``include_in_total``."""
    lines = [
        {
            "id": a["id"],
            "balance": balance_at(a, transactions, checkpoints, at),
            "in_total": bool(a["include_in_total"]),
        }
        for a in accounts
    ]
    return {"accounts": lines, "total": sum(x["balance"] for x in lines if x["in_total"])}


def balance_dynamics(
    accounts: Rows, transactions: Rows, checkpoints: Rows, dates: Sequence[str]
) -> list[dict[str, Any]]:
    """Total balance at the end of each given Moscow date (input order)."""
    out = []
    for day in dates:
        at = end_of_day(day).strftime("%Y-%m-%dT%H:%M:%SZ")
        out.append(
            {
                "date": day,
                "total": account_balances(accounts, transactions, checkpoints, at)["total"],
            }
        )
    return out


def adjustments(account: Row, transactions: Rows, checkpoints: Rows) -> list[dict[str, Any]]:
    """For each checkpoint (ascending): what the books expected just before it and the gap.

    ``expected`` = balance at the checkpoint's instant computed from the opening and the earlier
    checkpoints only; ``adjustment = actual - expected`` (a correction, never an income or an
    expense). Checkpoints before the opening of the account are not listed.
    """
    opened = opening_instant(account["opening_date"])
    mine = sorted(
        (cp for cp in checkpoints if cp["account_id"] == account["id"]), key=_checkpoint_key
    )
    out = []
    for index, cp in enumerate(mine):
        if _when(cp["checked_at"]) < opened:
            continue
        expected = balance_at(account, transactions, mine[:index], cp["checked_at"])
        out.append(
            {
                "checkpoint_id": cp["id"],
                "checked_at": cp["checked_at"],
                "actual": int(cp["actual_balance"]),
                "expected": expected,
                "adjustment": int(cp["actual_balance"]) - expected,
            }
        )
    return out


# ------------------------------------------------------------------ analytics


def counts_in_analytics(tx: Row) -> bool:
    """Confirmed income or expense that is not a transfer and not part of a debt."""
    return _confirmed(tx) and tx["kind"] in ("income", "expense") and tx.get("debt_id") is None


def monthly_totals(
    transactions: Rows, account_ids: Sequence[str] | None = None, period: Row | None = None
) -> list[dict[str, Any]]:
    """Income and expense per Moscow month (``YYYY-MM``, ascending, months with data only)."""
    sums: dict[str, dict[str, int]] = defaultdict(lambda: {"income": 0, "expense": 0})
    for tx in transactions:
        if not counts_in_analytics(tx):
            continue
        if account_ids is not None and tx["account_id"] not in account_ids:
            continue
        day = work.moscow_date(tx["occurred_at"])
        if work.in_period(day, period):
            sums[day[:7]][tx["kind"]] += int(tx["amount"])
    return [
        {
            "month": month,
            "income": sums[month]["income"],
            "expense": sums[month]["expense"],
            "net": sums[month]["income"] - sums[month]["expense"],
        }
        for month in sorted(sums)
    ]


def category_breakdown(
    transactions: Rows, categories: Rows, kind: str, period: Row | None = None
) -> dict[str, Any]:
    """Totals of ``kind`` ("expense" | "income") per top-level category with subcategories.

    ``categories`` are the live categories. A transaction goes to its category; if that has a
    live parent, it is a child of the parent group, otherwise a group of its own. A missing,
    deleted or empty category means the ``null`` group. Groups: total desc, ``null`` last, id;
    children: total desc, id.
    """
    parent_of = {c["id"]: c.get("parent_id") for c in categories}
    groups: dict[str | None, dict[str, Any]] = {}
    children: dict[str | None, dict[str, dict[str, int]]] = defaultdict(dict)
    grand = 0
    for tx in transactions:
        if not counts_in_analytics(tx) or tx["kind"] != kind:
            continue
        if not work.in_period(work.moscow_date(tx["occurred_at"]), period):
            continue
        amount = int(tx["amount"])
        cid = tx.get("category_id")
        if cid not in parent_of:
            cid = None
        parent = parent_of.get(cid) if cid is not None else None
        top = parent if parent in parent_of else cid
        group = groups.setdefault(top, {"category_id": top, "total": 0, "own": 0, "count": 0})
        group["total"] += amount
        group["count"] += 1
        grand += amount
        if top == cid:
            group["own"] += amount
        else:
            row = children[top].setdefault(str(cid), {"total": 0, "count": 0})
            row["total"] += amount
            row["count"] += 1
    ordered = sorted(
        groups.values(),
        key=lambda g: (-g["total"], g["category_id"] is None, g["category_id"] or ""),
    )
    for group in ordered:
        kids = children[group["category_id"]]
        group["children"] = [
            {"category_id": cid, "total": v["total"], "count": v["count"]}
            for cid, v in sorted(kids.items(), key=lambda item: (-item[1]["total"], item[0]))
        ]
    return {"total": grand, "groups": ordered}


def top_merchants(
    transactions: Rows, kind: str = "expense", period: Row | None = None, limit: int = 10
) -> list[dict[str, Any]]:
    """Merchants by total (``fold_merchant`` key; shown as the spelling of the earliest
    transaction by ``(occurred_at, id)``); blank merchants are skipped."""
    found: dict[str, dict[str, Any]] = {}
    ordered = sorted(
        (tx for tx in transactions if counts_in_analytics(tx) and tx["kind"] == kind),
        key=lambda tx: (_when(tx["occurred_at"]), tx["id"]),
    )
    for tx in ordered:
        name = _SPACES.sub(" ", tx.get("merchant") or "").strip(" ")
        if not name or not work.in_period(work.moscow_date(tx["occurred_at"]), period):
            continue
        row = found.setdefault(fold_merchant(name), {"merchant": name, "total": 0, "count": 0})
        row["total"] += int(tx["amount"])
        row["count"] += 1
    ranked = sorted(found.items(), key=lambda item: (-item[1]["total"], -item[1]["count"], item[0]))
    return [row for _, row in ranked[:limit]]


# ------------------------------------------------------------------ debts


def debt_state(debt: Row, repayments: Rows, today: str | None = None) -> dict[str, Any]:
    """Repaid and remaining amounts, status (open / partial / closed) and overdue flag."""
    repaid = sum(int(r["amount"]) for r in repayments if r["debt_id"] == debt["id"])
    amount = int(debt["amount"])
    status = "closed" if repaid >= amount else "partial" if repaid > 0 else "open"
    due = debt.get("due_date")
    return {
        "id": debt["id"],
        "direction": debt["direction"],
        "amount": amount,
        "repaid": repaid,
        "remaining": max(0, amount - repaid),
        "overpaid": max(0, repaid - amount),
        "status": status,
        "overdue": bool(today and due and status != "closed" and due < today),
    }


def debts_summary(debts: Rows, repayments: Rows, today: str | None = None) -> dict[str, Any]:
    """States of all debts (input order) and the open remainders per direction."""
    states = [debt_state(d, repayments, today) for d in debts]
    owed_to_me = sum(s["remaining"] for s in states if s["direction"] == "owed_to_me")
    i_owe = sum(s["remaining"] for s in states if s["direction"] == "i_owe")
    return {"owed_to_me": owed_to_me, "i_owe": i_owe, "debts": states}


# ------------------------------------------------------------------ goals


def goal_progress(
    goal: Row,
    accounts: Rows,
    transactions: Rows,
    checkpoints: Rows,
    debts: Rows,
    repayments: Rows,
    projects: Rows,
    change_requests: Rows,
    allocations: Rows,
) -> dict[str, Any]:
    """Evaluate the "have" formula of a goal.

    Each term gives a non-negative value that the sign makes positive or negative:
    ``accounts`` - balances of the listed accounts (a deleted one counts 0; each id once);
    ``all_accounts`` - the total balance (accounts with ``include_in_total``);
    ``debts_to_me`` / ``my_debts`` - open remainders of the debts in that direction;
    ``receivables`` - Work receivables of the listed customers (``null`` = all, also those of
    projects without a customer). ``missing = target - have`` is signed.
    """
    balances = {a["id"]: balance_at(a, transactions, checkpoints) for a in accounts}
    in_total = sum(balances[a["id"]] for a in accounts if a["include_in_total"])
    summary = debts_summary(debts, repayments)
    owed = work.receivables(projects, change_requests, allocations)
    lines = []
    for term in goal["formula"]:
        kind = term["kind"]
        if kind == "accounts":
            value = sum(balances.get(i, 0) for i in set(term["account_ids"]))
        elif kind == "all_accounts":
            value = in_total
        elif kind == "debts_to_me":
            value = summary["owed_to_me"]
        elif kind == "my_debts":
            value = summary["i_owe"]
        else:
            chosen = term.get("client_ids")
            value = (
                owed["total"]
                if chosen is None
                else sum(c["remaining"] for c in owed["clients"] if c["client_id"] in chosen)
            )
        lines.append({"kind": kind, "value": value if term["sign"] == "+" else -value})
    have = sum(line["value"] for line in lines)
    target = int(goal["target_amount"])
    missing = target - have
    return {
        "have": have,
        "target": target,
        "missing": missing,
        "reached": missing <= 0,
        "surplus": max(0, -missing),
        "progress_bp": progress_basis_points(have, target),
        "terms": lines,
    }


# ------------------------------------------------------------------ Work payments


def work_payment_coverage(payments: Rows, transactions: Rows) -> list[dict[str, Any]]:
    """How much of each Work payment is already reflected as confirmed income on an account.

    ``linked`` = confirmed income transactions with ``work_payment_id`` = the payment;
    ``unlinked = amount - linked`` (signed; negative = over-linked). Input order.
    """
    linked: dict[str, int] = defaultdict(int)
    for tx in transactions:
        if _confirmed(tx) and tx["kind"] == "income" and tx.get("work_payment_id") is not None:
            linked[tx["work_payment_id"]] += int(tx["amount"])
    return [
        {
            "payment_id": p["id"],
            "amount": int(p["amount"]),
            "linked": linked[p["id"]],
            "unlinked": int(p["amount"]) - linked[p["id"]],
        }
        for p in payments
    ]


# ------------------------------------------------------------------ integrity


def integrity_problems(
    categories: Rows,
    transactions: Rows,
    debts: Rows,
    repayments: Rows,
    payments: Rows,
) -> list[dict[str, Any]]:
    """What the server cannot reject row by row (spec 8); sorted by ``code``, then ``id``."""
    found: list[dict[str, Any]] = []
    by_id = {c["id"]: c for c in categories}
    for c in categories:
        parent = by_id.get(c.get("parent_id"))
        if parent is not None and (parent.get("parent_id") in by_id or parent["kind"] != c["kind"]):
            found.append({"code": "category_parent_invalid", "id": c["id"], "excess": None})
    first: dict[str, tuple[datetime, str]] = {}
    for tx in transactions:
        key = dedup_key(tx)
        if key is not None:
            first[key] = min(
                first.get(key, (_when(tx["occurred_at"]), tx["id"])),
                (_when(tx["occurred_at"]), tx["id"]),
            )
    for tx in transactions:
        key = dedup_key(tx)
        if key is not None and first[key] != (_when(tx["occurred_at"]), tx["id"]):
            found.append({"code": "duplicate_external_id", "id": tx["id"], "excess": None})
        category = by_id.get(tx.get("category_id"))
        if category is not None and tx["kind"] != category["kind"]:
            found.append({"code": "category_kind_mismatch", "id": tx["id"], "excess": None})
    debt_of = {tx["id"]: tx.get("debt_id") for tx in transactions}
    for r in repayments:
        link = r.get("transaction_id")
        if link in debt_of and debt_of[link] != r["debt_id"]:
            found.append({"code": "repayment_transaction_mismatch", "id": r["id"], "excess": None})
    for d in debts:
        state = debt_state(d, repayments)
        if state["overpaid"]:
            found.append({"code": "over_repaid", "id": d["id"], "excess": state["overpaid"]})
    for line in work_payment_coverage(payments, transactions):
        if line["unlinked"] < 0:
            found.append(
                {
                    "code": "work_payment_over_linked",
                    "id": line["payment_id"],
                    "excess": -line["unlinked"],
                }
            )
    found.sort(key=lambda f: (f["code"], f["id"]))
    return found
