"""Server-side validation of every Stage 2 table, driven through the real push endpoint."""

import uuid
from typing import Any

import pytest

from tasker.calendar import ids
from tasker.calendar.tables import CALENDAR_TABLES, reminders_problem, valid_timezone
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.calendar_support import (
    ORIGINAL,
    Seed,
    all_day_event_fields,
    calendar_fields,
    completion_fields,
    event_fields,
    override_fields,
    seed,
    subtask_fields,
    task_fields,
)

Case = tuple[str, str, uuid.UUID | None, dict[str, Any], str | None]
# (name, table, row id (None: fresh UUIDv7), fields, expected reject code (None: applied))


async def run_cases(dc: DeviceClient, cases: list[Case]) -> None:
    ops = [dc.op(table, row_id or uuid7(), fields=fields) for _, table, row_id, fields, _ in cases]
    results = await dc.push_ok(ops)
    problems = []
    for (name, _, _, _, expected), result in zip(cases, results, strict=True):
        got = result["code"] if result["status"] == "rejected" else None
        if got != expected:
            problems.append(f"{name}: expected {expected}, got {got} ({result['message']})")
    assert not problems, "\n".join(problems)


def cal(dc: DeviceClient, label: str, expected: str | None = None, **over: Any) -> Case:
    return (label, "calendars", None, calendar_fields(dc, **over), expected)


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


@pytest.fixture
async def graph(phone: DeviceClient) -> Seed:
    return await seed(phone)


async def test_registry_lists_every_table_parents_first() -> None:
    names = [spec.name for spec in CALENDAR_TABLES]
    assert names == [
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
    ]
    for index, spec in enumerate(CALENDAR_TABLES):
        assert all(column.parent in names[:index] for column in spec.parents())


async def test_seed_graph_is_valid(env: Env, graph: Seed) -> None:
    assert await env.scalar("SELECT count(*) FROM events") == 1
    assert await env.scalar("SELECT count(*) FROM task_completions") == 1


# ------------------------------------------------------------------ calendars


async def test_calendar_validation(phone: DeviceClient) -> None:
    system = ids.system_calendar_id("work")
    cases: list[Case] = [
        cal(phone, "user calendar ok"),
        cal(phone, "user calendar with color", color="#aBc123"),
        (
            "system calendar ok",
            "calendars",
            system,
            calendar_fields(phone, kind="system", system_key="work"),
            None,
        ),
        cal(phone, "blank name", "validation_failed", name="   "),
        cal(phone, "empty name", "invalid_field", name=""),
        cal(phone, "name too long", "invalid_field", name="x" * 101),
        cal(phone, "bad color", "invalid_field", color="red"),
        cal(phone, "short color", "invalid_field", color="#fff"),
        cal(phone, "bad kind", "invalid_field", kind="shared"),
        cal(phone, "position negative", "invalid_field", position=-1),
        cal(phone, "visible is not bool", "invalid_field", visible="yes"),
        cal(phone, "system without key", "validation_failed", kind="system"),
        cal(
            phone, "system with unknown key", "validation_failed", kind="system", system_key="mail"
        ),
        cal(phone, "user with system key", "validation_failed", system_key="work"),
        (
            "system id is not uuid5",
            "calendars",
            None,
            calendar_fields(phone, kind="system", system_key="study"),
            "invalid_id",
        ),
        ("user id is not uuid7", "calendars", uuid.uuid4(), calendar_fields(phone), "invalid_id"),
        (
            "user id is uuid5 of nothing",
            "calendars",
            ids.system_calendar_id("personal"),
            calendar_fields(phone),
            "invalid_id",
        ),
        (
            "missing required",
            "calendars",
            None,
            {"name": "x", "created_at": phone.created()},
            "missing_fields",
        ),
    ]
    await run_cases(phone, cases)


async def test_system_key_and_kind_of_a_calendar_are_immutable_in_practice(
    phone: DeviceClient,
) -> None:
    calendar = ids.system_calendar_id("tasks")
    (created,) = await phone.push_ok(
        [
            phone.op(
                "calendars",
                calendar,
                fields=calendar_fields(phone, kind="system", system_key="tasks"),
            )
        ]
    )
    (moved,) = await phone.push_ok(
        [
            phone.op(
                "calendars", calendar, fields={"system_key": "work"}, base=created["server_version"]
            )
        ]
    )
    assert (moved["status"], moved["code"]) == ("rejected", "immutable_field")
    (kind,) = await phone.push_ok(
        [phone.op("calendars", calendar, fields={"kind": "user"}, base=created["server_version"])]
    )
    assert (kind["status"], kind["code"]) == ("rejected", "validation_failed")


# ------------------------------------------------------------------ events


async def test_event_validation(phone: DeviceClient, graph: Seed) -> None:
    c = graph.calendar

    def ev(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "events", None, event_fields(phone, c, **over), expected)

    def day(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "events", None, all_day_event_fields(phone, c, **over), expected)

    cases: list[Case] = [
        ev("timed ok", None),
        ev("timed zero length", None, end_at="2026-10-05T07:00:00Z"),
        ev("timed with offset ok", None, start_at="2026-10-05T10:00:00+03:00"),
        ev(
            "timed with rrule", None, rrule="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;UNTIL=20261231T210000Z"
        ),
        ev("timed with reminders", None, reminders=[0, 10, 1440]),
        ev("empty reminders", None, reminders=[]),
        day("all-day ok", None),
        day("all-day multi", None, end_date="2026-10-07"),
        day("all-day recurring", None, rrule="FREQ=YEARLY;COUNT=3"),
        day("all-day until as date", None, rrule="FREQ=DAILY;UNTIL=20261231"),
        ev("blank title", "validation_failed", title="  "),
        ev("title too long", "invalid_field", title="x" * 301),
        ev("bad source", "invalid_field", source="google"),
        ev("all_day is not bool", "invalid_field", all_day=1),
        ev("timed without tz", "validation_failed", tz=None),
        ev("unknown tz", "validation_failed", tz="Mars/Base"),
        ev("offset as tz", "validation_failed", tz="+03:00"),
        ev("abbreviation as tz", "validation_failed", tz="MSK"),
        ev("path-like tz", "validation_failed", tz="../etc/passwd"),
        ev("timed without start", "validation_failed", start_at=None, end_at=None),
        ev("timed with only start", "validation_failed", end_at=None),
        ev("end before start", "validation_failed", end_at="2026-10-05T06:59:59Z"),
        ev("longer than 366 days", "validation_failed", end_at="2027-10-07T07:00:00Z"),
        ev("exactly 366 days", None, end_at="2027-10-06T07:00:00Z"),
        ev("naive start", "invalid_field", start_at="2026-10-05T07:00:00"),
        ev("start is not a date", "invalid_field", start_at="soon"),
        ev("timed with dates", "validation_failed", start_date="2026-10-05", end_date="2026-10-05"),
        day("all-day with times", "validation_failed", start_at=START_AT),
        day("all-day with tz", "validation_failed", tz="Europe/Moscow"),
        day("all-day without dates", "validation_failed", start_date=None, end_date=None),
        day("all-day with one date", "validation_failed", end_date=None),
        day("all-day end before start", "validation_failed", start_date="2026-10-06"),
        day(
            "all-day not a real date",
            "validation_failed",
            start_date="2026-02-30",
            end_date="2026-02-30",
        ),
        day("all-day bad date format", "invalid_field", start_date="5.10.2026"),
        day("all-day longer than 366 days", "validation_failed", end_date="2027-10-07"),
        day(
            "all-day year out of range",
            "validation_failed",
            start_date="1900-01-01",
            end_date="1900-01-01",
        ),
        ev("rrule hourly", "validation_failed", rrule="FREQ=HOURLY"),
        ev("rrule with prefix", "validation_failed", rrule="RRULE:FREQ=DAILY"),
        ev("rrule lower case", "validation_failed", rrule="freq=daily"),
        ev("rrule empty string", "validation_failed", rrule=""),
        ev(
            "rrule count and until",
            "validation_failed",
            rrule="FREQ=DAILY;COUNT=2;UNTIL=20261231T000000Z",
        ),
        ev(
            "rrule until in date form for timed",
            "validation_failed",
            rrule="FREQ=DAILY;UNTIL=20261231",
        ),
        ev(
            "rrule until before start",
            "validation_failed",
            rrule="FREQ=DAILY;UNTIL=20261004T000000Z",
        ),
        day(
            "rrule until before start (all-day)",
            "validation_failed",
            rrule="FREQ=DAILY;UNTIL=20261004",
        ),
        day(
            "rrule until in instant form for all-day",
            "validation_failed",
            rrule="FREQ=DAILY;UNTIL=20261231T000000Z",
        ),
        ev("rrule not a string", "invalid_field", rrule=5),
        ev("rrule too long", "invalid_field", rrule="FREQ=DAILY;" + "X" * 200),
        ev("reminders duplicates", "validation_failed", reminders=[5, 5]),
        ev("reminders negative", "validation_failed", reminders=[-1]),
        ev("reminders too far", "validation_failed", reminders=[40321]),
        ev("reminders too many", "validation_failed", reminders=[0, 1, 2, 3, 4, 5]),
        ev("reminders not integers", "validation_failed", reminders=[1.5]),
        ev("reminders booleans", "validation_failed", reminders=[True]),
        ev("reminders not a list", "validation_failed", reminders={"a": 1}),
        ev("description too long", "invalid_field", description="x" * 10001),
        ev("location too long", "invalid_field", location="x" * 501),
        ("calendar missing", "events", None, event_fields(phone, uuid7()), "parent_not_found"),
        (
            "missing required",
            "events",
            None,
            {"title": "x", "created_at": phone.created()},
            "missing_fields",
        ),
        ("id is not uuid7", "events", uuid.uuid4(), event_fields(phone, c), "invalid_id"),
    ]
    await run_cases(phone, cases)


START_AT = "2026-10-05T07:00:00Z"


async def test_editing_an_event_revalidates_the_merged_row(
    phone: DeviceClient, graph: Seed
) -> None:
    (row,) = await phone.push_ok(
        [phone.op("events", graph.event, fields={"title": "Новое имя"}, base=1)]
    )
    assert row["status"] == "applied"
    base = row["server_version"]
    cases: list[tuple[str, dict[str, Any], str]] = [
        ("switch to all-day but keep the times", {"all_day": True}, "validation_failed"),
        ("clear tz but keep the instants", {"tz": None}, "validation_failed"),
        (
            "rrule that ends before the start",
            {"rrule": "FREQ=DAILY;UNTIL=20200101T000000Z"},
            "validation_failed",
        ),
        ("move the calendar to a missing one", {"calendar_id": str(uuid7())}, "parent_not_found"),
    ]
    ops = [phone.op("events", graph.event, fields=fields, base=base) for _, fields, _ in cases]
    for (name, _, code), result in zip(cases, await phone.push_ok(ops), strict=True):
        assert (result["status"], result["code"]) == ("rejected", code), name
    ok = await phone.push_ok(
        [
            phone.op(
                "events",
                graph.event,
                fields={
                    "all_day": True,
                    "start_at": None,
                    "end_at": None,
                    "tz": None,
                    "start_date": "2026-10-05",
                    "end_date": "2026-10-05",
                    "rrule": "FREQ=DAILY;COUNT=5",
                },
                base=base,
            )
        ]
    )
    assert ok[0]["status"] == "applied"


# ------------------------------------------------------------------ overrides


async def test_override_validation(phone: DeviceClient, graph: Seed) -> None:
    def ov(
        name: str, expected: str | None, original: str = "2026-10-07T07:00:00Z", **over: Any
    ) -> Case:
        fields = override_fields(phone, graph.event, original_start=original, **over)
        return (name, "event_overrides", ids.override_id(graph.event, original), fields, expected)

    cases: list[Case] = [
        ov("cancel", None, cancelled=True),
        ov("retitle", None, "2026-10-08T07:00:00Z", title="Другое"),
        ov(
            "move",
            None,
            "2026-10-09T07:00:00Z",
            start_at="2026-10-09T09:00:00Z",
            end_at="2026-10-09T10:00:00Z",
        ),
        ov("date key", None, "2026-10-10", start_date="2026-10-11", end_date="2026-10-12"),
        ov("reminders override", None, "2026-10-11T07:00:00Z", reminders=[]),
        ov("bad key", "validation_failed", "2026-10-07 07:00"),
        ov("key with offset", "invalid_field", "2026-10-07T07:00:00+00:00"),
        ov("key with millis", "invalid_field", "2026-10-07T07:00:00.000Z"),
        ov("key not a real date", "validation_failed", "2026-02-30"),
        ov("blank title", "validation_failed", "2026-10-12T07:00:00Z", title=" "),
        ov(
            "only start",
            "validation_failed",
            "2026-10-13T07:00:00Z",
            start_at="2026-10-13T09:00:00Z",
        ),
        ov(
            "end before start",
            "validation_failed",
            "2026-10-14T07:00:00Z",
            start_at="2026-10-14T09:00:00Z",
            end_at="2026-10-14T08:00:00Z",
        ),
        ov(
            "instant and date at once",
            "validation_failed",
            "2026-10-15T07:00:00Z",
            start_at="2026-10-15T09:00:00Z",
            end_at="2026-10-15T10:00:00Z",
            start_date="2026-10-15",
            end_date="2026-10-15",
        ),
        ov(
            "date end before start",
            "validation_failed",
            "2026-10-16",
            start_date="2026-10-17",
            end_date="2026-10-16",
        ),
        ov("bad reminders", "validation_failed", "2026-10-17T07:00:00Z", reminders=[1, 1]),
        ov("cancelled is not bool", "invalid_field", "2026-10-18T07:00:00Z", cancelled="x"),
        (
            "id is not the deterministic one",
            "event_overrides",
            uuid7(),
            override_fields(phone, graph.event, original_start="2026-10-19T07:00:00Z"),
            "invalid_id",
        ),
        (
            "same key, other event id",
            "event_overrides",
            ids.override_id(uuid7(), ORIGINAL),
            override_fields(phone, graph.event),
            "invalid_id",
        ),
    ]
    await run_cases(phone, cases)


async def test_override_of_a_missing_event_is_parent_not_found(phone: DeviceClient) -> None:
    event = uuid7()
    (result,) = await phone.push_ok(
        [
            phone.op(
                "event_overrides",
                ids.override_id(event, ORIGINAL),
                fields=override_fields(phone, event),
            )
        ]
    )
    assert (result["status"], result["code"]) == ("rejected", "parent_not_found")


async def test_override_key_and_event_are_immutable(phone: DeviceClient, graph: Seed) -> None:
    other = "2026-10-07T07:00:00Z"
    results = await phone.push_ok(
        [
            phone.op("event_overrides", graph.override, fields={"original_start": other}, base=1),
            phone.op("event_overrides", graph.override, fields={"event_id": str(uuid7())}, base=1),
        ]
    )
    assert [r["code"] for r in results] == ["immutable_field", "immutable_field"]


# ------------------------------------------------------------------ projects, people, tags


async def test_projects_people_and_tags_validation(phone: DeviceClient) -> None:
    def project(name: str, expected: str | None, **over: Any) -> Case:
        fields = {"title": "Бот", "archived": False, "created_at": phone.created(), **over}
        return (name, "projects", None, fields, expected)

    def person(label: str, expected: str | None, **over: Any) -> Case:
        fields = {"name": "Рома", "archived": False, "created_at": phone.created(), **over}
        return (label, "people", None, fields, expected)

    def tag(name: str, expected: str | None, tag_name: str, **over: Any) -> Case:
        fields = {"name": tag_name, "created_at": phone.created(), **over}
        return (name, "tags", ids.tag_id(tag_name), fields, expected)

    cases: list[Case] = [
        project("project ok", None, color="#00ff00"),
        project("project blank", "validation_failed", title="  "),
        project("project too long", "invalid_field", title="x" * 201),
        project("project bad color", "invalid_field", color="green"),
        project("project archived not bool", "invalid_field", archived=0),
        person("person ok", None),
        person("person blank", "validation_failed", name=" "),
        person("person too long", "invalid_field", name="x" * 101),
        tag("tag ok", None, "работа"),
        tag("tag ok with color", None, "Дом", color="#123456"),
        tag("tag latin and dash", None, "to-do_1"),
        tag("tag with space", "invalid_field", "две части"),
        tag("tag with hash", "invalid_field", "#работа"),
        tag("tag with plus", "invalid_field", "+работа"),
        tag("tag with at", "invalid_field", "@рома"),
        tag("tag too long", "invalid_field", "x" * 51),
        tag("tag empty", "invalid_field", ""),
        (
            "tag id is not lower(name)",
            "tags",
            uuid7(),
            {"name": "Работа2", "created_at": phone.created()},
            "invalid_id",
        ),
        (
            "tag id is case-insensitive",
            "tags",
            ids.tag_id("Срочно"),
            {"name": "срочно", "created_at": phone.created()},
            None,
        ),
    ]
    await run_cases(phone, cases)


async def test_a_tag_cannot_be_renamed(phone: DeviceClient) -> None:
    tag = ids.tag_id("работа")
    (created,) = await phone.push_ok(
        [phone.op("tags", tag, fields={"name": "работа", "created_at": phone.created()})]
    )
    (renamed,) = await phone.push_ok(
        [phone.op("tags", tag, fields={"name": "дело"}, base=created["server_version"])]
    )
    assert (renamed["status"], renamed["code"]) == ("rejected", "immutable_field")


# ------------------------------------------------------------------ tasks


async def test_task_validation(phone: DeviceClient, graph: Seed) -> None:
    def task(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "tasks", None, task_fields(phone, **over), expected)

    timed = {"due_at": "2026-10-05T12:00:00Z", "due_tz": "Europe/Moscow"}
    cases: list[Case] = [
        task("minimal", None),
        task("every status", None, status="in_progress"),
        task("priority 1", None, priority=1),
        task("priority 5", None, priority=5),
        task("no priority", None, priority=None),
        task("due date", None, due_date="2026-10-05"),
        task("due datetime", None, **timed),
        task("duration", None, duration_minutes=1440),
        task(
            "recurring dated",
            None,
            due_date="2026-10-05",
            rrule="FREQ=WEEKLY;BYDAY=MO",
            recurrence_mode="schedule",
        ),
        task(
            "recurring timed",
            None,
            rrule="FREQ=DAILY;UNTIL=20261231T000000Z",
            recurrence_mode="after_completion",
            **timed,
        ),
        task("reminders on dated", None, due_date="2026-10-05", reminders=[0, 900]),
        task("done with completed_at", None, status="done", completed_at="2026-10-05T12:00:00Z"),
        task("archived", None, status="cancelled", archived_at="2026-10-05T12:00:00Z"),
        task("soft refs", None, project_id=str(uuid7()), person_id=str(uuid7())),
        task("sort order", None, sort_order=2**53),
        task("blank title", "validation_failed", title=" "),
        task("title too long", "invalid_field", title="x" * 501),
        task("notes too long", "invalid_field", notes="x" * 20001),
        task("bad status", "invalid_field", status="waiting"),
        task("russian status", "invalid_field", status="К выполнению"),
        task("priority 0", "invalid_field", priority=0),
        task("priority 6", "invalid_field", priority=6),
        task("priority as text", "invalid_field", priority="P1"),
        task("duration 0", "invalid_field", duration_minutes=0),
        task("duration too long", "invalid_field", duration_minutes=1441),
        task("negative sort order", "invalid_field", sort_order=-1),
        task("bad source", "invalid_field", source="alice"),
        task("bad recurrence mode", "invalid_field", recurrence_mode="daily"),
        task("bad project id", "invalid_field", project_id="not-a-uuid"),
        task("date and datetime", "validation_failed", due_date="2026-10-05", **timed),
        task("datetime without tz", "validation_failed", due_at="2026-10-05T12:00:00Z"),
        task("tz without datetime", "validation_failed", due_tz="Europe/Moscow"),
        task(
            "tz unknown", "validation_failed", due_at="2026-10-05T12:00:00Z", due_tz="Nowhere/Land"
        ),
        task("due date not real", "validation_failed", due_date="2026-02-30"),
        task("due date bad format", "invalid_field", due_date="2026-2-3"),
        task(
            "rrule without a date",
            "validation_failed",
            rrule="FREQ=DAILY",
            recurrence_mode="schedule",
        ),
        task(
            "rrule without a mode", "validation_failed", due_date="2026-10-05", rrule="FREQ=DAILY"
        ),
        task("mode without rrule", "validation_failed", recurrence_mode="schedule"),
        task(
            "rrule invalid",
            "validation_failed",
            due_date="2026-10-05",
            rrule="FREQ=DAILY;COUNT=0",
            recurrence_mode="schedule",
        ),
        task(
            "rrule until form for dated",
            "validation_failed",
            due_date="2026-10-05",
            rrule="FREQ=DAILY;UNTIL=20261231T000000Z",
            recurrence_mode="schedule",
        ),
        task(
            "rrule until form for timed",
            "validation_failed",
            rrule="FREQ=DAILY;UNTIL=20261231",
            recurrence_mode="schedule",
            **timed,
        ),
        task(
            "rrule until before due",
            "validation_failed",
            due_date="2026-10-05",
            rrule="FREQ=DAILY;UNTIL=20261001",
            recurrence_mode="schedule",
        ),
        task("reminders without a date", "validation_failed", reminders=[10]),
        task("bad reminders", "validation_failed", due_date="2026-10-05", reminders=[1, 1]),
        task("completed_at not a datetime", "invalid_field", completed_at="today"),
        task("archived_at naive", "invalid_field", archived_at="2026-10-05T12:00:00"),
        ("id is not uuid7", "tasks", uuid.uuid4(), task_fields(phone), "invalid_id"),
        (
            "missing status",
            "tasks",
            None,
            {"title": "x", "source": "manual", "created_at": phone.created()},
            "missing_fields",
        ),
    ]
    await run_cases(phone, cases)


async def test_task_status_transitions_are_unrestricted(phone: DeviceClient) -> None:
    """The server allows any status change; done/completed_at consistency is a client rule."""
    task = uuid7()
    (created,) = await phone.push_ok(
        [phone.op("tasks", task, fields=task_fields(phone, status="inbox"))]
    )
    base = created["server_version"]
    for status in ("done", "inbox", "cancelled", "in_progress", "todo", "done"):
        (result,) = await phone.push_ok(
            [phone.op("tasks", task, fields={"status": status}, base=base)]
        )
        assert result["status"] == "applied", status
        base = result["server_version"]


# ---------------------------------------------------------------- subtasks, relations, completions


async def test_subtask_and_relation_validation(phone: DeviceClient, graph: Seed) -> None:
    other_tag = ids.tag_id("дом")
    cases: list[Case] = [
        (
            "tag row for the second tag",
            "tags",
            other_tag,
            {"name": "дом", "created_at": phone.created()},
            None,
        ),
        (
            "subtask ok",
            "subtasks",
            None,
            subtask_fields(phone, graph.task, title="Второй пункт", position=2048),
            None,
        ),
        ("subtask done", "subtasks", None, subtask_fields(phone, graph.task, done=True), None),
        (
            "subtask blank",
            "subtasks",
            None,
            subtask_fields(phone, graph.task, title=" "),
            "validation_failed",
        ),
        (
            "subtask too long",
            "subtasks",
            None,
            subtask_fields(phone, graph.task, title="x" * 501),
            "invalid_field",
        ),
        (
            "subtask negative position",
            "subtasks",
            None,
            subtask_fields(phone, graph.task, position=-1),
            "invalid_field",
        ),
        (
            "subtask done not bool",
            "subtasks",
            None,
            subtask_fields(phone, graph.task, done="no"),
            "invalid_field",
        ),
        (
            "subtask of missing task",
            "subtasks",
            None,
            subtask_fields(phone, uuid7()),
            "parent_not_found",
        ),
        (
            "task tag ok",
            "task_tags",
            ids.task_tag_id(graph.task, other_tag),
            {"task_id": str(graph.task), "tag_id": str(other_tag), "created_at": phone.created()},
            None,
        ),
        (
            "task tag with a random id",
            "task_tags",
            uuid7(),
            {"task_id": str(graph.task), "tag_id": str(other_tag), "created_at": phone.created()},
            "invalid_id",
        ),
        (
            "task tag with a missing tag",
            "task_tags",
            ids.task_tag_id(graph.task, uuid.UUID(int=5)),
            {
                "task_id": str(graph.task),
                "tag_id": str(uuid.UUID(int=5)),
                "created_at": phone.created(),
            },
            "parent_not_found",
        ),
        (
            "task tag with a missing task",
            "task_tags",
            ids.task_tag_id(uuid.UUID(int=6), graph.tag),
            {
                "task_id": str(uuid.UUID(int=6)),
                "tag_id": str(graph.tag),
                "created_at": phone.created(),
            },
            "parent_not_found",
        ),
        (
            "completion ok",
            "task_completions",
            ids.completion_id(graph.task, "2026-10-07"),
            completion_fields(phone, graph.task, "2026-10-07", state="skipped"),
            None,
        ),
        (
            "completion with a random id",
            "task_completions",
            uuid7(),
            completion_fields(phone, graph.task, "2026-10-08"),
            "invalid_id",
        ),
        (
            "completion of a missing task",
            "task_completions",
            ids.completion_id(uuid.UUID(int=7), "2026-10-08"),
            completion_fields(phone, uuid.UUID(int=7), "2026-10-08"),
            "parent_not_found",
        ),
        (
            "completion on a fake date",
            "task_completions",
            ids.completion_id(graph.task, "2026-02-30"),
            completion_fields(phone, graph.task, "2026-02-30"),
            "validation_failed",
        ),
        (
            "completion date format",
            "task_completions",
            ids.completion_id(graph.task, "6.10.2026"),
            completion_fields(phone, graph.task, "6.10.2026"),
            "invalid_field",
        ),
        (
            "completion bad state",
            "task_completions",
            ids.completion_id(graph.task, "2026-10-09"),
            completion_fields(phone, graph.task, "2026-10-09", state="failed"),
            "invalid_field",
        ),
        (
            "completion without completed_at",
            "task_completions",
            ids.completion_id(graph.task, "2026-10-10"),
            {
                k: v
                for k, v in completion_fields(phone, graph.task, "2026-10-10").items()
                if k != "completed_at"
            },
            "missing_fields",
        ),
    ]
    await run_cases(phone, cases)


async def test_relation_keys_are_immutable(phone: DeviceClient, graph: Seed) -> None:
    results = await phone.push_ok(
        [
            phone.op("subtasks", graph.subtask, fields={"task_id": str(uuid7())}, base=1),
            phone.op("task_tags", graph.task_tag, fields={"tag_id": str(uuid7())}, base=1),
            phone.op(
                "task_completions", graph.completion, fields={"instance_date": "2026-10-07"}, base=1
            ),
            phone.op(
                "task_completions", graph.completion, fields={"task_id": str(uuid7())}, base=1
            ),
        ]
    )
    assert [r["code"] for r in results] == ["immutable_field"] * 4


# ------------------------------------------------------------------ helpers


def test_reminders_problem_accepts_none_and_valid_lists() -> None:
    assert reminders_problem(None) is None
    assert reminders_problem([]) is None
    assert reminders_problem([0, 40320]) is None
    assert reminders_problem("x") is not None


def test_valid_timezone() -> None:
    assert valid_timezone("Europe/Moscow")
    assert valid_timezone("UTC")
    assert not valid_timezone("Europe/Nowhere")
    assert not valid_timezone("")
