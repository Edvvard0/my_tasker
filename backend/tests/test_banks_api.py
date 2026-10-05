"""POST /banks/statements/parse: access, limits, errors, nothing is stored."""

import os
import tempfile
import time
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from tasker.banks import api as banks_api
from tasker.banks import statements
from tasker.banks.tables import rule_id
from tasker.ids import uuid7
from tests.api_support import SCHEMA, DeviceClient, Env, make_env

DATA = Path(__file__).resolve().parent / "data" / "banks"
CSV = (DATA / "tbank_synthetic.csv").read_bytes()
PDF = (DATA / "vtb_synthetic.pdf").read_bytes()
URL = "/banks/statements/parse"
SYNC_TABLES = ("transactions", "accounts", "balance_checkpoints", "merchant_category_rules")


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


async def upload(dc: DeviceClient, data: bytes | AsyncIterator[bytes], **params: str) -> Any:
    return await dc.env.client.post(URL, content=data, params=params, headers=dc.headers)


async def test_parse_returns_candidates(phone: DeviceClient) -> None:
    response = await upload(phone, CSV)
    assert response.status_code == 200, response.text
    body = response.json()
    assert (body["format"], body["bank"], body["cards"]) == ("csv", "tbank", ["1234"])
    assert len(body["candidates"]) == 6
    assert body["candidates"][0]["dedup_tail"].startswith("expense|123456|")


async def test_parse_a_pdf_with_the_format_given(phone: DeviceClient) -> None:
    response = await upload(phone, PDF, format="pdf", bank="vtb")
    assert response.status_code == 200, response.text
    assert response.json()["closing_balance"]["amount"] == 10_201_545


async def test_the_closing_balance_is_not_later_than_the_server_clock(
    env: Env, phone: DeviceClient
) -> None:
    today = (
        "Период с 01.10.2026 по 01.10.2026\nОстаток на конец периода: 1 234,50 RUB\n"
        "Дата;Сумма;Описание;Валюта\n01.10.2026;-100;Кофе;RUB\n"
    ).encode()
    response = await upload(phone, today)
    assert response.status_code == 200, response.text
    closing = response.json()["closing_balance"]
    assert closing["amount"] == 123_450
    assert closing["at"] == env.clock.now().strftime("%Y-%m-%dT%H:%M:%SZ")
    assert env.clock.now().date() == datetime(2026, 10, 1, tzinfo=UTC).date()


async def test_authentication_is_required(env: Env, phone: DeviceClient) -> None:
    client = env.client
    assert (await client.post(URL, content=CSV, headers=SCHEMA)).status_code == 401
    bad = {"Authorization": "Bearer nonsense", **SCHEMA}
    assert (await client.post(URL, content=CSV, headers=bad)).status_code == 401
    no_schema = {"Authorization": f"Bearer {phone.access_token}"}
    assert (await client.post(URL, content=CSV, headers=no_schema)).status_code == 400
    await env.execute("UPDATE devices SET revoked_at = now()")
    revoked = await client.post(URL, content=CSV, headers=phone.headers)
    assert (revoked.status_code, revoked.json()["error"]["code"]) == (401, "device_revoked")


async def test_empty_and_unreadable_files(phone: DeviceClient) -> None:
    empty = await upload(phone, b"")
    assert (empty.status_code, empty.json()["error"]["code"]) == (400, "empty_file")
    text = await upload(phone, b"hello;world\n1;2\n")
    assert (text.status_code, text.json()["error"]["code"]) == (422, "statement_unrecognized")
    mismatch = await upload(phone, CSV, format="pdf")
    assert (mismatch.status_code, mismatch.json()["error"]["code"]) == (
        422,
        "statement_format_mismatch",
    )
    garbage = await upload(phone, b"%PDF-1.4 garbage")
    assert garbage.json()["error"]["code"] == "statement_unreadable"
    bank = await upload(phone, CSV, bank="alfa")
    assert bank.status_code == 422
    kind = await upload(phone, CSV, format="docx")
    assert kind.status_code == 422


async def test_the_size_limit(migrated_db_url: str) -> None:
    async with make_env(migrated_db_url, banks_statement_max_bytes=1024) as small:
        dc = await small.login()
        by_header = await upload(dc, CSV)  # content-length is known up front
        assert by_header.status_code == 413
        assert by_header.json()["error"]["code"] == "payload_too_large"
        assert by_header.json()["error"]["details"] == {"max_bytes": 1024}

        async def chunks() -> AsyncIterator[bytes]:  # chunked: no length, counted while reading
            for start in range(0, len(CSV), 200):
                yield CSV[start : start + 200]

        streamed = await upload(dc, chunks())
        assert streamed.status_code == 413
        fits = await upload(dc, CSV[:1000].rsplit(b"\n", 1)[0] + b"\n")
        assert fits.status_code == 200


async def test_the_file_is_not_stored_anywhere(
    env: Env, phone: DeviceClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path))
    before = {name: await env.scalar(f"SELECT count(*) FROM {name}") for name in SYNC_TABLES}  # noqa: S608
    for data in (CSV, PDF):
        assert (await upload(phone, data)).status_code == 200
    assert os.listdir(tmp_path) == []
    after = {name: await env.scalar(f"SELECT count(*) FROM {name}") for name in SYNC_TABLES}  # noqa: S608
    assert after == before == dict.fromkeys(SYNC_TABLES, 0)
    assert await env.scalar("SELECT count(*) FROM sync_ops") == 0


async def test_a_parser_that_hangs_does_not_hang_the_request(
    phone: DeviceClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    def slow(*_args: object) -> dict[str, Any]:
        time.sleep(1.0)
        return {}

    monkeypatch.setattr(banks_api, "parse_statement", slow)
    monkeypatch.setattr(statements, "PARSE_HARD_SECONDS", 0.05)
    response = await upload(phone, CSV)
    assert (response.status_code, response.json()["error"]["code"]) == (422, "statement_too_large")


async def test_the_users_own_rules_feed_the_suggestions(phone: DeviceClient) -> None:
    category = uuid7()
    key = "yandex taxi"
    rid = rule_id("expense", "exact", key)
    other = rule_id("income", "exact", "магнит")
    results = await phone.push_ok(
        [
            phone.op(
                "merchant_category_rules",
                rid,
                fields={
                    "merchant_key": key,
                    "match_type": "exact",
                    "kind": "expense",
                    "category_id": str(category),
                    "created_at": phone.created(),
                },
            ),
            phone.op(
                "merchant_category_rules",
                other,
                fields={
                    "merchant_key": "магнит",
                    "match_type": "exact",
                    "kind": "income",
                    "category_id": str(category),
                    "created_at": phone.created(),
                },
            ),
        ]
    )
    assert [r["status"] for r in results] == ["applied", "applied"]
    suggested = {
        c["merchant"]: c["suggested_category"]
        for c in (await upload(phone, CSV)).json()["candidates"]
    }
    assert suggested["Yandex Taxi"] == {
        "source": "user",
        "category_id": str(category),
        "system_key": None,
    }
    assert suggested["Магнит"]["source"] == "user"  # the income rule fits the refund line
    await phone.push_ok([phone.op("merchant_category_rules", rid, "delete", base=1)])
    again = {
        c["merchant"]: c["suggested_category"]
        for c in (await upload(phone, CSV)).json()["candidates"]
    }
    assert again["Yandex Taxi"]["source"] == "keyword"
