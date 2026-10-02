"""Builders of valid Stage 5 rows and the seeded Finance graph of the spec (the Excel case)."""

import uuid
from dataclasses import dataclass
from typing import Any

from tasker.finance.presets import category_id
from tasker.ids import uuid7
from tests.api_support import DeviceClient
from tests.work_support import person_fields, project_fields

R = 100  # kopecks in a rouble
AT = "2026-10-05T09:00:00Z"


def account_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "name": "Карта",
        "kind": "debit_card",
        "opening_balance": 0,
        "opening_date": "2026-01-01",
        "include_in_total": True,
        "archived": False,
        "created_at": dc.created(),
        **over,
    }


def category_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {"name": "Кофе", "kind": "expense", "created_at": dc.created(), **over}


def transaction_fields(dc: DeviceClient, account: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "kind": "expense",
        "account_id": str(account),
        "amount": 12_500,
        "occurred_at": AT,
        "source": "manual",
        "status": "confirmed",
        "created_at": dc.created(),
        **over,
    }


def checkpoint_fields(dc: DeviceClient, account: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "account_id": str(account),
        "checked_at": AT,
        "actual_balance": 17_320_000,
        "source": "manual",
        "created_at": dc.created(),
        **over,
    }


def debt_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "direction": "owed_to_me",
        "counterparty": "Сосед",
        "amount": 750_000,
        "debt_date": "2026-09-01",
        "created_at": dc.created(),
        **over,
    }


def repayment_fields(dc: DeviceClient, debt: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "debt_id": str(debt),
        "amount": 100_000,
        "repaid_on": "2026-09-15",
        "created_at": dc.created(),
        **over,
    }


def term(kind: str, sign: str = "+", **extra: Any) -> dict[str, Any]:
    return {"kind": kind, "sign": sign, **extra}


DEFAULT_FORMULA = [term("all_accounts"), term("debts_to_me"), term("receivables", client_ids=None)]


def goal_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "name": "Накопить",
        "target_amount": 400_000 * R,
        "formula": DEFAULT_FORMULA,
        "archived": False,
        "created_at": dc.created(),
        **over,
    }


@dataclass
class ExcelSeed:
    cash: uuid.UUID
    card: uuid.UUID
    savings: uuid.UUID
    credit: uuid.UUID
    roma: uuid.UUID
    d1: uuid.UUID
    d2: uuid.UUID
    d3: uuid.UUID
    p1: uuid.UUID
    p2: uuid.UUID
    goal: uuid.UUID


def excel_seed_ops(dc: DeviceClient) -> tuple[ExcelSeed, list[dict[str, Any]]]:
    """Accounts 54 000 + 174 000 + 8 000, credit card 125 000, debts to me 7 500 + 2 600 + 3 000,
    Roma owes 20 000 + 60 500 through two projects, a goal of 400 000 with the default formula."""
    s = ExcelSeed(*(uuid7() for _ in range(11)))
    accounts: list[tuple[uuid.UUID, str, str, int, dict[str, Any]]] = [
        (s.cash, "Наличные", "cash", 54_000, {}),
        (s.card, "Т-Банк", "debit_card", 174_000, {"bank": "Т-Банк", "card_last4": "1234"}),
        (s.savings, "Накопительный", "savings", 8_000, {}),
        (s.credit, "Кредитка", "credit_card", 125_000, {"credit_limit": 300_000 * R}),
    ]
    ops = [
        dc.op(
            "accounts",
            account_id,
            fields=account_fields(dc, name=name, kind=kind, opening_balance=rub * R, **extra),
        )
        for account_id, name, kind, rub, extra in accounts
    ]
    ops.append(dc.op("people", s.roma, fields=person_fields(dc, role="client")))
    for debt_id, rub in ((s.d1, 7_500), (s.d2, 2_600), (s.d3, 3_000)):
        ops.append(dc.op("debts", debt_id, fields=debt_fields(dc, amount=rub * R)))
    for project_id, rub in ((s.p1, 20_000), (s.p2, 60_500)):
        ops.append(
            dc.op(
                "projects",
                project_id,
                fields=project_fields(
                    dc, title=f"Проект {rub}", client_id=str(s.roma), base_amount=rub * R
                ),
            )
        )
    ops.append(dc.op("goals", s.goal, fields=goal_fields(dc)))
    return s, ops


async def excel_seed(dc: DeviceClient) -> ExcelSeed:
    graph, ops = excel_seed_ops(dc)
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return graph


@dataclass
class Activity:
    salary: uuid.UUID
    food: uuid.UUID
    food2: uuid.UUID
    taxi: uuid.UUID
    transfer: uuid.UUID
    draft: uuid.UUID
    repay_tx: uuid.UUID
    debt_out: uuid.UUID
    repayment: uuid.UUID


async def activity_seed(dc: DeviceClient, s: ExcelSeed) -> Activity:
    """October: salary, groceries, a taxi just after Moscow midnight, a transfer to savings, a
    draft, and a 3 000 repayment of a debt of 10 000 that the user owes."""
    a = Activity(*(uuid7() for _ in range(9)))
    cat = {
        key: category_id(key)
        for key in ("income.salary", "expense.groceries", "expense.transport.taxi")
    }
    parents = {"expense.transport.taxi": category_id("expense.transport")}
    category_ops = [
        dc.op(
            "categories",
            cid,
            fields=category_fields(
                dc,
                name=key,
                kind="income" if key.startswith("income") else "expense",
                system_key=key,
                **({"parent_id": str(parents[key])} if key in parents else {}),
            ),
        )
        for key, cid in cat.items()
    ]
    category_ops.append(
        dc.op(
            "categories",
            parents["expense.transport.taxi"],
            fields=category_fields(dc, name="Транспорт", system_key="expense.transport"),
        )
    )
    ops = [
        *category_ops,
        dc.op("debts", a.debt_out, fields=debt_fields(dc, direction="i_owe", amount=1_000_000)),
        dc.op(
            "transactions",
            a.salary,
            fields=transaction_fields(
                dc,
                s.card,
                kind="income",
                amount=3_000_000,
                category_id=str(cat["income.salary"]),
                occurred_at="2026-10-02T09:00:00Z",
            ),
        ),
        dc.op(
            "transactions",
            a.food,
            fields=transaction_fields(
                dc,
                s.card,
                amount=125_050,
                category_id=str(cat["expense.groceries"]),
                merchant="Пятёрочка",
                occurred_at="2026-10-03T09:00:00Z",
            ),
        ),
        dc.op(
            "transactions",
            a.food2,
            fields=transaction_fields(
                dc,
                s.card,
                amount=74_950,
                category_id=str(cat["expense.groceries"]),
                merchant="ПЯТЁРОЧКА",
                occurred_at="2026-10-04T09:00:00Z",
            ),
        ),
        dc.op(
            "transactions",
            a.taxi,
            fields=transaction_fields(
                dc,
                s.card,
                amount=50_000,
                category_id=str(cat["expense.transport.taxi"]),
                occurred_at="2026-09-30T21:30:00Z",
            ),
        ),
        dc.op(
            "transactions",
            a.transfer,
            fields=transaction_fields(
                dc,
                s.card,
                kind="transfer",
                amount=1_000_000,
                to_account_id=str(s.savings),
            ),
        ),
        dc.op(
            "transactions",
            a.draft,
            fields=transaction_fields(
                dc, s.card, amount=999_999, status="draft", source="notification"
            ),
        ),
        dc.op(
            "transactions",
            a.repay_tx,
            fields=transaction_fields(dc, s.cash, amount=300_000, debt_id=str(a.debt_out)),
        ),
        dc.op(
            "debt_repayments",
            a.repayment,
            fields=repayment_fields(dc, a.debt_out, amount=300_000, transaction_id=str(a.repay_tx)),
        ),
    ]
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return a
