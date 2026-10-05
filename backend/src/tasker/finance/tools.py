"""Read tools of the "Finance" agent: ``get_accounts``, ``get_finance_summary``, ``get_goals``,
``get_debts``. Contract: ``docs/specs/stage5_finance.md``, section 9. Numbers come from
``tasker.finance.reference``; amounts are integer kopecks with a ready-made text next to them.
"""

import json
import uuid
from datetime import UTC, datetime
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StringConstraints, model_validator

from tasker.ai.tools import MAX_TOOL_RESULT_CHARS, TOOLS, ToolContext, ToolSpec
from tasker.calendar.timefmt import format_utc, parse_date
from tasker.finance import reference
from tasker.finance.tables import (
    accounts,
    balance_checkpoints,
    categories,
    debt_repayments,
    debts,
    goals,
    transactions,
)
from tasker.money import MAX_KOPECKS, format_amount
from tasker.work import tools as work_tools
from tasker.work.reference import in_period, moscow_date

MAX_PERIOD_DAYS = 366
Day = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")]


def _amount_text(value: int) -> str:
    """``format_amount`` raises beyond ``MAX_KOPECKS``; a tool result must never fail on it."""
    if abs(value) > MAX_KOPECKS:
        return "≈ ∞" if value > 0 else "≈ -∞"
    return format_amount(value)


def _money(name: str, value: int | None) -> dict[str, Any]:
    return {
        f"{name}_kopecks": value,
        f"{name}_text": None if value is None else _amount_text(value),
    }


def _json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _clip(payload: dict[str, Any], key: str) -> str:
    """Drop trailing list items until the JSON fits the tool result limit."""
    items: list[Any] = payload[key]
    while True:
        text = _json(payload)
        if len(text) <= MAX_TOOL_RESULT_CHARS or not items:
            return text
        del items[len(items) // 2 :]
        payload["truncated"] = True
        payload["count"] = len(items)


def _plain(row: Any, *, instants: tuple[str, ...] = ()) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in dict(row).items():
        if isinstance(value, uuid.UUID):
            out[key] = str(value)
        elif key in instants and value is not None:
            out[key] = format_utc(value)
        else:
            out[key] = value
    return out


class Data:
    """Visible rows of the Finance tables in the JSON shape of ``reference``.

    Visible = live, and every parent live too (a transaction of a deleted account is hidden,
    a transfer is hidden when either account is gone), as on the client.
    """

    def __init__(self) -> None:
        self.accounts: list[dict[str, Any]] = []
        self.categories: list[dict[str, Any]] = []
        self.transactions: list[dict[str, Any]] = []
        self.checkpoints: list[dict[str, Any]] = []
        self.debts: list[dict[str, Any]] = []
        self.repayments: list[dict[str, Any]] = []
        self.goals: list[dict[str, Any]] = []
        self.work: work_tools.Data | None = None

    @property
    def names(self) -> dict[str, str]:
        return self.work.names if self.work is not None else {}


async def load(ctx: ToolContext, *, with_work: bool = False) -> Data:
    async def rows(table: sa.Table) -> list[Any]:
        query = sa.select(table).where(table.c.deleted_at.is_(None)).order_by(table.c.created_at)
        return list((await session.execute(query)).mappings().all())

    data = Data()
    async with ctx.sessionmaker() as session:
        account_rows = await rows(accounts.table)
        category_rows = await rows(categories.table)
        tx_rows = await rows(transactions.table)
        checkpoint_rows = await rows(balance_checkpoints.table)
        debt_rows = await rows(debts.table)
        repayment_rows = await rows(debt_repayments.table)
        goal_rows = await rows(goals.table)
    data.accounts = [_plain(r) for r in account_rows]
    live = {a["id"] for a in data.accounts}
    data.categories = [_plain(r) for r in category_rows]
    data.transactions = [
        t
        for t in (_plain(r, instants=("occurred_at",)) for r in tx_rows)
        if t["account_id"] in live and (t["to_account_id"] is None or t["to_account_id"] in live)
    ]
    data.checkpoints = [
        c
        for c in (_plain(r, instants=("checked_at",)) for r in checkpoint_rows)
        if c["account_id"] in live
    ]
    data.debts = [_plain(r) for r in debt_rows]
    live_debts = {d["id"] for d in data.debts}
    data.repayments = [r for r in (_plain(x) for x in repayment_rows) if r["debt_id"] in live_debts]
    data.goals = [_plain(r) for r in goal_rows]
    if with_work:
        data.work = await work_tools.load(ctx)
    return data


# ------------------------------------------------------------------ get_accounts


class GetAccountsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    include_archived: bool = False


async def get_accounts(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetAccountsArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    result = reference.account_balances(data.accounts, data.transactions, data.checkpoints)
    balance = {line["id"]: line["balance"] for line in result["accounts"]}
    last: dict[str, dict[str, Any]] = {}
    for cp in sorted(data.checkpoints, key=lambda c: (c["checked_at"], c["id"])):
        last[cp["account_id"]] = cp
    lines = []
    for account in data.accounts:
        if account["archived"] and not args.include_archived:
            continue
        checkpoint = last.get(account["id"])
        lines.append(
            {
                "id": account["id"],
                "name": account["name"],
                "kind": account["kind"],
                "bank": account["bank"],
                "card_last4": account["card_last4"],
                "in_total": account["include_in_total"],
                "archived": account["archived"],
                **_money("balance", balance[account["id"]]),
                **_money("credit_limit", account["credit_limit"]),
                "last_checkpoint_at": checkpoint["checked_at"] if checkpoint else None,
            }
        )
    payload = {
        "currency": "RUB",
        **_money("total", result["total"]),
        "count": len(lines),
        "truncated": False,
        "accounts": lines,
    }
    return _clip(payload, "accounts")


# ------------------------------------------------------------------ get_finance_summary


class GetFinanceSummaryArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    from_date: Day
    to_date: Day
    kind: Literal["expense", "income"] = "expense"
    top: StrictInt = Field(default=10, ge=1, le=30)

    @model_validator(mode="after")
    def _range(self) -> "GetFinanceSummaryArgs":
        first, last = parse_date(self.from_date), parse_date(self.to_date)
        if first is None or last is None:
            raise ValueError("from_date and to_date must be real dates YYYY-MM-DD")
        if last < first:
            raise ValueError("to_date must not be before from_date")
        if (last - first).days >= MAX_PERIOD_DAYS:
            raise ValueError(f"the range is limited to {MAX_PERIOD_DAYS} days")
        return self


async def get_finance_summary(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetFinanceSummaryArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx)
    period = {"from": args.from_date, "to": args.to_date}
    months = reference.monthly_totals(data.transactions, None, period)
    income = sum(m["income"] for m in months)
    expense = sum(m["expense"] for m in months)
    breakdown = reference.category_breakdown(data.transactions, data.categories, args.kind, period)
    names = {c["id"]: c["name"] for c in data.categories}

    def group(row: dict[str, Any]) -> dict[str, Any]:
        cid = row["category_id"]
        return {
            "category_id": cid,
            "category": names.get(cid) if cid else None,
            **_money("total", row["total"]),
            **(
                {
                    "children": [
                        {
                            "category_id": kid["category_id"],
                            "category": names.get(kid["category_id"]),
                            **_money("total", kid["total"]),
                        }
                        for kid in row["children"]
                    ]
                }
                if row["children"]
                else {}
            ),
        }

    unconfirmed = sum(
        1
        for t in data.transactions
        if t["status"] != "confirmed"
        and t["kind"] != "transfer"
        and in_period(moscow_date(t["occurred_at"]), period)
    )
    payload = {
        "currency": "RUB",
        "period": period,
        **_money("income", income),
        **_money("expense", expense),
        **_money("net", income - expense),
        "months": [
            {
                "month": m["month"],
                **_money("income", m["income"]),
                **_money("expense", m["expense"]),
            }
            for m in months
        ],
        "category_kind": args.kind,
        **_money("category_total", breakdown["total"]),
        "count": len(breakdown["groups"][: args.top]),
        "truncated": len(breakdown["groups"]) > args.top,
        "categories": [group(g) for g in breakdown["groups"][: args.top]],
        "top_merchants": [
            {"merchant": m["merchant"], **_money("total", m["total"]), "count": m["count"]}
            for m in reference.top_merchants(data.transactions, args.kind, period, 5)
        ],
        "unconfirmed_count": unconfirmed,
    }
    return _clip(payload, "categories")


# ------------------------------------------------------------------ get_goals


class GetGoalsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    goal_id: uuid.UUID | None = None
    include_archived: bool = False


async def get_goals(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetGoalsArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx, with_work=True)
    work = data.work
    assert work is not None  # noqa: S101 - asked for above
    lines = []
    for goal in data.goals:
        if args.goal_id is not None and goal["id"] != str(args.goal_id):
            continue
        if args.goal_id is None and goal["archived"] and not args.include_archived:
            continue
        progress = reference.goal_progress(
            goal,
            data.accounts,
            data.transactions,
            data.checkpoints,
            data.debts,
            data.repayments,
            work.projects,
            work.change_requests,
            work.allocations,
        )
        lines.append(
            {
                "id": goal["id"],
                "name": goal["name"],
                "deadline_date": goal["deadline_date"],
                "archived": goal["archived"],
                **_money("target", progress["target"]),
                **_money("have", progress["have"]),
                **_money("missing", progress["missing"]),
                **_money("surplus", progress["surplus"]),
                "reached": progress["reached"],
                "progress_percent": progress["progress_bp"] / 100,
                "terms": [
                    {"kind": t["kind"], **_money("value", t["value"])} for t in progress["terms"]
                ],
            }
        )
    payload = {"currency": "RUB", "count": len(lines), "truncated": False, "goals": lines}
    return _clip(payload, "goals")


# ------------------------------------------------------------------ get_debts


class GetDebtsArgs(BaseModel):
    model_config = ConfigDict(extra="ignore")

    direction: Literal["owed_to_me", "i_owe"] | None = None
    include_closed: bool = False
    limit: StrictInt = Field(default=50, ge=1, le=100)


async def get_debts(ctx: ToolContext, args: BaseModel) -> str:
    assert isinstance(args, GetDebtsArgs)  # noqa: S101 - the registry pairs handler and model
    data = await load(ctx, with_work=True)
    # "today" is the Moscow date of the server, as the contract says (stage5, 9), not the
    # time zone of the request.
    today = moscow_date(format_utc(datetime.now(UTC)))
    summary = reference.debts_summary(data.debts, data.repayments, today)
    by_id = {d["id"]: d for d in data.debts}
    found = []
    for state in summary["debts"]:
        if args.direction and state["direction"] != args.direction:
            continue
        if state["status"] == "closed" and not args.include_closed:
            continue
        row = by_id[state["id"]]
        person = row["person_id"]
        found.append(
            {
                "id": state["id"],
                "direction": state["direction"],
                "counterparty": data.names.get(person) if person else row["counterparty"],
                "status": state["status"],
                **_money("amount", state["amount"]),
                **_money("repaid", state["repaid"]),
                **_money("remaining", state["remaining"]),
                "debt_date": row["debt_date"],
                "due_date": row["due_date"],
                "overdue": state["overdue"],
            }
        )
    found.sort(key=lambda d: (d["due_date"] is None, d["due_date"] or "", d["id"]))
    shown = found[: args.limit]
    payload = {
        "currency": "RUB",
        **_money("owed_to_me_total", summary["owed_to_me"]),
        **_money("i_owe_total", summary["i_owe"]),
        "count": len(shown),
        "truncated": len(shown) < len(found),
        "debts": shown,
    }
    return _clip(payload, "debts")


GET_ACCOUNTS = TOOLS.register(
    ToolSpec(
        name="get_accounts",
        description=(
            "The user's accounts with current balances (integer kopecks and text, RUB) and the "
            "total balance (accounts counted in the total). A credit card is an ordinary "
            "balance. Unconfirmed drafts are not included. Archived accounts only with "
            "include_archived."
        ),
        parameters={
            "type": "object",
            "properties": {"include_archived": {"type": "boolean"}},
        },
        args_model=GetAccountsArgs,
        kind="read",
        sensitive=True,
        handler=get_accounts,
    )
)

GET_FINANCE_SUMMARY = TOOLS.register(
    ToolSpec(
        name="get_finance_summary",
        description=(
            "Income and expenses for a period (Europe/Moscow dates, inclusive, at most 366 "
            "days): totals, per month, breakdown by category with subcategories for `kind` "
            "(expense by default), top merchants. Transfers between own accounts, debt "
            "movements and unconfirmed drafts are never income or expense."
        ),
        parameters={
            "type": "object",
            "properties": {
                "from_date": {"type": "string", "description": "YYYY-MM-DD"},
                "to_date": {"type": "string", "description": "YYYY-MM-DD"},
                "kind": {"type": "string", "enum": ["expense", "income"]},
                "top": {"type": "integer", "minimum": 1, "maximum": 30},
            },
            "required": ["from_date", "to_date"],
        },
        args_model=GetFinanceSummaryArgs,
        kind="read",
        sensitive=True,
        handler=get_finance_summary,
    )
)

GET_GOALS = TOOLS.register(
    ToolSpec(
        name="get_goals",
        description=(
            "Progress of the user's savings goals: target, what they have by the goal's own "
            "formula (accounts, debts, expected payments from Work), what is missing "
            "(negative = reached with a surplus). Optional goal_id."
        ),
        parameters={
            "type": "object",
            "properties": {
                "goal_id": {"type": "string", "description": "uuid of one goal"},
                "include_archived": {"type": "boolean"},
            },
        },
        args_model=GetGoalsArgs,
        kind="read",
        sensitive=True,
        handler=get_goals,
    )
)

GET_DEBTS = TOOLS.register(
    ToolSpec(
        name="get_debts",
        description=(
            "Debts: who owes the user (owed_to_me) and whom the user owes (i_owe), with repaid "
            "and remaining amounts, status and due dates. Closed debts only with "
            "include_closed."
        ),
        parameters={
            "type": "object",
            "properties": {
                "direction": {"type": "string", "enum": ["owed_to_me", "i_owe"]},
                "include_closed": {"type": "boolean"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
        args_model=GetDebtsArgs,
        kind="read",
        sensitive=True,
        handler=get_debts,
    )
)

__all__ = ["GET_ACCOUNTS", "GET_DEBTS", "GET_FINANCE_SUMMARY", "GET_GOALS"]
