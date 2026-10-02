"""Stage 5 tables through the real sync engine: round trip, cascades, trash, offline merges,
and the Excel case computed from rows a second device pulled."""

from typing import Any

from tasker.finance import reference as ref
from tasker.finance.presets import category_id
from tasker.ids import uuid7
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env
from tests.finance_support import (
    R,
    account_fields,
    activity_seed,
    category_fields,
    debt_fields,
    excel_seed,
    repayment_fields,
    transaction_fields,
)
from tests.test_calendar_sync import deleted, pull_rows

FINANCE_NAMES = (
    "accounts",
    "categories",
    "transactions",
    "balance_checkpoints",
    "debts",
    "debt_repayments",
    "goals",
)


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def live(rows: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    return [dict(r) for r in rows.values() if r["deleted_at"] is None]


def test_registry_has_the_finance_tables_parents_first() -> None:
    names = [spec.name for spec in build_registry().tables()]
    for name in FINANCE_NAMES:
        assert name in names
    assert names.index("transactions") > names.index("accounts")
    assert names.index("balance_checkpoints") > names.index("accounts")
    assert names.index("debt_repayments") > names.index("debts")


async def test_the_excel_case_survives_the_round_trip(env: Env) -> None:
    """Spec 6.3 through the engine: everything pulled by a second device gives 454 600."""
    phone = await env.login()
    seed = await excel_seed(phone)
    pc = await env.login("PC")
    tables = await pull_rows(pc)
    accounts = live(tables["accounts"])
    goal = dict(tables["goals"][str(seed.goal)])
    assert goal["formula"][0] == {"kind": "all_accounts", "sign": "+"}
    work = {
        "projects": live(tables["projects"]),
        "change_requests": [],
        "allocations": [],
    }
    progress = ref.goal_progress(
        goal,
        accounts,
        [],
        [],
        live(tables["debts"]),
        [],
        work["projects"],
        work["change_requests"],
        work["allocations"],
    )
    assert progress["have"] == 454_600 * R
    assert progress["missing"] == -54_600 * R
    assert progress["reached"] is True
    credit = dict(tables["accounts"][str(seed.credit)])
    assert (credit["kind"], credit["credit_limit"]) == ("credit_card", 300_000 * R)
    assert dict(tables["accounts"][str(seed.card)])["card_last4"] == "1234"


async def test_activity_round_trips_and_the_books_balance(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    rows = await pull_rows(await env.login("PC"))
    transactions = live(rows["transactions"])
    assert len(transactions) == 7
    assert str(rows["transactions"][str(act.transfer)]["to_account_id"]) == str(seed.savings)
    balances = ref.account_balances(live(rows["accounts"]), transactions, [])
    by_id = {line["id"]: line["balance"] for line in balances["accounts"]}
    assert by_id[str(seed.cash)] == (54_000 - 3_000) * R
    assert by_id[str(seed.card)] == 191_500 * R
    assert by_id[str(seed.savings)] == 18_000 * R
    assert by_id[str(seed.credit)] == 125_000 * R
    assert balances["total"] == 385_500 * R
    months = ref.monthly_totals(transactions)
    assert months == [
        {"month": "2026-10", "income": 3_000_000, "expense": 250_000, "net": 2_750_000}
    ]


async def test_deleting_an_account_trashes_its_history_and_both_sides_of_transfers(
    env: Env,
) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    cp = uuid7()
    await phone.push_ok(
        [
            phone.op(
                "balance_checkpoints",
                cp,
                fields={
                    "account_id": str(seed.savings),
                    "checked_at": "2026-10-06T09:00:00Z",
                    "actual_balance": 1_800_000,
                    "source": "manual",
                    "created_at": phone.created(),
                },
            )
        ]
    )
    (result,) = await phone.push_ok(
        [phone.op("accounts", seed.savings, "delete", base=await head(phone))]
    )
    assert result["status"] == "applied"
    assert await deleted(env, "transactions") == 1  # the transfer into savings
    assert await deleted(env, "balance_checkpoints") == 1
    assert await deleted(env, "accounts") == 1
    assert await deleted(env, "debt_repayments") == 0
    rows = await pull_rows(phone)
    assert rows["transactions"][str(act.salary)]["deleted_at"] is None
    assert rows["transactions"][str(act.transfer)]["deleted_at"] is not None

    (restored,) = await phone.push_ok(
        [phone.op("accounts", seed.savings, fields={"deleted_at": None}, base=await head(phone))]
    )
    assert restored["status"] == "applied"
    for table in ("transactions", "balance_checkpoints", "accounts"):
        assert await deleted(env, table) == 0, table


async def test_deleting_the_source_account_trashes_the_transfer_too(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    await activity_seed(phone, seed)
    await phone.push_ok([phone.op("accounts", seed.card, "delete", base=await head(phone))])
    # salary, 2 groceries, taxi, transfer, draft all lived on the card
    assert await deleted(env, "transactions") == 7 - 1  # only the cash repayment stays


async def test_deleting_a_debt_trashes_repayments_but_not_the_money_movements(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    await phone.push_ok([phone.op("debts", act.debt_out, "delete", base=await head(phone))])
    assert await deleted(env, "debt_repayments") == 1
    assert await deleted(env, "transactions") == 0  # the 3 000 really left the cash account
    rows = await pull_rows(phone)
    assert rows["transactions"][str(act.repay_tx)]["debt_id"] == str(act.debt_out)  # soft link
    await phone.push_ok(
        [phone.op("debts", act.debt_out, fields={"deleted_at": None}, base=await head(phone))]
    )
    assert await deleted(env, "debt_repayments") == 0


async def test_categories_goals_and_people_cascade_nothing(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    base = await head(phone)
    await phone.push_ok(
        [
            phone.op("categories", category_id("expense.groceries"), "delete", base=base),
            phone.op("goals", seed.goal, "delete", base=base),
            phone.op("people", seed.roma, "delete", base=base),
        ]
    )
    assert await deleted(env, "transactions") == 0
    assert await deleted(env, "projects") == 0
    rows = await pull_rows(phone)
    assert rows["transactions"][str(act.food)]["category_id"] == str(
        category_id("expense.groceries")
    )
    # the deleted category is no longer a live one: its money goes to "uncategorised"
    categories = live(rows["categories"])
    breakdown = ref.category_breakdown(live(rows["transactions"]), categories, "expense")
    assert {g["category_id"] for g in breakdown["groups"]} == {
        None,
        str(category_id("expense.transport")),
    }


async def test_two_offline_devices_seeding_the_same_preset_produce_one_row(env: Env) -> None:
    phone = await env.login()
    pc = await env.login("PC")
    preset = category_id("expense.groceries")
    fields = {"name": "Продукты", "kind": "expense", "system_key": "expense.groceries"}
    (a,) = await phone.push_ok(
        [phone.op("categories", preset, fields={**fields, "created_at": phone.created()})]
    )
    (b,) = await pc.push_ok(
        [pc.op("categories", preset, fields={**fields, "created_at": pc.created()})]
    )
    assert a["status"] == "applied"
    assert b["status"] == "applied"
    assert await env.scalar("SELECT count(*) FROM categories") == 1
    # a rename on one device and an icon on the other merge field by field
    seen = await head(phone)
    await phone.push_ok([phone.op("categories", preset, fields={"name": "Еда"}, base=seen)])
    await pc.push_ok([pc.op("categories", preset, fields={"icon": "restaurant"}, base=seen)])
    row = (await pull_rows(phone))["categories"][str(preset)]
    assert (row["name"], row["icon"]) == ("Еда", "restaurant")


async def test_two_devices_importing_the_same_bank_operation_are_both_accepted_and_reported(
    env: Env,
) -> None:
    """Spec 7: uniqueness of ``external_id`` cannot be enforced row by row offline."""
    phone = await env.login()
    seed = await excel_seed(phone)
    pc = await env.login("PC")
    a, b = uuid7(), uuid7()
    for device, tx in ((phone, a), (pc, b)):
        (result,) = await device.push_ok(
            [
                device.op(
                    "transactions",
                    tx,
                    fields=transaction_fields(
                        device, seed.card, external_id="BANK-1", status="draft", source="statement"
                    ),
                )
            ]
        )
        assert result["status"] == "applied"
    rows = await pull_rows(phone)
    problems = ref.integrity_problems([], live(rows["transactions"]), [], [], [])
    assert [p["code"] for p in problems] == ["duplicate_external_id"]
    assert problems[0]["id"] == max(str(a), str(b))  # UUIDv7 of the later op sorts later


async def test_concurrent_edits_of_different_transaction_fields_merge(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    pc = await env.login("PC")
    seen = await head(phone)
    await phone.push_ok([phone.op("transactions", act.food, fields={"amount": 130_000}, base=seen)])
    await pc.push_ok([pc.op("transactions", act.food, fields={"comment": "чек"}, base=seen)])
    row = (await pull_rows(phone))["transactions"][str(act.food)]
    assert (row["amount"], row["comment"]) == (130_000, "чек")


async def test_a_draft_becomes_a_confirmed_transaction_by_an_edit(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    act = await activity_seed(phone, seed)
    before = ref.account_balances(
        live((await pull_rows(phone))["accounts"]),
        live((await pull_rows(phone))["transactions"]),
        [],
    )["total"]
    await phone.push_ok(
        [
            phone.op(
                "transactions", act.draft, fields={"status": "confirmed"}, base=await head(phone)
            )
        ]
    )
    rows = await pull_rows(phone)
    after = ref.account_balances(live(rows["accounts"]), live(rows["transactions"]), [])["total"]
    assert before - after == 999_999


async def test_a_transaction_created_under_a_deleted_account_lands_in_the_trash(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    await phone.push_ok([phone.op("accounts", seed.cash, "delete", base=await head(phone))])
    late = uuid7()
    (result,) = await phone.push_ok(
        [phone.op("transactions", late, fields=transaction_fields(phone, seed.cash))]
    )
    assert (result["status"], result["conflicts"]) == ("applied", 1)
    assert (await pull_rows(phone))["transactions"][str(late)]["deleted_at"] is not None


async def test_old_finance_tombstones_are_purged_children_first(env: Env) -> None:
    phone = await env.login()
    seed = await excel_seed(phone)
    await activity_seed(phone, seed)
    await phone.push_ok([phone.op("accounts", seed.card, "delete", base=await head(phone))])
    await phone.push_ok([phone.op("debts", seed.d1, "delete", base=await head(phone))])
    page = await phone.pull_ok(0)
    await phone.pull_ok(page["head_version"])
    env.clock.advance(days=31)
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged >= 7
    assert await env.scalar("SELECT count(*) FROM accounts") == 3
    assert await env.scalar("SELECT count(*) FROM debts") == 3  # d2, d3 and the one the user owes


async def test_account_and_debt_helpers_are_valid_rows(env: Env) -> None:
    """A new debt and a repayment can be created in one push (parent first, then child)."""
    phone = await env.login()
    debt, repayment, account, tx = uuid7(), uuid7(), uuid7(), uuid7()
    results = await phone.push_ok(
        [
            phone.op("debts", debt, fields=debt_fields(phone)),
            phone.op("debt_repayments", repayment, fields=repayment_fields(phone, debt)),
            phone.op("accounts", account, fields=account_fields(phone)),
            phone.op("transactions", tx, fields=transaction_fields(phone, account)),
            phone.op("categories", uuid7(), fields=category_fields(phone)),
        ]
    )
    assert [r["status"] for r in results] == ["applied"] * 5
