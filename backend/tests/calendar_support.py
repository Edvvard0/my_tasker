"""Builders of valid Stage 2 rows and a seed graph, shared by the calendar sync tests."""

import uuid
from dataclasses import dataclass
from typing import Any

from tasker.calendar import ids
from tasker.ids import uuid7
from tests.api_support import DeviceClient

START = "2026-10-05T07:00:00Z"
END = "2026-10-05T08:00:00Z"
ORIGINAL = "2026-10-06T07:00:00Z"


def calendar_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "name": "Личное",
        "kind": "user",
        "visible": True,
        "position": 0,
        "created_at": dc.created(),
        **over,
    }


def event_fields(dc: DeviceClient, calendar_id: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "calendar_id": str(calendar_id),
        "title": "Планёрка",
        "all_day": False,
        "start_at": START,
        "end_at": END,
        "tz": "Europe/Moscow",
        "source": "manual",
        "created_at": dc.created(),
        **over,
    }


def all_day_event_fields(dc: DeviceClient, calendar_id: uuid.UUID, **over: Any) -> dict[str, Any]:
    fields = event_fields(
        dc, calendar_id, all_day=True, start_date="2026-10-05", end_date="2026-10-05"
    )
    fields.update(start_at=None, end_at=None, tz=None)
    return {**fields, **over}


def override_fields(dc: DeviceClient, event_id: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "event_id": str(event_id),
        "original_start": ORIGINAL,
        "cancelled": False,
        "created_at": dc.created(),
        **over,
    }


def task_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "title": "Позвонить Роме",
        "status": "todo",
        "source": "manual",
        "created_at": dc.created(),
        **over,
    }


def subtask_fields(dc: DeviceClient, task_id: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "task_id": str(task_id),
        "title": "Найти номер",
        "done": False,
        "position": 1024,
        "created_at": dc.created(),
        **over,
    }


def completion_fields(
    dc: DeviceClient, task_id: uuid.UUID, day: str, **over: Any
) -> dict[str, Any]:
    return {
        "task_id": str(task_id),
        "instance_date": day,
        "state": "done",
        "completed_at": "2026-10-06T10:00:00Z",
        "created_at": dc.created(),
        **over,
    }


@dataclass
class Seed:
    """A complete graph, pushed by ``seed`` in creation order."""

    calendar: uuid.UUID
    event: uuid.UUID
    override: uuid.UUID
    project: uuid.UUID
    person: uuid.UUID
    tag: uuid.UUID
    task: uuid.UUID
    subtask: uuid.UUID
    task_tag: uuid.UUID
    completion: uuid.UUID


def seed_ops(dc: DeviceClient) -> tuple[Seed, list[dict[str, Any]]]:
    graph = Seed(
        calendar=ids.system_calendar_id("personal"),
        event=uuid7(),
        override=ids.override_id("00000000-0000-0000-0000-000000000000", ORIGINAL),
        project=uuid7(),
        person=uuid7(),
        tag=ids.tag_id("работа"),
        task=uuid7(),
        subtask=uuid7(),
        task_tag=uuid7(),
        completion=uuid7(),
    )
    graph.override = ids.override_id(graph.event, ORIGINAL)
    graph.task_tag = ids.task_tag_id(graph.task, graph.tag)
    graph.completion = ids.completion_id(graph.task, "2026-10-06")
    ops = [
        dc.op(
            "calendars",
            graph.calendar,
            fields=calendar_fields(dc, kind="system", system_key="personal", color="#0A84FF"),
        ),
        dc.op(
            "events",
            graph.event,
            fields=event_fields(
                dc,
                graph.calendar,
                rrule="FREQ=DAILY;COUNT=5",
                reminders=[0, 10],
                description="Каждый день",
                location="Кабинет 3",
            ),
        ),
        dc.op(
            "event_overrides",
            graph.override,
            fields=override_fields(
                dc,
                graph.event,
                start_at="2026-10-06T09:00:00Z",
                end_at="2026-10-06T10:00:00Z",
                title="Перенесена",
            ),
        ),
        dc.op(
            "projects",
            graph.project,
            fields={"title": "Бот", "archived": False, "created_at": dc.created()},
        ),
        dc.op(
            "people",
            graph.person,
            fields={"name": "Рома", "archived": False, "created_at": dc.created()},
        ),
        dc.op("tags", graph.tag, fields={"name": "работа", "created_at": dc.created()}),
        dc.op(
            "tasks",
            graph.task,
            fields=task_fields(
                dc,
                priority=2,
                due_at="2026-10-05T12:00:00Z",
                due_tz="Europe/Moscow",
                duration_minutes=30,
                rrule="FREQ=DAILY",
                recurrence_mode="schedule",
                project_id=str(graph.project),
                person_id=str(graph.person),
                reminders=[15],
                notes="**важно**",
            ),
        ),
        dc.op("subtasks", graph.subtask, fields=subtask_fields(dc, graph.task)),
        dc.op(
            "task_tags",
            graph.task_tag,
            fields={
                "task_id": str(graph.task),
                "tag_id": str(graph.tag),
                "created_at": dc.created(),
            },
        ),
        dc.op(
            "task_completions",
            graph.completion,
            fields=completion_fields(dc, graph.task, "2026-10-06"),
        ),
    ]
    return graph, ops


async def seed(dc: DeviceClient) -> Seed:
    graph, ops = seed_ops(dc)
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return graph


async def push_one(
    dc: DeviceClient, table: str, row_id: uuid.UUID, fields: dict[str, Any], base: int = 0
) -> dict[str, Any]:
    (result,) = await dc.push_ok([dc.op(table, row_id, fields=fields, base=base)])
    return result
