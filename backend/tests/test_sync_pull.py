import uuid

from tasker.sync.user_settings import settings_id
from tests.api_support import Env
from tests.test_auth_api import error_code
from tests.test_sync_push import create_setting


async def seed(env: Env, count: int) -> None:
    phone = await env.login("Seeder")
    await phone.push_ok([create_setting(phone, f"key{i}") for i in range(count)])


async def test_empty_pull(env: Env) -> None:
    phone = await env.login()
    page = await phone.pull_ok()
    assert page["changes"] == []
    assert (page["next_since"], page["has_more"], page["head_version"]) == (0, False, 0)
    assert page["purge_watermark"] == 0
    assert page["server_time"].endswith("Z")


async def test_pagination_walks_every_row_once_in_order(env: Env) -> None:
    await seed(env, 7)
    phone = await env.login()
    seen: list[int] = []
    since = 0
    pages = 0
    while True:
        page = await phone.pull_ok(since, 3)
        pages += 1
        seen.extend(c["server_version"] for c in page["changes"])
        assert len(page["changes"]) <= 3
        since = page["next_since"]
        if not page["has_more"]:
            assert since == page["head_version"] == 7
            break
        assert since == page["changes"][-1]["server_version"]
    assert (seen, pages) == ([1, 2, 3, 4, 5, 6, 7], 3)


async def test_exact_page_boundary_reports_no_more(env: Env) -> None:
    await seed(env, 3)
    phone = await env.login()
    page = await phone.pull_ok(0, 3)
    assert (len(page["changes"]), page["has_more"], page["next_since"]) == (3, False, 3)


async def test_pull_since_head_returns_nothing_and_keeps_cursor(env: Env) -> None:
    await seed(env, 2)
    phone = await env.login()
    page = await phone.pull_ok(2)
    assert (page["changes"], page["next_since"], page["has_more"]) == ([], 2, False)


async def test_pull_includes_tombstones(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone, "gone")])
    await phone.push_ok([phone.op("user_settings", settings_id("gone"), "delete", base=1)])
    (change,) = (await phone.pull_ok(0))["changes"]
    assert change["row"]["deleted_at"] is not None
    assert change["server_version"] == 2


async def test_pull_parameter_validation(env: Env) -> None:
    phone = await env.login()
    for params in ({"since": -1}, {"limit": 0}, {"limit": 1001}, {"since": "x"}):
        response = await phone.get("/sync/pull", **params)
        assert (response.status_code, error_code(response)) == (422, "validation_error"), params
    ok = await phone.pull_ok(0, 1000)
    assert ok["changes"] == []


async def test_default_limit_is_500(env: Env) -> None:
    await seed(env, 3)
    phone = await env.login()
    response = await phone.get("/sync/pull")
    assert len(response.json()["changes"]) == 3


async def test_pull_records_the_device_cursor(env: Env) -> None:
    await seed(env, 3)
    phone = await env.login()
    assert (
        await env.scalar("SELECT last_pulled_version FROM devices WHERE id=:i", i=phone.device_id)
        == 0
    )
    await phone.pull_ok(2)
    assert (
        await env.scalar("SELECT last_pulled_version FROM devices WHERE id=:i", i=phone.device_id)
        == 2
    )
    await phone.pull_ok(0)  # a full resync lowers the cursor again
    assert (
        await env.scalar("SELECT last_pulled_version FROM devices WHERE id=:i", i=phone.device_id)
        == 0
    )
    listed = (await phone.get("/auth/devices")).json()["devices"]
    assert [d["last_pulled_version"] for d in listed if d["is_current"]] == [0]


async def test_push_does_not_move_the_cursor(env: Env) -> None:
    phone = await env.login()
    await phone.push_ok([create_setting(phone)])
    assert await env.scalar("SELECT last_pulled_version FROM devices") == 0


async def test_lagging_cursor_gets_resync_required(env: Env) -> None:
    await seed(env, 3)
    phone = await env.login()
    await env.execute("UPDATE sync_state SET purge_watermark = 2")
    response = await phone.pull(1)
    assert (response.status_code, error_code(response)) == (410, "resync_required")
    assert response.json()["error"]["details"] == {
        "purge_watermark": 2,
        "head_version": 3,
        "reason": "purged",
    }
    assert (
        await env.scalar("SELECT last_pulled_version FROM devices WHERE id=:i", i=phone.device_id)
        == 0
    )
    for since in (2, 3, 0):  # at or beyond the watermark, and a fresh start, are fine
        assert (await phone.pull(since)).status_code == 200
    assert (await phone.pull_ok(0))["purge_watermark"] == 2


async def test_pull_sees_other_devices_rows_with_origin(env: Env) -> None:
    phone = await env.login("Phone")
    pc = await env.login("PC")
    await phone.push_ok([create_setting(phone, "from.phone")])
    await pc.push_ok([create_setting(pc, "from.pc")])
    origins = {c["row"]["key"]: c["row"]["origin_device_id"] for c in await phone.pull_all()}
    assert origins == {"from.phone": str(phone.device_id), "from.pc": str(pc.device_id)}
    assert uuid.UUID(next(iter(origins.values()))).version == 7
