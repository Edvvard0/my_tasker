"""Server-side validation of the Stage 5 tables, driven through the real push endpoint."""

import uuid
from typing import Any

import pytest

from tasker.finance.presets import category_id
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.finance_support import (
    account_fields,
    category_fields,
    checkpoint_fields,
    debt_fields,
    goal_fields,
    repayment_fields,
    term,
    transaction_fields,
)
from tests.test_work_validation import Case, run_cases


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


async def test_account_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, /, **over: Any) -> Case:
        return (label, "accounts", None, account_fields(phone, **over), expected)

    await run_cases(
        phone,
        [
            case("plain account", None),
            case(
                "credit card with limit and digits",
                None,
                kind="credit_card",
                credit_limit=30_000_000,
                card_last4="0042",
                bank="Т-Банк",
            ),
            case("negative opening balance", None, opening_balance=-5_000),
            case("max opening balance", None, opening_balance=99_999_999_999_999),
            case("opening balance too large", "invalid_field", opening_balance=10**14),
            case("opening balance too small", "invalid_field", opening_balance=-(10**14)),
            case("float balance", "invalid_field", opening_balance=10.5),
            case("string balance", "invalid_field", opening_balance="100"),
            case("bool balance", "invalid_field", opening_balance=True),
            case("unknown kind", "invalid_field", kind="wallet"),
            case("all kinds", None, kind="deposit"),
            case("blank name", "validation_failed", name="  "),
            case("long name", "invalid_field", name="x" * 101),
            case("limit on a debit card", "validation_failed", credit_limit=1),
            case("negative limit", "invalid_field", kind="credit_card", credit_limit=-1),
            case("digits on cash", "validation_failed", kind="cash", card_last4="1234"),
            case("three digits", "invalid_field", card_last4="123"),
            case("letters instead of digits", "invalid_field", card_last4="12a4"),
            case("not a date", "invalid_field", opening_date="1.01.2026"),
            case("february 30", "validation_failed", opening_date="2026-02-30"),
            case("flags are required booleans", "invalid_field", include_in_total="yes"),
        ],
    )


async def test_missing_required_account_columns(phone: DeviceClient) -> None:
    fields = account_fields(phone)
    del fields["opening_date"]
    (result,) = await phone.push_ok([phone.op("accounts", uuid7(), fields=fields)])
    assert (result["status"], result["code"]) == ("rejected", "missing_fields")


async def test_category_columns_and_preset_ids(phone: DeviceClient) -> None:
    preset = category_id("expense.groceries")

    def case(
        label: str, expected: str | None, row_id: uuid.UUID | None = None, /, **over: Any
    ) -> Case:
        return (label, "categories", row_id, category_fields(phone, **over), expected)

    await run_cases(
        phone,
        [
            case("a deterministic id without a key", "invalid_id", preset),
            case("custom category", None),
            case("subcategory with a soft parent", None, parent_id=str(uuid7())),
            case("icon and color", None, icon="coffee", color="#1A73E8"),
            case("bad color", "invalid_field", color="blue"),
            case("unknown kind", "invalid_field", kind="transfer"),
            case("blank name", "validation_failed", name=" "),
            case("preset with the deterministic id", None, preset, system_key="expense.groceries"),
            case("preset with a random id", "invalid_id", None, system_key="expense.groceries"),
            case(
                "preset key of another id",
                "invalid_id",
                category_id("income.other"),
                system_key="expense.groceries",
            ),
            case(
                "unknown preset key with a deterministic id",
                "invalid_id",
                category_id("expense.nope"),
                system_key="expense.nope",
            ),
            case(
                "unknown preset key with a UUIDv7",
                "validation_failed",
                uuid7(),
                system_key="expense.nope",
            ),
            case("preset can be pushed twice", None, preset, system_key="expense.groceries"),
        ],
    )


async def test_transaction_columns(phone: DeviceClient) -> None:
    account, other = uuid7(), uuid7()
    await run_cases(
        phone,
        [
            ("a", "accounts", account, account_fields(phone), None),
            ("b", "accounts", other, account_fields(phone, name="Вторая"), None),
        ],
    )

    def case(label: str, expected: str | None, /, **over: Any) -> Case:
        return (label, "transactions", None, transaction_fields(phone, account, **over), expected)

    def transfer(**over: Any) -> dict[str, Any]:
        return {"kind": "transfer", "to_account_id": str(other), **over}

    await run_cases(
        phone,
        [
            case("expense", None),
            case(
                "income with all optional columns",
                None,
                kind="income",
                merchant="ООО",
                comment="c",
                category_id=str(uuid7()),
                external_id="OP-1",
                dedup_hash="ab" * 16,
            ),
            case("transfer", None, **transfer()),
            case("draft", None, status="draft", source="notification"),
            case("needs review from a statement", None, status="needs_review", source="statement"),
            case("zero amount", "invalid_field", amount=0),
            case("negative amount", "invalid_field", amount=-1),
            case("float amount", "invalid_field", amount=1.5),
            case("amount too large", "invalid_field", amount=10**14),
            case("unknown kind", "invalid_field", kind="refund"),
            case("unknown source", "invalid_field", source="zenmoney"),
            case("unknown status", "invalid_field", status="void"),
            case("before 2015", "validation_failed", occurred_at="2014-12-31T23:59:59Z"),
            case("naive time", "invalid_field", occurred_at="2026-10-05T09:00:00"),
            case("transfer without a destination", "validation_failed", kind="transfer"),
            case(
                "transfer to itself",
                "validation_failed",
                kind="transfer",
                to_account_id=str(account),
            ),
            case(
                "transfer with a category",
                "validation_failed",
                **transfer(category_id=str(uuid7())),
            ),
            case("transfer with a debt", "validation_failed", **transfer(debt_id=str(uuid7()))),
            case(
                "transfer with a work payment",
                "validation_failed",
                **transfer(work_payment_id=str(uuid7()), source="work_payment"),
            ),
            case("expense with a destination", "validation_failed", to_account_id=str(other)),
            case(
                "income from a work payment",
                None,
                kind="income",
                source="work_payment",
                work_payment_id=str(uuid7()),
            ),
            case(
                "work payment source without a link",
                "validation_failed",
                kind="income",
                source="work_payment",
            ),
            case(
                "work payment link on a manual source",
                "validation_failed",
                kind="income",
                work_payment_id=str(uuid7()),
            ),
            case(
                "work payment link on an expense",
                "validation_failed",
                source="work_payment",
                work_payment_id=str(uuid7()),
            ),
            case("debt movement", None, debt_id=str(uuid7())),
            case("empty external id", "invalid_field", external_id=""),
            case("long external id", "invalid_field", external_id="x" * 201),
            case("hash with capitals", "invalid_field", dedup_hash="AB" * 16),
            case("hash too short", "invalid_field", dedup_hash="ab" * 7),
            case("long merchant", "invalid_field", merchant="x" * 201),
            case("the same external id twice is accepted (spec 7)", None, external_id="OP-1"),
            (
                "orphan",
                "transactions",
                None,
                transaction_fields(phone, uuid7()),
                "parent_not_found",
            ),
            (
                "missing destination account",
                "transactions",
                None,
                transaction_fields(phone, account, **transfer(to_account_id=str(uuid7()))),
                "parent_not_found",
            ),
        ],
    )


async def test_checkpoint_debt_repayment_and_goal_columns(phone: DeviceClient) -> None:
    account, debt = uuid7(), uuid7()
    await run_cases(
        phone,
        [
            ("account", "accounts", account, account_fields(phone), None),
            ("debt", "debts", debt, debt_fields(phone), None),
        ],
    )

    def checkpoint(label: str, expected: str | None, /, **over: Any) -> Case:
        return (
            label,
            "balance_checkpoints",
            None,
            checkpoint_fields(phone, account, **over),
            expected,
        )

    def d(label: str, expected: str | None, /, **over: Any) -> Case:
        return (label, "debts", None, debt_fields(phone, **over), expected)

    def repayment(label: str, expected: str | None, /, **over: Any) -> Case:
        return (label, "debt_repayments", None, repayment_fields(phone, debt, **over), expected)

    def goal(label: str, expected: str | None, /, **over: Any) -> Case:
        return (label, "goals", None, goal_fields(phone, **over), expected)

    ids = [str(uuid7()), str(uuid7())]
    await run_cases(
        phone,
        [
            checkpoint("checkpoint", None),
            checkpoint("negative actual balance", None, actual_balance=-100),
            checkpoint("statement source", None, source="statement", note="выписка"),
            checkpoint("unknown source", "invalid_field", source="zenmoney"),
            checkpoint("before 2015", "validation_failed", checked_at="2014-01-01T00:00:00Z"),
            checkpoint("float balance", "invalid_field", actual_balance=1.5),
            (
                "checkpoint of a missing account",
                "balance_checkpoints",
                None,
                checkpoint_fields(phone, uuid7()),
                "parent_not_found",
            ),
            d("debt to a text counterparty", None),
            d("debt to a person", None, counterparty=None, person_id=str(uuid7())),
            d("i owe", None, direction="i_owe", due_date="2026-12-01", comment="c"),
            d("nobody", "validation_failed", counterparty=None),
            d("blank counterparty", "validation_failed", counterparty="  "),
            d("zero amount", "invalid_field", amount=0),
            d("unknown direction", "invalid_field", direction="both"),
            d("due before the debt", "validation_failed", due_date="2026-08-31"),
            d("due on the day", None, due_date="2026-09-01"),
            d("impossible date", "validation_failed", debt_date="2026-02-30"),
            d("bad date format", "invalid_field", debt_date="01.09.2026"),
            repayment("repayment", None),
            repayment("repayment with a transaction", None, transaction_id=str(uuid7())),
            repayment("zero repayment", "invalid_field", amount=0),
            repayment("impossible date", "validation_failed", repaid_on="2026-02-30"),
            (
                "repayment of a missing debt",
                "debt_repayments",
                None,
                repayment_fields(phone, uuid7()),
                "parent_not_found",
            ),
            goal("default goal", None),
            goal("goal with a deadline", None, deadline_date="2026-12-31"),
            goal("zero target", "invalid_field", target_amount=0),
            goal("blank name", "validation_failed", name=" "),
            goal("impossible deadline", "validation_failed", deadline_date="2026-02-30"),
            goal(
                "account terms",
                None,
                formula=[term("accounts", account_ids=ids), term("my_debts", "-")],
            ),
            goal("receivables of customers", None, formula=[term("receivables", client_ids=ids)]),
            goal("empty formula", "validation_failed", formula=[]),
            goal("formula is not a list", "validation_failed", formula={"kind": "all_accounts"}),
            goal("31 terms", "validation_failed", formula=[term("all_accounts")] * 31),
            goal("unknown kind", "validation_failed", formula=[term("salary")]),
            goal("no sign", "validation_failed", formula=[{"kind": "all_accounts"}]),
            goal("bad sign", "validation_failed", formula=[term("all_accounts", "*")]),
            goal(
                "foreign key in a term",
                "validation_failed",
                formula=[term("debts_to_me", account_ids=ids)],
            ),
            goal("accounts term without ids", "validation_failed", formula=[term("accounts")]),
            goal(
                "accounts term with no ids",
                "validation_failed",
                formula=[term("accounts", account_ids=[])],
            ),
            goal(
                "51 ids",
                "validation_failed",
                formula=[term("accounts", account_ids=[str(uuid7()) for _ in range(51)])],
            ),
            goal(
                "ids in capitals",
                "validation_failed",
                formula=[term("accounts", account_ids=[ids[0].upper()])],
            ),
            goal(
                "not a uuid", "validation_failed", formula=[term("accounts", account_ids=["nope"])]
            ),
            goal(
                "a number as an id",
                "validation_failed",
                formula=[term("accounts", account_ids=[5])],
            ),
            goal(
                "empty customer list",
                "validation_failed",
                formula=[term("receivables", client_ids=[])],
            ),
            goal("term is not an object", "validation_failed", formula=["all_accounts"]),
            goal(
                "formula too big",
                "invalid_field",
                formula=[term("receivables", client_ids=[str(uuid7())] * 50)] * 30,
            ),
        ],
    )


async def test_immutable_columns(env: Env) -> None:
    phone = await env.login()
    first, second, debt, other_debt, cat = uuid7(), uuid7(), uuid7(), uuid7(), uuid7()
    checkpoint = uuid7()
    repayment = uuid7()
    preset = category_id("expense.groceries")
    await phone.push_ok(
        [
            phone.op("accounts", first, fields=account_fields(phone)),
            phone.op("accounts", second, fields=account_fields(phone, name="Вторая")),
            phone.op("balance_checkpoints", checkpoint, fields=checkpoint_fields(phone, first)),
            phone.op("debts", debt, fields=debt_fields(phone)),
            phone.op("debts", other_debt, fields=debt_fields(phone)),
            phone.op("debt_repayments", repayment, fields=repayment_fields(phone, debt)),
            phone.op("categories", cat, fields=category_fields(phone)),
            phone.op(
                "categories", preset, fields=category_fields(phone, system_key="expense.groceries")
            ),
        ]
    )
    head = (await phone.pull_ok(0))["head_version"]
    results = await phone.push_ok(
        [
            phone.op(
                "balance_checkpoints", checkpoint, fields={"account_id": str(second)}, base=head
            ),
            phone.op("debt_repayments", repayment, fields={"debt_id": str(other_debt)}, base=head),
            phone.op("categories", preset, fields={"system_key": "expense.other"}, base=head),
            phone.op("categories", cat, fields={"system_key": "expense.other"}, base=head),
            phone.op("balance_checkpoints", checkpoint, fields={"actual_balance": 1}, base=head),
            phone.op("debt_repayments", repayment, fields={"amount": 5}, base=head),
        ]
    )
    assert [r["code"] for r in results] == ["immutable_field"] * 4 + [None, None]


async def test_edits_that_break_an_invariant_are_rejected(env: Env) -> None:
    phone = await env.login()
    first, second, tx = uuid7(), uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op("accounts", first, fields=account_fields(phone)),
            phone.op("accounts", second, fields=account_fields(phone, name="Вторая")),
            phone.op("transactions", tx, fields=transaction_fields(phone, first)),
        ]
    )
    head = (await phone.pull_ok(0))["head_version"]
    results = await phone.push_ok(
        [
            phone.op("transactions", tx, fields={"kind": "transfer"}, base=head),
            phone.op("transactions", tx, fields={"to_account_id": str(second)}, base=head),
            phone.op("accounts", first, fields={"credit_limit": 5}, base=head),
            phone.op(
                "accounts", first, fields={"kind": "credit_card", "credit_limit": 5}, base=head
            ),
        ]
    )
    assert [r["code"] for r in results] == ["validation_failed"] * 3 + [None]
    (ok,) = await phone.push_ok(
        [
            phone.op(
                "transactions",
                tx,
                fields={"kind": "transfer", "to_account_id": str(second)},
                base=head,
            )
        ]
    )
    assert ok["status"] == "applied"
