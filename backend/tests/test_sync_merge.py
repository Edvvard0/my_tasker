"""Server merge rules (spec 3.4 and 3.5) exercised through the HTTP API."""

import uuid
from typing import Any

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env


def project(dc: DeviceClient, title: str = "P", **extra: Any) -> tuple[uuid.UUID, dict[str, Any]]:
    row_id = uuid7()
    fields = {"title": title, "created_at": dc.created(), **extra}
    return row_id, dc.op("test_projects", row_id, fields=fields)


def edit(dc: DeviceClient, table: str, row_id: uuid.UUID, fields: dict[str, Any], **kw: Any) -> Any:
    return dc.op(table, row_id, fields=fields, **kw)


async def rows(dc: DeviceClient, table: str = "test_projects") -> dict[str, dict[str, Any]]:
    return {c["id"]: c["row"] for c in (await dc.pull_ok())["changes"] if c["table"] == table}


async def conflicts(dc: DeviceClient) -> list[dict[str, Any]]:
    body: list[dict[str, Any]] = (await dc.get("/sync/conflicts")).json()["conflicts"]
    return list(reversed(body))  # oldest first


async def two_devices(env: Env) -> tuple[DeviceClient, DeviceClient]:
    return await env.login("A"), await env.login("B")


async def test_disjoint_field_edits_merge_silently(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a, "P", budget=1)
    await a.push_ok([create])
    (ra,) = await a.push_ok([edit(a, "test_projects", pid, {"title": "A1"}, base=1, hlc=a.at(10))])
    (rb,) = await b.push_ok([edit(b, "test_projects", pid, {"budget": 7}, base=1, hlc=b.at(20))])
    assert (ra["conflicts"], rb["conflicts"]) == (0, 0)
    row = (await rows(a))[str(pid)]
    assert (row["title"], row["budget"], row["server_version"]) == ("A1", 7, 3)
    assert await conflicts(a) == []


async def test_same_field_newer_hlc_wins_and_is_logged(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([edit(a, "test_projects", pid, {"title": "from A"}, base=1, hlc=a.at(10))])
    (result,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"title": "from B"}, base=1, hlc=b.at(20))]
    )
    assert (result["status"], result["conflicts"], result["server_version"]) == ("applied", 1, 3)
    assert (await rows(a))[str(pid)]["title"] == "from B"
    (conflict,) = await conflicts(a)
    assert (conflict["kind"], conflict["field"], conflict["table"]) == (
        "field",
        "title",
        "test_projects",
    )
    assert (conflict["losing_value"], conflict["winning_value"]) == ("from A", "from B")
    assert conflict["losing_device_id"] == str(a.device_id)
    assert conflict["winning_device_id"] == str(b.device_id)
    assert conflict["row_id"] == str(pid)
    assert conflict["reverted_at"] is None


async def test_same_field_older_hlc_loses_but_the_row_is_touched(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "from B"}, base=1, hlc=b.at(20))])
    (result,) = await a.push_ok(
        [edit(a, "test_projects", pid, {"title": "from A"}, base=1, hlc=a.at(10))]
    )
    assert (result["conflicts"], result["server_version"]) == (1, 3)
    # The version moved on, so the loser's next pull is guaranteed to bring the winner back.
    (change,) = (await a.pull_ok(2))["changes"]
    assert (change["row"]["title"], change["server_version"]) == ("from B", 3)
    (conflict,) = await conflicts(a)
    assert (conflict["losing_value"], conflict["winning_value"]) == ("from A", "from B")
    assert conflict["losing_device_id"] == str(a.device_id)


async def test_own_stale_writes_are_not_conflicts(tree_env: Env) -> None:
    (a,) = (await tree_env.login("A"),)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([edit(a, "test_projects", pid, {"title": "one"}, base=1, hlc=a.at(10))])
    (result,) = await a.push_ok(
        [edit(a, "test_projects", pid, {"title": "two"}, base=1, hlc=a.at(20))]
    )
    assert result["conflicts"] == 0
    assert (await rows(a))[str(pid)]["title"] == "two"


async def test_edit_after_seeing_the_other_change_is_not_a_conflict(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([edit(a, "test_projects", pid, {"title": "one"}, base=1, hlc=a.at(10))])
    (result,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"title": "two"}, base=2, hlc=b.at(20))]
    )
    assert result["conflicts"] == 0


async def test_edit_newer_than_a_concurrent_delete_resurrects(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    (result,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"title": "still needed"}, base=1, hlc=b.at(20))]
    )
    assert (result["status"], result["conflicts"]) == ("applied", 1)
    row = (await rows(a))[str(pid)]
    assert (row["deleted_at"], row["title"]) == (None, "still needed")
    (conflict,) = await conflicts(a)
    assert conflict["kind"] == "resurrected"
    assert conflict["field"] == "deleted_at"
    assert conflict["losing_value"]["deleted_at"].endswith("Z")
    assert conflict["losing_device_id"] == str(a.device_id)


async def test_edit_older_than_a_concurrent_delete_stays_in_trash(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    (result,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"title": "late edit"}, base=1, hlc=b.at(5))]
    )
    assert result["conflicts"] == 1
    row = (await rows(a))[str(pid)]
    assert row["deleted_at"] is not None
    assert row["title"] == "late edit"  # merged, so nothing is lost
    (conflict,) = await conflicts(a)
    assert conflict["kind"] == "edit_vs_delete"
    assert conflict["losing_value"] == {"title": "late edit"}
    assert conflict["winning_device_id"] == str(a.device_id)


async def test_edit_that_saw_the_deletion_is_not_a_conflict(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    (result,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"title": "edited in trash"}, base=2, hlc=b.at(20))]
    )
    assert result["conflicts"] == 0
    row = (await rows(a))[str(pid)]
    assert (row["deleted_at"] is not None, row["title"]) == (True, "edited in trash")


async def test_delete_older_than_a_concurrent_edit_loses(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "edit"}, base=1, hlc=b.at(20))])
    (result,) = await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    assert (result["status"], result["conflicts"], result["server_version"]) == ("applied", 1, 3)
    row = (await rows(a))[str(pid)]
    assert (row["deleted_at"], row["title"]) == (None, "edit")
    (conflict,) = await conflicts(a)
    assert conflict["kind"] == "resurrected"
    assert conflict["losing_device_id"] == str(a.device_id)
    assert conflict["winning_value"] == {"fields": {"title": "edit"}}


async def test_delete_newer_than_a_concurrent_edit_wins(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "edit"}, base=1, hlc=b.at(5))])
    (result,) = await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    assert result["conflicts"] == 1
    row = (await rows(a))[str(pid)]
    assert (row["deleted_at"] is not None, row["title"]) == (True, "edit")
    (conflict,) = await conflicts(a)
    assert conflict["kind"] == "edit_vs_delete"
    assert conflict["losing_value"] == {"fields": {"title": "edit"}}


async def test_delete_that_saw_the_edit_is_not_a_conflict(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await b.push_ok([edit(b, "test_projects", pid, {"title": "edit"}, base=1, hlc=b.at(20))])
    (result,) = await a.push_ok([a.op("test_projects", pid, "delete", base=2, hlc=a.at(30))])
    assert result["conflicts"] == 0


async def test_restore_against_a_concurrent_delete(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    restore_newer = edit(b, "test_projects", pid, {"deleted_at": None}, base=1, hlc=b.at(20))
    (win,) = await b.push_ok([restore_newer])
    assert win["conflicts"] == 1
    assert (await rows(a))[str(pid)]["deleted_at"] is None
    assert (await conflicts(a))[0]["kind"] == "resurrected"

    await a.push_ok([a.op("test_projects", pid, "delete", base=3, hlc=a.at(30))])
    restore_older = edit(b, "test_projects", pid, {"deleted_at": None}, base=3, hlc=b.at(25))
    await b.push_ok([restore_older])
    (only,) = await b.push_ok(
        [edit(b, "test_projects", pid, {"deleted_at": None}, base=1, hlc=b.at(15))]
    )
    assert only["conflicts"] == 1
    last = (await conflicts(a))[-1]
    assert (last["kind"], last["losing_value"]) == ("edit_vs_delete", {"deleted_at": None})
    assert (await rows(a))[str(pid)]["deleted_at"] is not None


async def test_cascade_delete_and_restore(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    t1, t2, s1 = uuid7(), uuid7(), uuid7()
    made = a.created()
    await a.push_ok(
        [
            create,
            a.op(
                "test_tasks", t1, fields={"project_id": str(pid), "title": "t1", "created_at": made}
            ),
            a.op(
                "test_tasks", t2, fields={"project_id": str(pid), "title": "t2", "created_at": made}
            ),
            a.op(
                "test_subtasks", s1, fields={"task_id": str(t1), "title": "s1", "created_at": made}
            ),
        ]
    )  # versions 1..4
    await a.push_ok([a.op("test_tasks", t2, "delete", base=3, hlc=a.at(1))])  # already in trash: v5
    (deleted,) = await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(10))])
    assert deleted["server_version"] == 6
    changes = (await a.pull_ok(5))["changes"]
    assert [(c["table"], c["server_version"]) for c in changes] == [
        ("test_projects", 6),
        ("test_tasks", 7),  # t1 only: t2 was already deleted and keeps version 5
        ("test_subtasks", 8),
    ]
    assert all(c["row"]["deleted_at"] is not None for c in changes)
    assert changes[1]["row"]["deleted_at"] == changes[0]["row"]["deleted_at"]

    (restored,) = await b.push_ok(
        [b.op("test_projects", pid, fields={"deleted_at": None}, base=6, hlc=b.at(20))]
    )
    assert restored["server_version"] == 9
    latest = {c["id"]: c["row"] for c in (await a.pull_ok(8))["changes"]}
    assert set(latest) == {str(pid), str(t1), str(s1)}
    assert all(row["deleted_at"] is None for row in latest.values())
    still_deleted = [c for c in (await a.pull_ok(0))["changes"] if c["id"] == str(t2)]
    assert still_deleted[0]["row"]["deleted_at"] is not None


async def test_child_cannot_be_restored_while_the_parent_is_deleted(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    pid, create = project(a)
    tid = uuid7()
    await a.push_ok(
        [
            create,
            a.op(
                "test_tasks",
                tid,
                fields={"project_id": str(pid), "title": "t", "created_at": a.created()},
            ),
        ]
    )
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])  # v3, v4
    (result,) = await a.push_ok(
        [a.op("test_tasks", tid, fields={"deleted_at": None}, base=4, hlc=a.at(20))]
    )
    assert result["server_version"] == 5  # touched, but still in the trash
    (change,) = (await a.pull_ok(4))["changes"]
    assert change["row"]["deleted_at"] is not None


async def test_child_written_under_a_deleted_parent_goes_to_trash(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])
    tid = uuid7()
    (created,) = await b.push_ok(
        [
            b.op(
                "test_tasks",
                tid,
                fields={"project_id": str(pid), "title": "late", "created_at": b.created()},
                hlc=b.at(20),
            )
        ]
    )
    assert created["conflicts"] == 1
    (conflict,) = await conflicts(a)
    assert conflict["kind"] == "parent_deleted"
    task = (await rows(a, "test_tasks"))[str(tid)]
    assert task["deleted_at"] is not None
    # Restoring the parent brings the late child back with it.
    await a.push_ok([a.op("test_projects", pid, fields={"deleted_at": None}, base=2, hlc=a.at(30))])
    assert (await rows(a, "test_tasks"))[str(tid)]["deleted_at"] is None


async def test_reparenting_to_a_deleted_parent_trashes_the_child(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    p1, c1 = project(a, "one")
    p2, c2 = project(a, "two")
    tid = uuid7()
    await a.push_ok(
        [
            c1,
            c2,
            a.op(
                "test_tasks",
                tid,
                fields={"project_id": str(p1), "title": "t", "created_at": a.created()},
            ),
        ]
    )
    await a.push_ok([a.op("test_projects", p2, "delete", base=2, hlc=a.at(10))])  # v4
    (result,) = await a.push_ok(
        [a.op("test_tasks", tid, fields={"project_id": str(p2)}, base=3, hlc=a.at(20))]
    )
    assert result["conflicts"] == 1
    assert (await rows(a, "test_tasks"))[str(tid)]["deleted_at"] is not None


async def test_missing_parent_is_rejected(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    pid, create = project(a)
    (missing,) = await a.push_ok(
        [
            a.op(
                "test_tasks",
                uuid7(),
                fields={"project_id": str(uuid7()), "title": "t", "created_at": a.created()},
            )
        ]
    )
    assert (missing["status"], missing["code"]) == ("rejected", "parent_not_found")
    await a.push_ok([create])
    tid = uuid7()
    await a.push_ok(
        [
            a.op(
                "test_tasks",
                tid,
                fields={"project_id": str(pid), "title": "t", "created_at": a.created()},
            )
        ]
    )
    (moved,) = await a.push_ok(
        [a.op("test_tasks", tid, fields={"project_id": str(uuid7())}, base=2)]
    )
    assert moved["code"] == "parent_not_found"


async def test_field_validation_of_the_test_table(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    made = a.created()

    def new(fields: dict[str, Any]) -> dict[str, Any]:
        return a.op("test_projects", uuid7(), fields={"created_at": made, **fields})

    results = await a.push_ok(
        [
            new({"title": "   "}),
            new({"title": "x" * 51}),
            new({"title": "ok", "budget": -1}),
            new({"title": "ok", "budget": 1.5}),
            new({"title": "ok", "budget": True}),
            new({"title": "ok", "archived": 1}),
            new({"title": 5}),
            new({"title": "ok", "budget": 0, "archived": False}),
        ]
    )
    assert [r["code"] for r in results] == [
        "validation_failed",
        "invalid_field",
        "invalid_field",
        "invalid_field",
        "invalid_field",
        "invalid_field",
        "invalid_field",
        None,
    ]
    pid, create = project(a)
    await a.push_ok([create])
    (blank,) = await a.push_ok([edit(a, "test_projects", pid, {"title": ""}, base=1)])
    assert blank["code"] == "validation_failed"


async def test_only_uuid7_ids_are_accepted(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    op = a.op("test_projects", uuid.uuid4(), fields={"title": "x", "created_at": a.created()})
    (result,) = await a.push_ok([op])
    assert (result["code"], result["message"]) == ("invalid_id", "id must be a UUIDv7")


async def test_nullable_column_accepts_null(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    pid, create = project(a)
    tid = uuid7()
    fields = {"project_id": str(pid), "title": "t", "note": None, "created_at": a.created()}
    results = await a.push_ok([create, a.op("test_tasks", tid, fields=fields)])
    assert [r["status"] for r in results] == ["applied", "applied"]
    assert (await rows(a, "test_tasks"))[str(tid)]["note"] is None


async def test_pull_orders_versions_across_tables(tree_env: Env) -> None:
    a, _ = await two_devices(tree_env)
    ops = []
    for index in range(4):
        _, op = project(a, f"p{index}")
        ops.append(op)
    ops.append(
        a.op(
            "user_settings",
            uuid.uuid5(uuid.UUID("11fae5eb-de4a-5a92-88e3-5c86a8c454f4"), "k"),
            fields={"key": "k", "value": 1, "created_at": a.created()},
        )
    )
    await a.push_ok(ops)
    changes = await a.pull_all()
    assert [c["server_version"] for c in changes] == [1, 2, 3, 4, 5]
    assert changes[-1]["table"] == "user_settings"


async def test_a_later_delete_refreshes_the_deletion_clock(tree_env: Env) -> None:
    a, b = await two_devices(tree_env)
    c = await tree_env.login("C")
    pid, create = project(a)
    await a.push_ok([create])
    await a.push_ok([a.op("test_projects", pid, "delete", base=1, hlc=a.at(10))])  # v2
    await b.push_ok([b.op("test_projects", pid, "delete", base=1, hlc=b.at(30))])  # already gone
    # C restores at t=20: after A's deletion (10) but before B's (30), without seeing either.
    (result,) = await c.push_ok(
        [edit(c, "test_projects", pid, {"deleted_at": None}, base=1, hlc=c.at(20))]
    )
    assert result["conflicts"] == 1
    assert (await rows(a))[str(pid)]["deleted_at"] is not None  # the newest deletion stands
    assert (await conflicts(a))[0]["kind"] == "edit_vs_delete"
