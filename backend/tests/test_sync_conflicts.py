import uuid
from typing import Any

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.test_auth_api import error_code
from tests.test_sync_merge import edit, project, rows, two_devices


async def make_field_conflict(a: DeviceClient, b: DeviceClient) -> tuple[uuid.UUID, str]:
    pid, create = project(a, "start")
    await a.push_ok([create])
    await a.push_ok([edit(a, "test_projects", pid, {"title": "from A"}, base=1, hlc=a.at(10))])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "from B"}, base=1, hlc=b.at(20))])
    (conflict,) = (await a.get("/sync/conflicts")).json()["conflicts"]
    return pid, str(conflict["id"])


async def test_revert_field_conflict_applies_the_losing_value(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, conflict_id = await make_field_conflict(a, b)
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["conflict"]["reverted_at"] is not None
    change = body["change"]
    assert change["table"] == "test_projects"
    assert (change["row"]["title"], change["row"]["origin_device_id"]) == (
        "from A",
        str(a.device_id),
    )
    assert change["server_version"] == 4
    # The revert is an ordinary new version that reaches the other device without a new conflict.
    assert (await rows(b))[str(pid)]["title"] == "from A"
    listed = (await a.get("/sync/conflicts")).json()["conflicts"]
    assert len(listed) == 1


async def test_revert_twice_and_unknown(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    _, conflict_id = await make_field_conflict(a, b)
    await a.post(f"/sync/conflicts/{conflict_id}/revert")
    again = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert (again.status_code, error_code(again)) == (409, "conflict_already_reverted")
    missing = await a.post(f"/sync/conflicts/{uuid7()}/revert")
    assert (missing.status_code, error_code(missing)) == (404, "conflict_not_found")
    assert (await a.post("/sync/conflicts/not-a-uuid/revert")).status_code == 422


async def test_revert_resurrected_deletes_again(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "revived"}, base=1, hlc=b.at(20))])
    (conflict,) = (await a.get("/sync/conflicts")).json()["conflicts"]
    assert conflict["kind"] == "resurrected"
    response = await a.post(f"/sync/conflicts/{conflict['id']}/revert")
    assert response.status_code == 200
    assert response.json()["change"]["row"]["deleted_at"] is not None
    assert (await rows(b))[str(pid)]["deleted_at"] is not None


async def test_revert_edit_vs_delete_restores(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "late"}, base=1, hlc=b.at(5))])
    (conflict,) = (await b.get("/sync/conflicts")).json()["conflicts"]
    assert conflict["kind"] == "edit_vs_delete"
    response = await b.post(f"/sync/conflicts/{conflict['id']}/revert")
    assert response.status_code == 200
    row = response.json()["change"]["row"]
    assert (row["deleted_at"], row["title"]) == (None, "late")


async def test_parent_deleted_conflict_cannot_be_reverted(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    await b.push_ok(
        [
            b.op(
                "test_tasks",
                uuid7(),
                fields={"project_id": str(pid), "title": "t", "created_at": b.created()},
            )
        ]
    )
    (conflict,) = (await a.get("/sync/conflicts")).json()["conflicts"]
    response = await a.post(f"/sync/conflicts/{conflict['id']}/revert")
    assert (response.status_code, error_code(response)) == (409, "not_revertable")


async def test_revert_when_the_row_was_purged(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    _, conflict_id = await make_field_conflict(a, b)
    await tree_env.execute("DELETE FROM test_projects")
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert (response.status_code, error_code(response)) == (409, "row_not_found")


async def test_revert_of_a_value_that_is_no_longer_valid(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    _, conflict_id = await make_field_conflict(a, b)
    await tree_env.execute("UPDATE sync_conflicts SET losing_value = '\"\"'::jsonb")
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert (response.status_code, error_code(response)) == (422, "revert_rejected")
    assert await tree_env.scalar("SELECT reverted_at FROM sync_conflicts") is None
    await tree_env.execute("UPDATE sync_conflicts SET losing_value = '5'::jsonb")  # not a string
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert (response.status_code, error_code(response)) == (422, "revert_rejected")


async def test_revert_of_a_dropped_column_or_table(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    _, conflict_id = await make_field_conflict(a, b)
    await tree_env.execute("UPDATE sync_conflicts SET field = 'gone'")
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert error_code(response) == "not_revertable"
    await tree_env.execute("UPDATE sync_conflicts SET table_name = 'gone'")
    assert error_code(await a.post(f"/sync/conflicts/{conflict_id}/revert")) == "not_revertable"


async def test_revert_wins_over_later_edits_of_the_same_field(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, conflict_id = await make_field_conflict(a, b)
    await b.push_ok([edit(b, "test_projects", pid, {"title": "later"}, base=3, hlc=b.at(500))])
    response = await a.post(f"/sync/conflicts/{conflict_id}/revert")
    assert response.json()["change"]["row"]["title"] == "from A"  # user asked for it explicitly


async def test_list_filters_and_paging(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    ids: list[str] = []
    for index in range(5):
        pid, create = project(a, f"p{index}")
        await a.push_ok([create])
        await a.push_ok(
            [edit(a, "test_projects", pid, {"title": "A"}, base=1, hlc=a.at(10 + index))]
        )
        await b.push_ok(
            [edit(b, "test_projects", pid, {"title": "B"}, base=1, hlc=b.at(20 + index))]
        )
    listed: dict[str, Any] = (await a.get("/sync/conflicts", limit=2)).json()
    assert len(listed["conflicts"]) == 2
    assert listed["next_before"] == listed["conflicts"][-1]["id"]
    seen = [c["id"] for c in listed["conflicts"]]
    while listed["next_before"]:
        listed = (await a.get("/sync/conflicts", limit=2, before=listed["next_before"])).json()
        seen.extend(c["id"] for c in listed["conflicts"])
    ids = seen
    assert len(ids) == len(set(ids)) == 5
    assert ids == sorted(ids, reverse=True)  # newest (largest UUIDv7) first
    await a.post(f"/sync/conflicts/{ids[0]}/revert")
    reverted = (await a.get("/sync/conflicts", reverted="true")).json()["conflicts"]
    open_ones = (await a.get("/sync/conflicts", reverted="false")).json()["conflicts"]
    assert [c["id"] for c in reverted] == [ids[0]]
    assert len(open_ones) == 4
    for params in ({"limit": 0}, {"limit": 201}, {"reverted": "maybe"}, {"before": "x"}):
        assert (await a.get("/sync/conflicts", **params)).status_code == 422
