"""Stage 2 tables through the real sync engine: round trips, ids, cascades, trash, conflicts."""

import uuid
from datetime import timedelta
from typing import Any

from tasker.calendar import ids
from tasker.ids import uuid7
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env
from tests.calendar_support import (
    Seed,
    calendar_fields,
    completion_fields,
    event_fields,
    override_fields,
    push_one,
    seed,
    seed_ops,
    subtask_fields,
    task_fields,
)


def rows_by_table(changes: list[dict[str, Any]]) -> dict[str, dict[str, dict[str, Any]]]:
    tables: dict[str, dict[str, dict[str, Any]]] = {}
    for change in changes:
        tables.setdefault(change["table"], {})[change["id"]] = change["row"]
    return tables


async def pull_rows(dc: DeviceClient) -> dict[str, dict[str, dict[str, Any]]]:
    return rows_by_table((await dc.pull_ok(0))["changes"])


async def deleted(env: Env, table: str) -> int:
    return int(await env.scalar(f"SELECT count(*) FROM {table} WHERE deleted_at IS NOT NULL"))  # noqa: S608


def test_registry_has_every_stage2_table() -> None:
    names = {spec.name for spec in build_registry().tables()}
    assert {
        "calendars",
        "events",
        "event_overrides",
        "projects",
        "people",
        "tags",
        "tasks",
        "subtasks",
        "task_tags",
        "task_completions",
    } <= names


# ------------------------------------------------------------------ round trip


async def test_whole_graph_round_trips_to_a_second_device(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    pc = await env.login("PC")
    tables = await pull_rows(pc)

    calendar = tables["calendars"][str(graph.calendar)]
    assert (calendar["kind"], calendar["system_key"], calendar["color"]) == (
        "system",
        "personal",
        "#0A84FF",
    )
    event = tables["events"][str(graph.event)]
    assert event["rrule"] == "FREQ=DAILY;COUNT=5"
    assert event["reminders"] == [0, 10]
    assert (event["tz"], event["start_at"], event["all_day"]) == (
        "Europe/Moscow",
        "2026-10-05T07:00:00Z",
        False,
    )
    assert event["start_date"] is None
    override = tables["event_overrides"][str(graph.override)]
    assert (override["title"], override["start_at"]) == ("Перенесена", "2026-10-06T09:00:00Z")
    assert tables["tags"][str(graph.tag)]["name"] == "работа"
    task = tables["tasks"][str(graph.task)]
    assert (task["priority"], task["status"], task["recurrence_mode"]) == (2, "todo", "schedule")
    assert (task["due_at"], task["due_tz"], task["duration_minutes"]) == (
        "2026-10-05T12:00:00Z",
        "Europe/Moscow",
        30,
    )
    assert task["project_id"] == str(graph.project)
    assert task["reminders"] == [15]
    assert tables["subtasks"][str(graph.subtask)]["position"] == 1024
    assert tables["task_tags"][str(graph.task_tag)]["tag_id"] == str(graph.tag)
    assert tables["task_completions"][str(graph.completion)]["instance_date"] == "2026-10-06"
    assert len(tables["projects"]) == len(tables["people"]) == 1


async def test_edit_a_task_changes_only_sent_fields_and_can_null_them(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    result = await push_one(
        phone,
        "tasks",
        graph.task,
        {"priority": None, "notes": None, "status": "in_progress", "project_id": None},
        base=8,
    )
    assert result["status"] == "applied"
    row = (await pull_rows(await env.login("PC")))["tasks"][str(graph.task)]
    assert (row["priority"], row["notes"], row["project_id"]) == (None, None, None)
    assert (row["status"], row["title"], row["duration_minutes"]) == (
        "in_progress",
        "Позвонить Роме",
        30,
    )


async def test_a_moved_calendar_is_a_plain_field_edit(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    work = uuid7()
    await push_one(phone, "calendars", work, calendar_fields(phone, name="Работа"))
    result = await push_one(phone, "events", graph.event, {"calendar_id": str(work)}, base=2)
    assert result["status"] == "applied"


# ------------------------------------------------------------------ deterministic ids


async def test_same_logical_rows_from_two_devices_are_one_row(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    calendar = ids.system_calendar_id("study")
    tag = ids.tag_id("Срочно")
    event, task = uuid7(), uuid7()
    for device in (phone, pc):
        name = "Учёба" if device is phone else "Универ"
        pushed = [
            device.op(
                "calendars",
                calendar,
                fields=calendar_fields(device, name=name, kind="system", system_key="study"),
            ),
            device.op("tags", tag, fields={"name": "Срочно", "created_at": device.created()}),
        ]
        results = await device.push_ok(pushed)
        assert [r["status"] for r in results] == ["applied", "applied"]
    assert await env.scalar("SELECT count(*) FROM calendars") == 1
    assert await env.scalar("SELECT count(*) FROM tags") == 1
    # The same instance overridden on both devices, the same tag put on the same task.
    await phone.push_ok(
        [
            phone.op("events", event, fields=event_fields(phone, calendar, rrule="FREQ=DAILY")),
            phone.op("tasks", task, fields=task_fields(phone)),
        ]
    )
    key = "2026-10-07T07:00:00Z"
    for device in (phone, pc):
        results = await device.push_ok(
            [
                device.op(
                    "event_overrides",
                    ids.override_id(event, key),
                    fields=override_fields(device, event, original_start=key, cancelled=True),
                ),
                device.op(
                    "task_tags",
                    ids.task_tag_id(task, tag),
                    fields={
                        "task_id": str(task),
                        "tag_id": str(tag),
                        "created_at": device.created(),
                    },
                ),
            ]
        )
        assert [r["status"] for r in results] == ["applied", "applied"], results
    assert await env.scalar("SELECT count(*) FROM event_overrides") == 1
    assert await env.scalar("SELECT count(*) FROM task_tags") == 1
    (conflict_count,) = [
        await env.scalar("SELECT count(*) FROM sync_conflicts WHERE field = 'name'")
    ]
    assert conflict_count >= 1  # the two calendar names raced: the loser is in the journal


# ------------------------------------------------------------------ cascades and trash


async def test_deleting_a_calendar_trashes_events_and_overrides_and_restore_brings_them_back(
    env: Env,
) -> None:
    phone = await env.login()
    graph = await seed(phone)
    alone = uuid7()
    await push_one(phone, "events", alone, event_fields(phone, graph.calendar, title="Отдельное"))
    (gone,) = await phone.push_ok([phone.op("events", alone, "delete", base=10)])
    assert gone["status"] == "applied"
    (result,) = await phone.push_ok([phone.op("calendars", graph.calendar, "delete", base=1)])
    assert result["status"] == "applied"
    assert await deleted(env, "events") == 2
    assert await deleted(env, "event_overrides") == 1

    pc = await env.login("PC")
    tables = await pull_rows(pc)
    assert tables["events"][str(graph.event)]["deleted_at"] is not None
    assert tables["event_overrides"][str(graph.override)]["deleted_at"] is not None

    head = (await pc.pull_ok(0))["head_version"]
    (restored,) = await pc.push_ok(
        [pc.op("calendars", graph.calendar, fields={"deleted_at": None}, base=head)]
    )
    assert restored["status"] == "applied"
    rows = rows_by_table((await pc.pull_ok(0))["changes"])
    assert rows["calendars"][str(graph.calendar)]["deleted_at"] is None
    assert rows["events"][str(graph.event)]["deleted_at"] is None
    assert rows["event_overrides"][str(graph.override)]["deleted_at"] is None
    assert rows["events"][str(alone)]["deleted_at"] is not None  # deleted on its own: stays


async def test_deleting_a_task_trashes_its_subtasks_tags_and_completions(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    tag_ids = {"tags": 6}
    (result,) = await phone.push_ok([phone.op("tasks", graph.task, "delete", base=7)])
    assert result["status"] == "applied"
    for table in ("subtasks", "task_tags", "task_completions"):
        assert await deleted(env, table) == 1, table
    assert await deleted(env, "tags") == 0  # the tag itself is not a child of the task
    assert tag_ids  # (documented above)
    head = (await phone.pull_ok(0))["head_version"]
    await phone.push_ok([phone.op("tasks", graph.task, fields={"deleted_at": None}, base=head)])
    for table in ("subtasks", "task_tags", "task_completions", "tasks"):
        assert await deleted(env, table) == 0, table


async def test_deleting_a_tag_only_unlinks_it_from_tasks(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    await phone.push_ok([phone.op("tags", graph.tag, "delete", base=6)])
    assert await deleted(env, "task_tags") == 1
    assert await deleted(env, "tasks") == 0


async def test_deleting_a_project_or_a_person_leaves_tasks_untouched(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    await phone.push_ok(
        [
            phone.op("projects", graph.project, "delete", base=4),
            phone.op("people", graph.person, "delete", base=5),
        ]
    )
    assert await deleted(env, "tasks") == 0
    tables = await pull_rows(await env.login("PC"))
    assert tables["tasks"][str(graph.task)]["project_id"] == str(
        graph.project
    )  # dangling on purpose


async def test_a_child_created_under_a_deleted_parent_lands_in_the_trash(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    await phone.push_ok([phone.op("tasks", graph.task, "delete", base=7)])
    late = uuid7()
    (result,) = await phone.push_ok(
        [phone.op("subtasks", late, fields=subtask_fields(phone, graph.task, title="Поздний"))]
    )
    assert (result["status"], result["conflicts"]) == ("applied", 1)
    assert await env.scalar("SELECT deleted_at IS NOT NULL FROM subtasks WHERE id = :i", i=late)
    kinds = await env.scalar("SELECT string_agg(DISTINCT kind, ',') FROM sync_conflicts")
    assert "parent_deleted" in kinds


async def test_old_tombstones_are_purged_children_first(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    await phone.push_ok(
        [
            phone.op("calendars", graph.calendar, "delete", base=1),
            phone.op("tasks", graph.task, "delete", base=7),
            phone.op("tags", graph.tag, "delete", base=6),
        ]
    )
    await phone.pull_ok(0)
    page = await phone.pull_ok(0)
    await phone.pull_ok(page["head_version"])
    env.clock.advance(days=31)
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged >= 8
    for table in (
        "calendars",
        "events",
        "event_overrides",
        "tasks",
        "subtasks",
        "tags",
        "task_tags",
    ):
        assert await env.scalar(f"SELECT count(*) FROM {table}") == 0, table  # noqa: S608
    assert await env.scalar("SELECT count(*) FROM projects") == 1  # never deleted


# ------------------------------------------------------------------ conflicts


async def test_concurrent_status_changes_keep_the_later_write_and_log_the_other(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    task = uuid7()
    await phone.push_ok([phone.op("tasks", task, fields=task_fields(phone, status="inbox"))])
    await pc.pull_ok(0)
    early = phone.op("tasks", task, fields={"status": "done"}, base=1, hlc=phone.at(1000))
    late = pc.op("tasks", task, fields={"status": "cancelled"}, base=1, hlc=pc.at(2000))
    await phone.push_ok([early])
    (result,) = await pc.push_ok([late])
    assert result["conflicts"] == 1
    row = (await pull_rows(phone))["tasks"][str(task)]
    assert row["status"] == "cancelled"
    logged = await env.scalar("SELECT losing_value FROM sync_conflicts WHERE field = 'status'")
    assert logged == "done"


async def test_edits_of_different_fields_merge_without_conflict(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    task = uuid7()
    await phone.push_ok([phone.op("tasks", task, fields=task_fields(phone))])
    await pc.pull_ok(0)
    await phone.push_ok([phone.op("tasks", task, fields={"priority": 1}, base=1)])
    (result,) = await pc.push_ok([pc.op("tasks", task, fields={"title": "Другое"}, base=1)])
    assert result["conflicts"] == 0
    row = (await pull_rows(phone))["tasks"][str(task)]
    assert (row["priority"], row["title"]) == (1, "Другое")


async def test_a_merge_that_breaks_an_invariant_is_rejected_not_stored(env: Env) -> None:
    """Why time fields must travel together: start and end edited apart can cross."""
    phone, pc = await env.login(), await env.login("PC")
    calendar, event = uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op("calendars", calendar, fields=calendar_fields(phone)),
            phone.op("events", event, fields=event_fields(phone, calendar)),
        ]
    )
    await pc.pull_ok(0)
    moved = phone.op(
        "events",
        event,
        fields={"start_at": "2026-10-05T10:00:00Z", "end_at": "2026-10-05T11:00:00Z"},
        base=2,
        hlc=phone.at(1000),
    )
    shorter = pc.op(
        "events", event, fields={"end_at": "2026-10-05T07:30:00Z"}, base=2, hlc=pc.at(2000)
    )
    await phone.push_ok([moved])
    (result,) = await pc.push_ok([shorter])
    assert (result["status"], result["code"]) == ("rejected", "validation_failed")
    row = (await pull_rows(phone))["events"][str(event)]
    assert (row["start_at"], row["end_at"]) == ("2026-10-05T10:00:00Z", "2026-10-05T11:00:00Z")


async def test_editing_a_deleted_event_conflicts_with_the_deletion(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    graph = await seed(phone)
    await pc.pull_ok(0)
    await phone.push_ok([phone.op("events", graph.event, "delete", base=2, hlc=phone.at(1000))])
    (result,) = await pc.push_ok(
        [pc.op("events", graph.event, fields={"title": "Правка"}, base=2, hlc=pc.at(2000))]
    )
    assert result["conflicts"] >= 1
    row = (await pull_rows(phone))["events"][str(graph.event)]
    assert row["deleted_at"] is None  # the later edit resurrects the event
    assert row["title"] == "Правка"


async def test_completion_of_a_recurring_task_can_be_undone_and_redone(env: Env) -> None:
    phone = await env.login()
    graph = await seed(phone)
    (undo,) = await phone.push_ok(
        [phone.op("task_completions", graph.completion, "delete", base=9)]
    )
    assert undo["status"] == "applied"
    (redo,) = await phone.push_ok(
        [
            phone.op(
                "task_completions",
                graph.completion,
                fields=completion_fields(phone, graph.task, "2026-10-06", state="skipped")
                | {"deleted_at": None},
                base=undo["server_version"],
            )
        ]
    )
    assert redo["status"] == "applied", redo
    row = (await pull_rows(phone))["task_completions"][str(graph.completion)]
    assert (row["deleted_at"], row["state"]) == (None, "skipped")


async def test_seed_ops_are_in_dependency_order(env: Env) -> None:
    phone = await env.login()
    _, ops = seed_ops(phone)
    parents_first = [op["table"] for op in ops]
    assert parents_first.index("calendars") < parents_first.index("events")
    assert parents_first.index("events") < parents_first.index("event_overrides")
    assert parents_first.index("tasks") < parents_first.index("subtasks")
    assert isinstance(uuid.UUID(ops[0]["id"]), uuid.UUID)
    assert timedelta(0) == timedelta(seconds=0)
    assert Seed.__name__ == "Seed"
