"""The Finance read tools on seeded data: balances, summary, goals (Excel case), debts."""

import json
from typing import Any
from zoneinfo import ZoneInfo

import pytest

import tasker.ai.builtin  # noqa: F401 - registers the tools
from tasker.ai.agents import FINANCE_TOOLS, builtin_tools
from tasker.ai.tools import TOOLS, ToolArgumentError, ToolContext
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.finance_support import (
    ExcelSeed,
    R,
    account_fields,
    activity_seed,
    checkpoint_fields,
    debt_fields,
    excel_seed,
    goal_fields,
    repayment_fields,
    term,
)
from tests.work_support import person_fields


async def call(env: Env, name: str, args: dict[str, Any]) -> dict[str, Any]:
    spec = TOOLS.get(name)
    assert spec is not None
    assert spec.handler is not None
    ctx = ToolContext(env.sessionmaker, ZoneInfo("Europe/Moscow"))
    text = await spec.handler(ctx, spec.parse(args))
    assert len(text) <= 20_000
    result: dict[str, Any] = json.loads(text)
    return result


async def seeded(env: Env) -> tuple[DeviceClient, ExcelSeed]:
    phone = await env.login()
    seed = await excel_seed(phone)
    await activity_seed(phone, seed)
    return phone, seed


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def test_the_tools_are_registered_as_read_tools_of_the_finance_profile() -> None:
    for name in FINANCE_TOOLS:
        spec = TOOLS.get(name)
        assert spec is not None
        assert spec.kind == "read"
    assert builtin_tools("finance")[-4:] == FINANCE_TOOLS
    assert "get_accounts" not in builtin_tools("work")
    assert "get_projects" not in builtin_tools("finance")


async def test_get_accounts_shows_balances_and_the_total(env: Env) -> None:
    await seeded(env)
    result = await call(env, "get_accounts", {})
    assert result["currency"] == "RUB"
    assert result["total_kopecks"] == 385_500 * R
    assert result["total_text"] == "385 500 ₽"
    by_name = {a["name"]: a for a in result["accounts"]}
    assert by_name["Т-Банк"]["balance_kopecks"] == 191_500 * R
    assert by_name["Т-Банк"]["card_last4"] == "1234"
    assert by_name["Кредитка"]["credit_limit_kopecks"] == 300_000 * R
    assert by_name["Наличные"]["credit_limit_kopecks"] is None
    assert by_name["Накопительный"]["balance_text"] == "18 000 ₽"


async def test_get_accounts_hides_archived_accounts_and_honours_checkpoints(env: Env) -> None:
    phone, seed = await seeded(env)
    old = uuid7()
    await phone.push_ok(
        [
            phone.op(
                "accounts",
                old,
                fields=account_fields(phone, name="Старый", archived=True, opening_balance=1_000),
            ),
            phone.op(
                "balance_checkpoints",
                uuid7(),
                fields=checkpoint_fields(
                    phone, seed.cash, checked_at="2026-10-07T09:00:00Z", actual_balance=4_000_000
                ),
            ),
            phone.op(
                "accounts", seed.credit, fields={"include_in_total": False}, base=await head(phone)
            ),
        ]
    )
    result = await call(env, "get_accounts", {})
    names = [a["name"] for a in result["accounts"]]
    assert "Старый" not in names
    cash = next(a for a in result["accounts"] if a["name"] == "Наличные")
    assert cash["balance_kopecks"] == 4_000_000
    assert cash["last_checkpoint_at"] == "2026-10-07T09:00:00Z"
    # the archived account still counts (+10 ₽); the credit card left the total (-125 000 ₽)
    assert result["total_kopecks"] == (385_500 - 125_000 - 51_000 + 40_000) * R + 1_000
    with_old = await call(env, "get_accounts", {"include_archived": True})
    assert "Старый" in [a["name"] for a in with_old["accounts"]]


async def test_get_accounts_ignores_deleted_accounts_and_their_transfers(env: Env) -> None:
    phone, seed = await seeded(env)
    await phone.push_ok([phone.op("accounts", seed.savings, "delete", base=await head(phone))])
    result = await call(env, "get_accounts", {})
    assert [a["name"] for a in result["accounts"]] == ["Наличные", "Т-Банк", "Кредитка"]
    # the transfer is gone with the account: the card is back to 201 500
    card = next(a for a in result["accounts"] if a["name"] == "Т-Банк")
    assert card["balance_kopecks"] == 201_500 * R


async def test_get_finance_summary_counts_only_real_income_and_expense(env: Env) -> None:
    await seeded(env)
    result = await call(
        env, "get_finance_summary", {"from_date": "2026-10-01", "to_date": "2026-10-31"}
    )
    assert result["income_kopecks"] == 3_000_000
    assert result["expense_kopecks"] == 250_000  # no transfer, no draft, no debt repayment
    assert result["net_kopecks"] == 2_750_000
    assert [m["month"] for m in result["months"]] == ["2026-10"]
    assert result["unconfirmed_count"] == 1
    groups = {g["category"]: g for g in result["categories"]}
    assert groups["expense.groceries"]["total_kopecks"] == 200_000
    transport = groups["Транспорт"]
    assert transport["total_kopecks"] == 50_000
    assert transport["children"][0]["category"] == "expense.transport.taxi"
    assert result["top_merchants"] == [
        {"merchant": "Пятёрочка", "total_kopecks": 200_000, "total_text": "2 000 ₽", "count": 2}
    ]
    income = await call(
        env,
        "get_finance_summary",
        {"from_date": "2026-10-01", "to_date": "2026-10-31", "kind": "income"},
    )
    assert income["category_kind"] == "income"
    assert income["categories"][0]["total_kopecks"] == 3_000_000


async def test_the_summary_follows_moscow_midnight(env: Env) -> None:
    await seeded(env)
    september = await call(
        env, "get_finance_summary", {"from_date": "2026-09-01", "to_date": "2026-09-30"}
    )
    assert september["expense_kopecks"] == 0  # the taxi at 00:30 Moscow time is October
    october_first = await call(
        env, "get_finance_summary", {"from_date": "2026-10-01", "to_date": "2026-10-01"}
    )
    assert october_first["expense_kopecks"] == 50_000


async def test_summary_argument_errors(env: Env) -> None:
    await seeded(env)
    for bad in (
        {"from_date": "2026-10-31", "to_date": "2026-10-01"},
        {"from_date": "2026-02-30", "to_date": "2026-03-01"},
        {"from_date": "2025-01-01", "to_date": "2026-10-01"},
        {"from_date": "2026-10-01"},
        {"from_date": "2026-10-01", "to_date": "2026-10-02", "kind": "transfer"},
        {"from_date": "2026-10-01", "to_date": "2026-10-02", "top": 0},
    ):
        with pytest.raises(ToolArgumentError):
            await call(env, "get_finance_summary", bad)


async def test_get_goals_reproduces_the_excel_case(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)  # no activity: balances are the opening balances
    result = await call(env, "get_goals", {})
    assert result["count"] == 1
    goal = result["goals"][0]
    assert goal["have_kopecks"] == 454_600 * R
    assert goal["target_kopecks"] == 400_000 * R
    assert goal["missing_kopecks"] == -54_600 * R
    assert goal["missing_text"] == "-54 600 ₽"
    assert goal["surplus_kopecks"] == 54_600 * R
    assert goal["reached"] is True
    assert goal["progress_percent"] == 113.65
    assert [t["kind"] for t in goal["terms"]] == ["all_accounts", "debts_to_me", "receivables"]
    assert [t["value_kopecks"] for t in goal["terms"]] == [361_000 * R, 13_100 * R, 80_500 * R]

    # drop the credit card from the total: 329 600, 70 400 still missing
    await phone.push_ok(
        [
            phone.op(
                "accounts", seed.credit, fields={"include_in_total": False}, base=await head(phone)
            )
        ]
    )
    goal = (await call(env, "get_goals", {"goal_id": str(seed.goal)}))["goals"][0]
    assert (goal["have_kopecks"], goal["missing_kopecks"]) == (329_600 * R, 70_400 * R)
    assert goal["reached"] is False


async def test_get_goals_filters_and_formula_variants(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    other, archived = uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op(
                "goals",
                other,
                fields=goal_fields(
                    phone,
                    name="Только Рома",
                    target_amount=100_000 * R,
                    formula=[
                        term("receivables", client_ids=[str(seed.roma)]),
                        term("my_debts", "-"),
                    ],
                ),
            ),
            phone.op("goals", archived, fields=goal_fields(phone, name="Старая", archived=True)),
        ]
    )
    result = await call(env, "get_goals", {})
    assert sorted(g["name"] for g in result["goals"]) == ["Накопить", "Только Рома"]
    roma = next(g for g in result["goals"] if g["name"] == "Только Рома")
    assert roma["have_kopecks"] == 80_500 * R
    assert roma["missing_kopecks"] == 19_500 * R
    with_archived = await call(env, "get_goals", {"include_archived": True})
    assert len(with_archived["goals"]) == 3
    one = await call(env, "get_goals", {"goal_id": str(other)})
    assert [g["name"] for g in one["goals"]] == ["Только Рома"]
    none = await call(env, "get_goals", {"goal_id": str(uuid7())})
    assert none["goals"] == []


async def test_get_debts(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    friend = uuid7()
    pushed = await phone.push_ok(
        [
            phone.op("people", friend, fields=person_fields(phone, name="Лёша")),
            phone.op(
                "debts",
                uuid7(),
                fields=debt_fields(
                    phone,
                    counterparty=None,
                    person_id=str(friend),
                    amount=500_000,
                    debt_date="2019-12-01",
                    due_date="2020-01-01",
                ),
            ),
            phone.op(
                "debts",
                uuid7(),
                fields=debt_fields(
                    phone, counterparty="Позже", amount=100_000, due_date="2100-01-01"
                ),
            ),
        ]
    )
    assert [r["status"] for r in pushed] == ["applied"] * 3, pushed
    await phone.push_ok(
        [
            phone.op(
                "debt_repayments",
                uuid7(),
                fields=repayment_fields(phone, act.debt_out, amount=700_000),
            )
        ]
    )  # 300 000 + 700 000 = the whole 10 000 ₽ that the user owed: closed
    result = await call(env, "get_debts", {})
    assert result["owed_to_me_total_kopecks"] == (13_100 + 5_000 + 1_000) * R
    assert result["i_owe_total_kopecks"] == 0
    names = [d["counterparty"] for d in result["debts"]]
    assert "Лёша" in names  # the person's name, not the text
    assert next(d for d in result["debts"] if d["counterparty"] == "Лёша")["overdue"] is True
    assert all(d["status"] != "closed" for d in result["debts"])
    everything = await call(env, "get_debts", {"include_closed": True, "direction": "i_owe"})
    assert [d["status"] for d in everything["debts"]] == ["closed"]
    assert everything["debts"][0]["repaid_kopecks"] == 1_000_000
    limited = await call(env, "get_debts", {"limit": 2})
    assert (limited["count"], limited["truncated"]) == (2, True)
    # the sort puts due dates first, the undated last
    dated = [d["due_date"] for d in (await call(env, "get_debts", {}))["debts"]]
    assert dated[0] == "2020-01-01"
    assert dated[1] == "2100-01-01"


async def test_a_large_ledger_is_clipped_to_the_result_limit(env: Env) -> None:
    phone = await env.login()
    ops = [
        phone.op("accounts", uuid7(), fields=account_fields(phone, name=f"Счёт {i:04d}" + "я" * 80))
        for i in range(250)
    ]
    await phone.push_ok(ops)
    result = await call(env, "get_accounts", {})
    assert result["truncated"] is True
    assert 0 < result["count"] < 250
    assert result["count"] == len(result["accounts"])


async def test_tools_see_nothing_before_the_first_sync(env: Env) -> None:
    await env.login()
    assert (await call(env, "get_accounts", {}))["total_kopecks"] == 0
    assert (await call(env, "get_goals", {}))["goals"] == []
    assert (await call(env, "get_debts", {}))["debts"] == []
    summary = await call(
        env, "get_finance_summary", {"from_date": "2026-10-01", "to_date": "2026-10-31"}
    )
    assert summary["categories"] == [] and summary["months"] == []
