import uuid
from typing import Any

import pytest

from tasker.ids import uuid7
from tasker.sync.user_settings import settings_id
from tests.api_support import Env
from tests.test_auth_api import error_code

THEME = settings_id("ui.theme")


def create_setting(
    dc: Any, key: str = "ui.theme", value: Any = "dark", **kw: Any
) -> dict[str, Any]:
    op: dict[str, Any] = dc.op(
        "user_settings",
        settings_id(key),
        fields={"key": key, "value": value, "created_at": dc.created()},
        **kw,
    )
    return op


async def test_create_and_pull_a_setting(env: Env) -> None:
    phone = await env.login()
    (result,) = await phone.push_ok([create_setting(phone)])
    assert result["status"] == "applied"
    assert result["server_version"] == 1
    assert result["conflicts"] == 0
    assert result["duplicate"] is False
    pc = await env.login("PC")
    page = await pc.pull_ok()
    (change,) = page["changes"]
    assert change["table"] == "user_settings"
    row = change["row"]
    assert row["id"] == str(THEME)
    assert (row["key"], row["value"]) == ("ui.theme", "dark")
    assert row["server_version"] == 1
    assert row["deleted_at"] is None
    assert row["origin_device_id"] == str(phone.device_id)
    assert row["created_at"].endswith("Z")
    assert row["updated_at"].endswith(str(phone.device_id))
    assert (page["next_since"], page["head_version"], page["has_more"]) == (1, 1, False)


async def test_update_changes_only_sent_fields(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone, value={"a": 1})])
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"value": {"a": 2}}, base=1)]
    )
    assert result["server_version"] == 2
    (change,) = (await phone.pull_ok(1))["changes"]
    assert change["row"]["value"] == {"a": 2}
    assert change["row"]["key"] == "ui.theme"


async def test_equal_value_is_a_noop(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"value": "dark"}, base=1)]
    )
    # Nothing changes, but the row gets a new version so that it comes back in the next pull.
    assert (result["status"], result["server_version"], result["conflicts"]) == ("applied", 2, 0)
    (change,) = (await phone.pull_ok(1))["changes"]
    assert (change["row"]["value"], change["server_version"]) == ("dark", 2)
    assert await env.scalar("SELECT count(*) FROM sync_conflicts") == 0


async def test_json_values_of_every_kind(env: Env) -> None:
    phone = await env.login()
    values = [None or 0, 1.5, True, "text", [1, {"x": None}], {"deep": {"a": [1, 2]}}, ""]
    ops = [create_setting(phone, f"k{i}", value) for i, value in enumerate(values)]
    assert all(r["status"] == "applied" for r in await phone.push_ok(ops))
    rows = {c["row"]["key"]: c["row"]["value"] for c in (await phone.pull_ok())["changes"]}
    assert rows == {f"k{i}": value for i, value in enumerate(values)}


async def test_true_and_one_are_different_values(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone, value=1)])
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"value": True}, base=1)]
    )
    assert result["server_version"] == 2


async def test_delete_and_restore(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    env.clock.advance(seconds=5)
    (deleted,) = await phone.push_ok([phone.op("user_settings", THEME, "delete", base=1)])
    assert deleted["server_version"] == 2
    (change,) = (await phone.pull_ok(1))["changes"]
    assert change["row"]["deleted_at"] == phone.created()
    assert change["row"]["value"] == "dark"  # tombstones carry the full row
    env.clock.advance(seconds=5)
    (restored,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"deleted_at": None}, base=2)]
    )
    assert restored["server_version"] == 3
    (change,) = (await phone.pull_ok(2))["changes"]
    assert change["row"]["deleted_at"] is None


async def test_delete_is_idempotent_and_missing_rows_are_noops(env: Env) -> None:
    phone = await env.login()
    missing = await phone.push_ok([phone.op("user_settings", THEME, "delete")])
    assert missing[0]["status"] == "applied"
    assert missing[0]["server_version"] is None
    await phone.push_ok([create_setting(phone)])
    await phone.push_ok([phone.op("user_settings", THEME, "delete", base=1)])
    (again,) = await phone.push_ok([phone.op("user_settings", THEME, "delete", base=1)])
    assert (again["status"], again["server_version"]) == ("applied", 3)
    (change,) = (await phone.pull_ok(2))["changes"]
    assert change["row"]["deleted_at"] is not None


async def test_restore_of_a_live_row_is_a_noop(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"deleted_at": None}, base=1)]
    )
    assert result["server_version"] == 2
    assert (await phone.pull_ok(1))["changes"][0]["row"]["deleted_at"] is None


async def test_unknown_columns_and_service_keys_are_ignored(env: Env) -> None:
    phone = await env.login()
    op = create_setting(phone)
    op["fields"].update(
        future_column="x", server_version=999, id=str(uuid.uuid4()), origin_device_id="nope"
    )
    op["future_top_level"] = 1
    (result,) = await phone.push_ok([op])
    assert result["status"] == "applied"
    (change,) = (await phone.pull_ok())["changes"]
    assert change["row"]["server_version"] == 1
    assert change["row"]["id"] == str(THEME)
    assert "future_column" not in change["row"]


async def test_created_at_is_immutable_after_creation(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    original = (await phone.pull_ok())["changes"][0]["row"]["created_at"]
    op = phone.op(
        "user_settings", THEME, fields={"created_at": "2001-01-01T00:00:00Z", "value": 1}, base=1
    )
    await phone.push_ok([op])
    assert (await phone.pull_ok())["changes"][0]["row"]["created_at"] == original


REJECTIONS: list[tuple[str, Any, str]] = [
    ("not_object", "just a string", "invalid_op"),
    ("no_type", {"op_id": None}, "invalid_id"),
    ("bad_type", {"type": "merge"}, "invalid_op"),
    ("unknown_table", {"table": "nope"}, "unknown_table"),
    ("bad_row_id", {"id": "123"}, "invalid_id"),
    ("upper_row_id", {"id": str(THEME).upper()}, "invalid_id"),
    ("wrong_settings_id", {"id": str(uuid7())}, "invalid_id"),
    ("bad_hlc", {"hlc": "nope"}, "invalid_hlc"),
    ("hlc_number", {"hlc": 5}, "invalid_hlc"),
    ("hlc_other_device", {"hlc": f"001790000000000-00000-{uuid.uuid4()}"}, "hlc_device_mismatch"),
    ("bad_base", {"base_version": -1}, "invalid_op"),
    ("base_bool", {"base_version": True}, "invalid_op"),
    ("base_str", {"base_version": "1"}, "invalid_op"),
    ("fields_not_object", {"fields": [1]}, "invalid_op"),
    ("missing_value", {"fields": {"key": "ui.theme"}}, "missing_fields"),
    ("missing_created_at", {"fields": {"key": "ui.theme", "value": 1}}, "missing_fields"),
    ("bad_key", {"fields": {"key": "Bad Key", "value": 1}}, "invalid_field"),
    ("key_not_string", {"fields": {"key": 5, "value": 1}}, "invalid_field"),
    ("null_value", {"fields": {"key": "ui.theme", "value": None}}, "invalid_field"),
    ("huge_value", {"fields": {"key": "ui.theme", "value": "x" * 20000}}, "invalid_field"),
    (
        "bad_created_at",
        {"fields": {"key": "ui.theme", "value": 1, "created_at": "x"}},
        "invalid_field",
    ),
    (
        "naive_created_at",
        {"fields": {"key": "ui.theme", "value": 1, "created_at": "2026-01-01T00:00:00"}},
        "invalid_field",
    ),
    (
        "deleted_at_set",
        {"fields": {"key": "ui.theme", "value": 1, "deleted_at": "2026-01-01T00:00:00Z"}},
        "invalid_field",
    ),
]


@pytest.mark.parametrize(("name", "patch", "code"), REJECTIONS, ids=[r[0] for r in REJECTIONS])
async def test_invalid_operations_are_rejected_without_blocking_others(
    env: Env, name: str, patch: Any, code: str
) -> None:
    phone = await env.login()
    good = create_setting(phone, "good.key")
    if isinstance(patch, str):
        bad: Any = patch
    else:
        bad = create_setting(phone)
        bad["fields"]["created_at"] = phone.created()
        for key, value in patch.items():
            bad[key] = value
        if "fields" in patch and isinstance(patch["fields"], dict):
            bad["fields"] = dict(patch["fields"])
    results = await phone.push_ok([bad, good])
    assert results[0]["status"] == "rejected", name
    assert results[0]["code"] == code, (name, results[0])
    assert results[0]["message"]
    assert results[0]["server_version"] is None
    assert results[1]["status"] == "applied"
    assert len((await phone.pull_ok())["changes"]) == 1


async def test_rejected_operation_is_journaled_and_replayed(env: Env) -> None:
    phone = await env.login()
    bad = create_setting(phone)
    bad["fields"] = {"key": "ui.theme"}
    first = (await phone.push_ok([bad]))[0]
    second = (await phone.push_ok([bad]))[0]
    assert first["code"] == "missing_fields"
    assert (second["code"], second["duplicate"]) == ("missing_fields", True)


async def test_batch_size_limits(env: Env) -> None:
    phone = await env.login()
    ops = [create_setting(phone, f"k{i}") for i in range(500)]
    results = await phone.push_ok(ops)
    assert len(results) == 500
    assert all(r["status"] == "applied" for r in results)
    too_many = await phone.push([create_setting(phone, f"z{i}") for i in range(501)])
    assert (too_many.status_code, error_code(too_many)) == (413, "batch_too_large")
    assert too_many.json()["error"]["details"] == {"max": 500}
    bodies: list[dict[str, Any]] = [{"ops": []}, {"ops": "x"}, {}, {"ops": None}]
    for body in bodies:
        response = await env.client.post("/sync/push", json=body, headers=phone.headers)
        assert (response.status_code, error_code(response)) == (422, "validation_error")
    not_json = await env.client.post("/sync/push", content=b"{", headers=phone.headers)
    assert not_json.status_code == 422


async def test_same_batch_twice_is_idempotent(env: Env) -> None:
    phone = await env.login()
    batch = [
        create_setting(phone, "a"),
        create_setting(phone, "b"),
        phone.op("user_settings", settings_id("a"), fields={"value": "next"}, base=1),
    ]
    first = await phone.push_ok(batch)
    head = (await phone.pull_ok())["head_version"]
    second = await phone.push_ok(batch)
    assert [r["duplicate"] for r in first] == [False, False, False]
    assert [r["duplicate"] for r in second] == [True, True, True]

    def strip(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return [{k: v for k, v in r.items() if k != "duplicate"} for r in results]

    assert strip(first) == strip(second)
    assert (await phone.pull_ok())["head_version"] == head
    assert await env.scalar("SELECT count(*) FROM sync_ops") == 3


async def test_duplicate_op_id_inside_one_batch(env: Env) -> None:
    phone = await env.login()
    op = create_setting(phone)
    first, second = await phone.push_ok([op, op])
    assert (first["duplicate"], second["duplicate"]) == (False, True)
    assert first["server_version"] == second["server_version"] == 1


async def test_op_id_of_another_device_is_refused(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    op = create_setting(phone)
    await phone.push_ok([op])
    stolen = dict(op)
    stolen["hlc"] = pc.at()
    (result,) = await pc.push_ok([stolen])
    assert (result["status"], result["code"]) == ("rejected", "invalid_id")


async def test_hlc_in_the_future_is_refused_but_not_remembered(env: Env) -> None:
    phone = await env.login()
    op = create_setting(phone)
    op["hlc"] = phone.at(offset_ms=601_000)
    (first,) = await phone.push_ok([op])
    assert (first["status"], first["code"]) == ("rejected", "hlc_in_future")
    assert await env.scalar("SELECT count(*) FROM sync_ops") == 0
    env.clock.advance(seconds=5)  # now within the 10 minute tolerance
    (second,) = await phone.push_ok([op])
    assert second["status"] == "applied"
    # Exactly at the limit is accepted; operations from the past never are refused.
    ok = create_setting(phone, "edge")
    ok["hlc"] = phone.at(offset_ms=600_000)
    old = create_setting(phone, "old")
    old["hlc"] = phone.at(offset_ms=-3 * 86_400_000)
    assert [r["status"] for r in await phone.push_ok([ok, old])] == ["applied", "applied"]


async def test_immutable_key_cannot_change(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"key": "other"}, base=1)]
    )
    assert (result["status"], result["code"]) == ("rejected", "immutable_field")
    (same,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"key": "ui.theme", "value": "x"}, base=1)]
    )
    assert same["status"] == "applied"


async def test_update_of_missing_row_needs_all_fields(env: Env) -> None:
    phone = await env.login()
    (result,) = await phone.push_ok(
        [phone.op("user_settings", THEME, fields={"value": "x"}, base=5)]
    )
    assert (result["status"], result["code"]) == ("rejected", "missing_fields")


async def test_sync_endpoints_require_authentication(env: Env) -> None:
    for method, path in (
        ("post", "/sync/push"),
        ("get", "/sync/pull"),
        ("get", "/sync/conflicts"),
        ("get", "/events"),
        ("post", f"/sync/conflicts/{uuid.uuid4()}/revert"),
    ):
        response = await env.client.request(
            method,
            path,
            headers={"X-Client-Schema-Version": "1"},
            json={"ops": []} if method == "post" else None,
        )
        assert (response.status_code, error_code(response)) == (401, "not_authenticated"), path
