"""No single operation may fail a whole push (MAJOR-1): bad values are rejected per operation."""

import json
from typing import Any

import httpx
import pytest

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.test_sync_push import create_setting


def note(dc: DeviceClient, title: str = "ok", **fields: Any) -> dict[str, Any]:
    fields.setdefault("created_at", dc.created())
    return dc.op("test_notes", uuid7(), fields={"title": title, **fields})


def poisoned(dc: DeviceClient, **fields: Any) -> dict[str, Any]:
    return note(dc, **fields)


async def send(dc: DeviceClient, ops: list[dict[str, Any]]) -> httpx.Response:
    """POST the batch as ASCII JSON: httpx would refuse to encode a lone surrogate itself."""
    body = json.dumps({"ops": ops}, ensure_ascii=True).encode()
    return await dc.env.client.post(
        "/sync/push", content=body, headers={**dc.headers, "Content-Type": "application/json"}
    )


async def push_around(
    env: Env, dc: DeviceClient, poison: dict[str, Any], code: str = "invalid_field"
) -> None:
    """The poison op sits between two good ones: it is rejected, both neighbours are applied."""
    before, after = note(dc, "before"), note(dc, "after")
    response = await send(dc, [before, poison, after])
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    assert [r["status"] for r in results] == ["applied", "rejected", "applied"]
    assert results[1]["code"] == code
    titles = sorted(c["row"]["title"] for c in (await dc.pull_ok())["changes"])
    assert titles == ["after", "before"]
    # The rejection is remembered like any other: a retry returns it unchanged.
    again = await send(dc, [poison])
    assert again.json()["results"][0]["duplicate"] is True


POISON_TEXT = {
    "nul": "a\u0000b",
    "lone_surrogate": "\ud800",
    "surrogate_in_text": "ab\udfffcd",
}


@pytest.mark.parametrize("value", POISON_TEXT.values(), ids=POISON_TEXT.keys())
async def test_text_that_postgres_cannot_store_is_rejected(tree_env: Env, value: str) -> None:
    dc = await tree_env.login()
    await push_around(tree_env, dc, poisoned(dc, title=value))


POISON_JSON = {
    "nul_value": {"k": "a\u0000b"},
    "nul_key": {"a\u0000b": 1},
    "nul_nested": {"a": [1, {"b": ["x\u0000"]}]},
    "surrogate": ["\ud800"],
    "surrogate_key": {"\udc00": 1},
    "too_deep": [[[[]]]],  # replaced below with a really deep value
}


@pytest.mark.parametrize("value", POISON_JSON.values(), ids=POISON_JSON.keys())
async def test_json_that_postgres_cannot_store_is_rejected(tree_env: Env, value: Any) -> None:
    if value == [[[[]]]]:
        value = []
        for _ in range(200):
            value = [value]
    dc = await tree_env.login()
    await push_around(tree_env, dc, poisoned(dc, data=value))


async def test_user_settings_value_with_nul_is_rejected(env: Env) -> None:
    dc = await env.login()
    good = create_setting(dc, "good.one")
    bad = create_setting(dc, "bad.one", value={"deep": ["a\u0000"]})
    results = await dc.push_ok([good, bad, create_setting(dc, "good.two")])
    assert [r["status"] for r in results] == ["applied", "rejected", "applied"]
    assert results[1]["code"] == "invalid_field"


POISON_DATES = {
    "year_1_offset": "0001-01-01T00:00:00+14:00",
    "year_9999_offset": "9999-12-31T23:59:59-12:00",
    "before_1970": "1969-12-31T23:59:59Z",
    "after_2200": "2200-01-01T00:00:00Z",
    "no_timezone": "2026-10-01T12:00:00",
}


@pytest.mark.parametrize("value", POISON_DATES.values(), ids=POISON_DATES.keys())
async def test_out_of_range_datetime_column_is_rejected(tree_env: Env, value: str) -> None:
    dc = await tree_env.login()
    await push_around(tree_env, dc, poisoned(dc, due=value))


@pytest.mark.parametrize("value", POISON_DATES.values(), ids=POISON_DATES.keys())
async def test_out_of_range_created_at_is_rejected(tree_env: Env, value: str) -> None:
    dc = await tree_env.login()
    await push_around(tree_env, dc, poisoned(dc, created_at=value))


async def test_datetime_bounds_are_inclusive_lower_exclusive_upper(tree_env: Env) -> None:
    dc = await tree_env.login()
    ok = [
        note(dc, "epoch", due="1970-01-01T00:00:00Z"),
        note(dc, "last", due="2199-12-31T23:59:59.999999Z"),
        note(dc, "offset", due="2026-10-01T12:00:00+03:00", created_at="2026-10-01T00:00:00-05:00"),
    ]
    results = await dc.push_ok(ok)
    assert [r["status"] for r in results] == ["applied"] * 3
    rows = {c["row"]["title"]: c["row"] for c in (await dc.pull_ok())["changes"]}
    assert rows["offset"]["due"] == "2026-10-01T09:00:00Z"  # normalised to UTC
    assert rows["offset"]["created_at"] == "2026-10-01T05:00:00Z"


async def test_a_bad_op_in_the_middle_does_not_shift_versions(tree_env: Env) -> None:
    dc = await tree_env.login()
    results = await dc.push_ok([note(dc, "a"), poisoned(dc, title="x\u0000"), note(dc, "b")])
    assert [r["server_version"] for r in results] == [1, None, 2]
    assert (await dc.pull_ok())["head_version"] == 2


@pytest.mark.parametrize("raw", ["a\u0000b", "overflow", "value"])
async def test_safety_net_rejects_what_slips_past_the_validators(tree_env: Env, raw: str) -> None:
    """A lax column adapter lets NUL reach PostgreSQL; a validator may raise anything."""
    dc = await tree_env.login()
    bad = dc.op("test_raws", uuid7(), fields={"raw": raw, "created_at": dc.created()})
    results = await dc.push_ok([note(dc, "before"), bad, note(dc, "after")])
    assert [r["status"] for r in results] == ["applied", "rejected", "applied"]
    assert results[1]["code"] == "op_failed"
    assert results[1]["server_version"] is None
    titles = sorted(c["row"]["title"] for c in (await dc.pull_ok())["changes"])
    assert titles == ["after", "before"]
    assert (await dc.pull_ok())["head_version"] == 2


async def test_safety_net_leaves_the_transaction_usable_for_later_ops(tree_env: Env) -> None:
    dc = await tree_env.login()
    bad = dc.op("test_raws", uuid7(), fields={"raw": "\u0000", "created_at": dc.created()})
    good_raw = dc.op("test_raws", uuid7(), fields={"raw": "fine", "created_at": dc.created()})
    results = await dc.push_ok([bad, good_raw, bad_copy(bad), note(dc, "tail")])
    assert [r["status"] for r in results] == ["rejected", "applied", "rejected", "applied"]


def bad_copy(op: dict[str, Any]) -> dict[str, Any]:
    return {**op, "op_id": str(uuid7()), "id": str(uuid7())}


async def test_deeply_nested_request_body_is_a_client_error(env: Env) -> None:
    dc = await env.login()
    body = "[" * 100_000 + "]" * 100_000
    response = await env.client.post(
        "/sync/push",
        content=b'{"ops": ' + body.encode() + b"}",
        headers={**dc.headers, "Content-Type": "application/json"},
    )
    assert response.status_code < 500
