"""Proposal lifecycle: one approval = exactly one task, however many devices or clicks."""

import asyncio
import json
import uuid
from typing import Any

from tests.ai.fake_upstream import FakeUpstream, text_reply, tool_reply
from tests.ai.support import AiEnv, chat_body, make_conversation, run_chat
from tests.api_support import DeviceClient
from tests.calendar_support import task_fields

ARGS = {"title": "Сдать отчёт", "due_date": "2026-10-09", "priority": 2}


async def propose(aienv: AiEnv, fake: FakeUpstream, device: DeviceClient) -> dict[str, Any]:
    """Run a chat in which the model proposes a task; return the pulled proposal row."""
    conversation = await make_conversation(device)
    fake.queue(tool_reply([("t1", "create_task", json.dumps(ARGS))]), text_reply(["не нужно"]))
    sse = await run_chat(device, chat_body(conversation))
    assert sse.last[0] == "done", sse.text
    await aienv.settle()
    rows = [c for c in await device.pull_all() if c["table"] == "ai_tool_proposals"]
    assert len(rows) == 1
    row: dict[str, Any] = rows[0]["row"]
    return row


def approve_ops(
    device: DeviceClient, proposal: dict[str, Any], **edits: Any
) -> list[dict[str, Any]]:
    """What the client does on "Approve": the task with the proposal's id, then the decision."""
    arguments = {**ARGS, **edits}
    task = device.op(
        "tasks",
        uuid.UUID(proposal["entity_id"]),
        fields=task_fields(
            device,
            title=arguments["title"],
            due_date=arguments["due_date"],
            priority=arguments["priority"],
            source="ai",
        ),
    )
    decision = device.op(
        "ai_tool_proposals",
        uuid.UUID(proposal["id"]),
        fields={
            "status": "edited_approved" if edits else "approved",
            "decided_at": device.created(),
            "arguments": arguments,
        },
        base=proposal["server_version"],
    )
    return [task, decision]


async def test_approval_creates_one_task_and_marks_the_proposal(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    proposal = await propose(aienv, fake, phone)

    results = await phone.push_ok(approve_ops(phone, proposal))
    assert [r["status"] for r in results] == ["applied", "applied"]

    changes = await pc.pull_all()
    tasks = [c["row"] for c in changes if c["table"] == "tasks"]
    decided = [c["row"] for c in changes if c["table"] == "ai_tool_proposals"][0]
    assert [t["id"] for t in tasks] == [proposal["entity_id"]] and tasks[0]["source"] == "ai"
    assert decided["status"] == "approved" and decided["decided_at"] is not None
    assert decided["entity_id"] == proposal["entity_id"]


async def test_concurrent_double_approval_makes_exactly_one_task(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    proposal = await propose(aienv, fake, phone)
    pc_view = [c["row"] for c in await pc.pull_all() if c["table"] == "ai_tool_proposals"][0]

    # two devices, and a double click on each, all at once: four independent pushes
    pushes = [
        phone.push(approve_ops(phone, proposal)),
        pc.push(approve_ops(pc, pc_view)),
        phone.push(approve_ops(phone, proposal)),
        pc.push(approve_ops(pc, pc_view, title="Сдать отчёт до 12:00")),
    ]
    responses = await asyncio.gather(*pushes)

    for response in responses:
        assert response.status_code == 200
        assert [r["status"] for r in response.json()["results"]] == ["applied", "applied"]
    assert await aienv.env.scalar("SELECT count(*) FROM tasks") == 1
    assert await aienv.env.scalar("SELECT id::text FROM tasks") == proposal["entity_id"]
    assert await aienv.env.scalar("SELECT count(*) FROM ai_tool_proposals") == 1
    status = await aienv.env.scalar("SELECT status FROM ai_tool_proposals")
    assert status in ("approved", "edited_approved")
    title = await aienv.env.scalar("SELECT title FROM tasks")
    assert title in ("Сдать отчёт", "Сдать отчёт до 12:00")


async def test_approve_and_reject_race_never_makes_two_tasks(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    proposal = await propose(aienv, fake, phone)
    pc_view = [c["row"] for c in await pc.pull_all() if c["table"] == "ai_tool_proposals"][0]
    reject = pc.op(
        "ai_tool_proposals",
        uuid.UUID(pc_view["id"]),
        fields={
            "status": "rejected",
            "decided_at": pc.created(),
            "reject_reason": "не надо",
        },
        base=pc_view["server_version"],
        hlc=pc.at(500),  # the rejection is the later decision
    )
    await asyncio.gather(pc.push_ok([reject]), phone.push_ok(approve_ops(phone, proposal)))
    # the later decision wins the proposal; the task made by the approving device stays
    # (exactly one, the documented outcome of spec 2.6)
    assert await aienv.env.scalar("SELECT count(*) FROM tasks") == 1
    assert await aienv.env.scalar("SELECT status FROM ai_tool_proposals") == "rejected"
    assert await aienv.env.scalar("SELECT reject_reason FROM ai_tool_proposals") == "не надо"


async def test_reject_keeps_the_task_away(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    proposal = await propose(aienv, fake, phone)
    results = await phone.push_ok(
        [
            phone.op(
                "ai_tool_proposals",
                uuid.UUID(proposal["id"]),
                fields={
                    "status": "rejected",
                    "decided_at": phone.created(),
                    "reject_reason": "уже сделал",
                },
                base=proposal["server_version"],
            )
        ]
    )
    assert results[0]["status"] == "applied"
    assert await aienv.env.scalar("SELECT count(*) FROM tasks") == 0
    assert await aienv.env.scalar("SELECT reject_reason FROM ai_tool_proposals") == "уже сделал"


async def test_proposal_invariants_are_enforced(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    proposal = await propose(aienv, fake, phone)
    proposal_id = uuid.UUID(proposal["id"])
    version = proposal["server_version"]

    def attempt(**fields: Any) -> dict[str, Any]:
        return phone.op("ai_tool_proposals", proposal_id, fields=fields, base=version)

    bad = await phone.push_ok(
        [
            attempt(status="approved"),  # decided without a time
            attempt(decided_at=phone.created()),  # pending with a time
            attempt(entity_id=str(uuid.uuid4())),  # the id of the entity is fixed
            attempt(original_arguments={"title": "подмена"}),
            attempt(tool="delete_everything"),
            attempt(arguments=["not", "an", "object"]),
            attempt(status="maybe"),
        ]
    )
    assert [r["code"] for r in bad] == [
        "validation_failed",
        "validation_failed",
        "immutable_field",
        "immutable_field",
        "immutable_field",
        "validation_failed",
        "invalid_field",
    ]
    ok = await phone.push_ok([attempt(arguments={**ARGS, "title": "Правка"})])  # editing is fine
    assert ok[0]["status"] == "applied"
    assert await aienv.env.scalar("SELECT status FROM ai_tool_proposals") == "pending"


async def test_deleting_the_conversation_takes_messages_and_proposals_along(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    proposal = await propose(aienv, fake, phone)
    conversation = await aienv.env.scalar("SELECT conversation_id::text FROM ai_messages")
    await phone.push_ok([phone.op("ai_conversations", uuid.UUID(conversation), "delete", base=1)])
    changes = await pc.pull_all()
    deleted = {
        c["table"]: c["row"]["deleted_at"] is not None
        for c in changes
        if c["table"].startswith("ai_")
    }
    assert deleted["ai_messages"] and deleted["ai_tool_proposals"] and deleted["ai_conversations"]
    assert proposal["id"] in {c["id"] for c in changes}
