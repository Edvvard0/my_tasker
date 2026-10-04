"""The rules table through the real sync engine, and the import flows on top of Finance rows."""

import uuid
from pathlib import Path
from typing import Any

import pytest

from tasker.banks import reference as ref
from tasker.banks.tables import BANKS_TABLES, rule_id
from tasker.ids import uuid7
from tasker.sync.modules import build_registry
from tests.api_support import DeviceClient, Env
from tests.finance_support import account_fields, transaction_fields
from tests.test_calendar_sync import pull_rows
from tests.test_work_validation import Case, run_cases

CSV = (Path(__file__).resolve().parent / "data" / "banks" / "tbank_synthetic.csv").read_bytes()


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


def rule_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "merchant_key": "магнит",
        "match_type": "exact",
        "kind": "expense",
        "category_id": str(uuid7()),
        "created_at": dc.created(),
        **over,
    }


def rule_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return rule_id(fields["kind"], fields["match_type"], fields["merchant_key"])


def test_the_table_is_registered() -> None:
    names = [spec.name for spec in build_registry().tables()]
    assert "merchant_category_rules" in names
    assert [spec.name for spec in BANKS_TABLES] == ["merchant_category_rules"]


async def test_rule_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        fields = rule_fields(phone, **over)
        return (label, "merchant_category_rules", rule_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("exact rule", None),
            case("contains rule", None, match_type="contains", merchant_key="кофе хаус"),
            case("income rule", None, kind="income", merchant_key="зарплата"),
            case("key that is not normalized", "validation_failed", merchant_key="Магнит 5"),
            case("empty key", "invalid_field", merchant_key=""),
            case("long key", "invalid_field", merchant_key="а" * 201),
            case("unknown match type", "invalid_field", match_type="regex"),
            case("unknown kind", "invalid_field", kind="transfer"),
            case("category must be a uuid", "invalid_field", category_id="food"),
        ],
    )
    wrong_id = rule_fields(phone)
    (result,) = await phone.push_ok([phone.op("merchant_category_rules", uuid7(), fields=wrong_id)])
    assert (result["status"], result["code"]) == ("rejected", "invalid_id")
    missing = rule_fields(phone, merchant_key="лукойл")
    del missing["category_id"]
    (gone,) = await phone.push_ok(
        [phone.op("merchant_category_rules", rule_row_id(missing), fields=missing)]
    )
    assert (gone["status"], gone["code"]) == ("rejected", "missing_fields")


async def test_the_identity_of_a_rule_is_immutable_and_the_category_is_not(
    phone: DeviceClient,
) -> None:
    fields = rule_fields(phone)
    row_id = rule_row_id(fields)
    (created,) = await phone.push_ok([phone.op("merchant_category_rules", row_id, fields=fields)])
    version = created["server_version"]
    for column, value in (
        ("merchant_key", "лента"),
        ("match_type", "contains"),
        ("kind", "income"),
    ):
        (rejected,) = await phone.push_ok(
            [phone.op("merchant_category_rules", row_id, fields={column: value}, base=version)]
        )
        assert rejected["code"] == "immutable_field", column
    new_category = str(uuid7())
    (changed,) = await phone.push_ok(
        [
            phone.op(
                "merchant_category_rules",
                row_id,
                fields={"category_id": new_category},
                base=version,
            )
        ]
    )
    assert changed["status"] == "applied"


async def test_two_devices_adding_the_same_rule_make_one_row(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    fields = {"merchant_key": "пятерочка", "match_type": "exact", "kind": "expense"}
    first = rule_fields(phone, **fields)
    second = rule_fields(pc, **fields)
    row_id = rule_row_id(first)
    assert row_id == rule_row_id(second)
    await phone.push_ok([phone.op("merchant_category_rules", row_id, fields=first)])
    await pc.push_ok([pc.op("merchant_category_rules", row_id, fields=second)])
    assert await env.scalar("SELECT count(*) FROM merchant_category_rules") == 1
    rows = (await pull_rows(phone))["merchant_category_rules"]
    assert list(rows) == [str(row_id)]


async def test_delete_and_restore(env: Env, phone: DeviceClient) -> None:
    fields = rule_fields(phone)
    row_id = rule_row_id(fields)
    await phone.push_ok([phone.op("merchant_category_rules", row_id, fields=fields)])
    await phone.push_ok([phone.op("merchant_category_rules", row_id, "delete", base=1)])
    assert (
        await env.scalar("SELECT count(*) FROM merchant_category_rules WHERE deleted_at IS NULL")
        == 0
    )
    await phone.push_ok(
        [phone.op("merchant_category_rules", row_id, fields={"deleted_at": None}, base=2)]
    )
    assert (
        await env.scalar("SELECT count(*) FROM merchant_category_rules WHERE deleted_at IS NULL")
        == 1
    )


# ------------------------------------------------------------------ the import flows


async def _parse(dc: DeviceClient, data: bytes) -> dict[str, Any]:
    response = await dc.env.client.post("/banks/statements/parse", content=data, headers=dc.headers)
    assert response.status_code == 200, response.text
    body: dict[str, Any] = response.json()
    return body


async def _existing(dc: DeviceClient) -> list[dict[str, Any]]:
    rows = (await pull_rows(dc)).get("transactions", {})
    return [dict(r) for r in rows.values() if r["deleted_at"] is None]


async def _import(
    dc: DeviceClient, account: uuid.UUID, parsed: dict[str, Any], decisions: list[dict[str, Any]]
) -> int:
    """The wizard: create a transaction for every candidate decided ``new``."""
    ops = []
    for candidate, decision in zip(parsed["candidates"], decisions, strict=True):
        if decision["action"] != "new":
            continue
        fields = transaction_fields(
            dc,
            account,
            kind=candidate["kind"],
            amount=candidate["amount"],
            occurred_at=candidate["occurred_at"],
            merchant=candidate["merchant"],
            source="statement",
            status="needs_review" if candidate["needs_review"] else "confirmed",
            dedup_hash=decision["dedup_hash"],
        )
        ops.append(dc.op("transactions", uuid7(), fields=fields))
    if ops:
        results = await dc.push_ok(ops)
        assert {r["status"] for r in results} == {"applied"}
    return len(ops)


async def test_a_statement_is_imported_without_duplicates(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    account = uuid7()
    await phone.push_ok(
        [phone.op("accounts", account, fields=account_fields(phone, card_last4="1234"))]
    )
    parsed = await _parse(phone, CSV)
    first = ref.classify_candidates(str(account), parsed["candidates"], await _existing(phone))
    assert [d["action"] for d in first] == ["new"] * 6
    assert len({d["dedup_hash"] for d in first}) == 6  # the two identical taxis differ
    assert await _import(phone, account, parsed, first) == 6
    # the same file again, from another device: everything is a duplicate
    again = ref.classify_candidates(str(account), parsed["candidates"], await _existing(pc))
    assert {d["action"] for d in again} == {"duplicate"}
    assert {d["reason"] for d in again} == {"hash"}
    # a longer statement that overlaps: only the new line is new
    extra = "08.10.2026 12:00:00;08.10.2026;*1234;OK;-77,00;RUB;-77,00;RUB;;Кафе;5812;"
    longer = CSV + (extra + "Кофейня;;;77,00\n").encode()
    overlap = await _parse(pc, longer)
    third = ref.classify_candidates(str(account), overlap["candidates"], await _existing(pc))
    assert [d["action"] for d in third] == ["duplicate"] * 6 + ["new"]
    await _import(pc, account, overlap, third)
    assert await env.scalar("SELECT count(*) FROM transactions") == 7


async def test_a_notification_draft_is_refined_by_the_statement_not_doubled(env: Env) -> None:
    phone = await env.login()
    account = uuid7()
    draft = uuid7()
    await phone.push_ok(
        [
            phone.op("accounts", account, fields=account_fields(phone, card_last4="1234")),
            phone.op(
                "transactions",
                draft,
                fields=transaction_fields(
                    phone,
                    account,
                    amount=123_456,
                    occurred_at="2026-10-03T08:29:50Z",
                    merchant="ПЯТЁРОЧКА",
                    source="notification",
                    status="draft",
                ),
            ),
        ]
    )
    parsed = await _parse(phone, CSV)
    found = ref.classify_candidates(str(account), parsed["candidates"], await _existing(phone))
    assert found[0]["action"] == "merge"
    assert found[0]["existing_id"] == str(draft)
    assert found[0]["refine"] == {
        "occurred_at": "2026-10-03T08:30:12Z",
        "merchant": "Пятёрочка 1234",
    }
    assert [d["action"] for d in found[1:]] == ["new"] * 5
    assert await _import(phone, account, parsed, found) == 5
    assert await env.scalar("SELECT count(*) FROM transactions") == 6
