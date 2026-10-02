"""The tool loop: read tools on the server, malformed calls, proposals instead of tasks."""

import json
import uuid
from typing import Any

from tasker.calendar import ids
from tasker.ids import is_uuid7, uuid7
from tests.ai.fake_upstream import FakeUpstream, text_reply, tool_reply
from tests.ai.support import AiEnv, chat_body, make_conversation, run_chat
from tests.api_support import DeviceClient
from tests.calendar_support import (
    all_day_event_fields,
    calendar_fields,
    event_fields,
    override_fields,
    task_fields,
)


async def push_tasks(device: DeviceClient, *specs: dict[str, Any]) -> list[uuid.UUID]:
    ops, made = [], []
    for fields in specs:
        task_id = uuid7()
        made.append(task_id)
        ops.append(device.op("tasks", task_id, fields=task_fields(device, **fields)))
    results = await device.push_ok(ops)
    assert all(r["status"] == "applied" for r in results), results
    return made


def tool_message(request_json: dict[str, Any], index: int = -1) -> dict[str, Any]:
    tool_messages = [m for m in request_json["messages"] if m["role"] == "tool"]
    message: dict[str, Any] = tool_messages[index]
    return message


async def test_read_tool_runs_on_the_server_and_hides_deleted_rows(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    alive, gone, archived, _ = await push_tasks(
        phone,
        {"title": "Купить молоко", "priority": 2, "due_date": "2026-10-02"},
        {"title": "Удалённая"},
        {"title": "В архиве", "archived_at": "2026-09-01T00:00:00Z"},
        {"title": "Без срока", "status": "inbox"},
    )
    await phone.push_ok([phone.op("tasks", gone, "delete", base=2)])
    fake.queue(
        tool_reply([("call_1", "get_tasks", json.dumps({"status": ["todo", "inbox"]}))]),
        text_reply(["Нашёл задачи"]),
    )

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.names() == [
        "start",
        "usage",
        "tool_call",
        "tool_result",
        "delta",
        "usage",
        "done",
    ]
    assert sse.of("tool_call") == [
        {"id": "call_1", "name": "get_tasks", "arguments": {"status": ["todo", "inbox"]}}
    ]
    assert sse.of("tool_result")[0]["is_error"] is False
    second = fake.chat_requests[1].json
    result = json.loads(tool_message(second)["content"])
    titles = [t["title"] for t in result["tasks"]]
    assert titles == ["Купить молоко", "Без срока"]  # dated first; deleted and archived hidden
    assert str(alive) == result["tasks"][0]["id"] and str(archived) not in json.dumps(result)
    assistant = [m for m in second["messages"] if m["role"] == "assistant"][0]
    assert assistant["tool_calls"][0]["function"]["name"] == "get_tasks"
    assert second["messages"].index(assistant) + 1 == second["messages"].index(tool_message(second))

    await aienv.settle()
    row = [c["row"] for c in await phone.pull_all() if c["table"] == "ai_messages"][0]
    kinds = [p["type"] for p in row["parts"]]
    assert kinds == ["tool_call", "tool_result", "text"] and row["text"] == "Нашёл задачи"
    assert row["finish_reason"] == "stop"
    # the usage of both calls is added up
    assert row["prompt_tokens"] == 30 and row["completion_tokens"] == 13


async def test_get_tasks_filters(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await push_tasks(
        phone,
        {"title": "Отчёт", "priority": 1, "due_date": "2026-10-05"},
        {"title": "Звонок", "priority": 4, "due_date": "2026-10-20"},
        {
            "title": "Встреча",
            "due_at": "2026-10-05T21:30:00Z",  # 00:30 on the 6th in Moscow
            "due_tz": "Europe/Moscow",
            "duration_minutes": 30,
        },
        {"title": "Готово", "status": "done"},
    )
    args = {"due_from": "2026-10-04", "due_to": "2026-10-06", "query": "т"}
    fake.queue(tool_reply([("c1", "get_tasks", json.dumps(args))]), text_reply(["ok"]))
    await run_chat(phone, chat_body(conversation))
    found = json.loads(tool_message(fake.chat_requests[1].json)["content"])
    assert [(t["title"], t["due_date"], t["due_time"]) for t in found["tasks"]] == [
        ("Отчёт", "2026-10-05", None),
        ("Встреча", "2026-10-06", "00:30"),
    ]

    fake.queue(
        tool_reply([("c2", "get_tasks", json.dumps({"priority_max": 1, "limit": 1}))]),
        text_reply(["ok"]),
    )
    await run_chat(phone, chat_body(conversation))
    top = json.loads(tool_message(fake.chat_requests[3].json)["content"])
    assert [t["title"] for t in top["tasks"]] == ["Отчёт"] and top["truncated"] is False

    fake.queue(
        tool_reply([("c3", "get_tasks", json.dumps({"no_due_date": True, "limit": 1}))]),
        text_reply(["ok"]),
    )
    await run_chat(phone, chat_body(conversation))
    undated = json.loads(tool_message(fake.chat_requests[5].json)["content"])
    assert [t["title"] for t in undated["tasks"]] == ["Готово"] and undated["truncated"] is False


async def test_get_events_expands_recurrence_and_hides_deleted(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    calendar, dead_calendar = uuid7(), uuid7()
    weekly, single, all_day, in_dead, deleted_event = (uuid7() for _ in range(5))
    cancelled_override = ids.override_id(weekly, "2026-10-12T07:00:00Z")
    await phone.push_ok(
        [
            phone.op("calendars", calendar, fields=calendar_fields(phone)),
            phone.op("calendars", dead_calendar, fields=calendar_fields(phone, name="Старый")),
            phone.op(
                "events",
                weekly,
                fields=event_fields(
                    phone, calendar, title="Планёрка", rrule="FREQ=WEEKLY;BYDAY=MO"
                ),
            ),
            phone.op(
                "events",
                single,
                fields=event_fields(
                    phone,
                    calendar,
                    title="Стоматолог",
                    start_at="2026-10-08T11:00:00Z",
                    end_at="2026-10-08T12:00:00Z",
                ),
            ),
            phone.op(
                "events", all_day, fields=all_day_event_fields(phone, calendar, title="Отпуск")
            ),
            phone.op("events", in_dead, fields=event_fields(phone, dead_calendar, title="Призрак")),
            phone.op(
                "events", deleted_event, fields=event_fields(phone, calendar, title="Удалено")
            ),
            phone.op(
                "event_overrides",
                cancelled_override,
                fields=override_fields(
                    phone, weekly, original_start="2026-10-12T07:00:00Z", cancelled=True
                ),
            ),
        ]
    )
    await phone.push_ok(
        [
            phone.op("calendars", dead_calendar, "delete", base=2),
            phone.op("events", deleted_event, "delete", base=7),
        ]
    )
    args = {"from_date": "2026-10-05", "to_date": "2026-10-19"}
    fake.queue(tool_reply([("e1", "get_events", json.dumps(args))]), text_reply(["ok"]))

    await run_chat(phone, chat_body(conversation))

    found = json.loads(tool_message(fake.chat_requests[1].json)["content"])
    shown = [(e["title"], e["start"], e["all_day"]) for e in found["events"]]
    assert shown == [
        ("Отпуск", "2026-10-05", True),
        ("Планёрка", "2026-10-05T10:00", False),  # the 5th, Monday, 07:00Z = 10:00 Moscow
        ("Стоматолог", "2026-10-08T14:00", False),
        ("Планёрка", "2026-10-19T10:00", False),  # the 12th is cancelled
    ]
    assert found["events"][0]["calendar"] == "Личное"


async def test_parallel_calls_and_malformed_arguments(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await push_tasks(phone, {"title": "Одна"})
    fake.queue(
        tool_reply(
            [
                ("p1", "get_tasks", "{}"),
                ("p2", "get_tasks", '{"status": ["todo"'),  # cut off: not JSON
                ("p3", "get_tasks", '{"priority_min": 9}'),  # valid JSON, wrong schema
                ("p4", "get_events", '{"from_date": "2026-10-05"}'),  # missing field
                ("p5", "launch_rocket", "{}"),  # not a tool
                ("p6", "get_tasks", "[1, 2]"),  # not an object
            ]
        ),
        text_reply(["Часть вызовов не удалась"]),
    )

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.last[0] == "done"
    results = {r["tool_call_id"]: r["is_error"] for r in sse.of("tool_result")}
    assert results == {"p1": False, "p2": True, "p3": True, "p4": True, "p5": True, "p6": True}
    broken = [c for c in sse.of("tool_call") if c["id"] == "p2"][0]
    assert broken["arguments"] is None
    messages = fake.chat_requests[1].json["messages"]
    tool_messages = {m["tool_call_id"]: m["content"] for m in messages if m["role"] == "tool"}
    assert list(tool_messages) == ["p1", "p2", "p3", "p4", "p5", "p6"]  # one answer per call
    assert "not valid JSON" in tool_messages["p2"] and "priority_min" in tool_messages["p3"]
    assert "unknown tool" in tool_messages["p5"] and "9" not in tool_messages["p3"].replace(
        "priority_min", ""
    )
    await aienv.settle()
    row = [c["row"] for c in await phone.pull_all() if c["table"] == "ai_messages"][0]
    saved_call = [p for p in row["parts"] if p["type"] == "tool_call" and p["id"] == "p2"][0]
    assert saved_call["arguments"] is None and saved_call["raw_arguments"].startswith('{"status"')


async def test_create_task_becomes_a_proposal_not_a_task(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device("Phone")
    pc = await aienv.device("PC")
    conversation = await make_conversation(phone)
    args = {
        "title": "Сдать отчёт",
        "due_date": "2026-10-09",
        "due_time": "15:30",
        "priority": 2,
        "tags": ["работа"],
        "bogus": "dropped",
    }
    fake.queue(
        tool_reply([("t1", "create_task", json.dumps(args)), ("t2", "get_tasks", "{}")]),
        text_reply(["это не должно запроситься"]),
    )

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.last[0] == "done" and sse.last[1]["finish_reason"] == "awaiting_approval"
    assert len(fake.chat_requests) == 1  # the loop stopped at the card
    proposal = sse.of("proposal")[0]
    assert proposal["tool"] == "create_task" and proposal["entity_type"] == "task"
    assert is_uuid7(uuid.UUID(proposal["entity_id"]))
    expected = {
        "title": "Сдать отчёт",
        "due_date": "2026-10-09",
        "due_time": "15:30",
        "priority": 2,
        "tags": ["работа"],
    }
    assert proposal["arguments"] == expected
    assert "tasks" not in [c["table"] for c in await phone.pull_all()]  # no task was created
    assert await aienv.env.scalar("SELECT count(*) FROM tasks") == 0

    await aienv.settle()
    for device in (phone, pc):  # both devices receive the message and the card
        changes = await device.pull_all()
        proposals = [c["row"] for c in changes if c["table"] == "ai_tool_proposals"]
        messages = [c["row"] for c in changes if c["table"] == "ai_messages"]
        assert len(proposals) == 1 and len(messages) == 1
        row = proposals[0]
        assert row["status"] == "pending" and row["decided_at"] is None
        assert row["arguments"] == row["original_arguments"] == expected
        assert row["entity_id"] == proposal["entity_id"] and row["tool_call_id"] == "t1"
        assert row["message_id"] == messages[0]["id"] == sse.of("start")[0]["message_id"]
        kinds = [p["type"] for p in messages[0]["parts"]]
        assert kinds == ["tool_call", "proposal", "tool_call", "tool_result"]


async def test_invalid_create_task_is_not_proposed(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(
        tool_reply([("t1", "create_task", json.dumps({"title": "  ", "due_time": "25:00"}))]),
        tool_reply([("t2", "create_task", json.dumps({"title": "Ок", "due_time": "10:00"}))]),
        tool_reply([("t3", "create_task", json.dumps({"title": "Ок", "due_date": "2026-02-30"}))]),
        text_reply(["сдаюсь"]),
    )

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.of("proposal") == [] and sse.last[1]["finish_reason"] == "stop"
    assert [r["is_error"] for r in sse.of("tool_result")] == [True, True, True]
    assert "due_time needs due_date" in sse.of("tool_result")[1]["preview"]
    await aienv.settle()
    assert await aienv.env.scalar("SELECT count(*) FROM ai_tool_proposals") == 0


async def test_the_tool_loop_is_bounded(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(*[tool_reply([(f"c{i}", "get_tasks", "{}")]) for i in range(10)])

    sse = await run_chat(phone, chat_body(conversation))

    assert len(fake.chat_requests) == 5  # AI_MAX_TOOL_ITERATIONS
    assert [r.json.get("tool_choice") for r in fake.chat_requests] == ["auto"] * 4 + ["none"]
    name, data = sse.last
    assert name == "error" and data["code"] == "tool_loop_limit" and data["retryable"] is False
    await aienv.settle()
    row = [c["row"] for c in await phone.pull_all() if c["table"] == "ai_messages"][0]
    assert (row["status"], row["error_code"]) == ("error", "tool_loop_limit")
    assert data["message_id"] == row["id"]


async def test_tools_can_be_restricted_per_request(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(tool_reply([("c1", "create_task", '{"title": "x"}')]), text_reply(["ok"]))

    sse = await run_chat(phone, chat_body(conversation, tools=["get_tasks"]))

    assert [t["function"]["name"] for t in fake.chat_requests[0].json["tools"]] == ["get_tasks"]
    assert sse.of("proposal") == []  # create_task was not offered, so it is refused
    assert "unknown tool" in sse.of("tool_result")[0]["preview"]
