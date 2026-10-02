"""Stage 10: conversations with ``mode = local`` are written by the *client*.

The on-device model answers without the server, so the assistant message, the tool message and the
``create_task`` proposal (with a client-chosen ``entity_id``) arrive through plain ``POST
/sync/push``. The cloud rules do not change: the server still writes the answers of cloud chats.
"""

import asyncio
import uuid
from typing import Any

from tasker.ids import uuid7
from tests.ai.support import AiEnv, make_conversation
from tests.api_support import DeviceClient
from tests.calendar_support import task_fields

ARGS = {"title": "Купить молоко", "due_date": "2026-10-06", "due_time": "09:00", "priority": 2}
LOCAL_MODEL = "local/gemma-4-e2b-it"


def message_op(
    device: DeviceClient, conversation_id: uuid.UUID, role: str, **fields: Any
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "conversation_id": str(conversation_id),
        "role": role,
        "text": "",
        "parts": [],
        "status": "done",
        "created_at": device.created(),
        **fields,
    }
    return device.op("ai_messages", uuid7(), fields=body)


def local_answer_ops(
    device: DeviceClient, conversation_id: uuid.UUID
) -> tuple[list[dict[str, Any]], uuid.UUID, uuid.UUID]:
    """What the app writes after a local ``create_task`` answer: message + proposal, one batch."""
    proposal_id, entity_id = uuid7(), uuid7()
    message = message_op(
        device,
        conversation_id,
        "assistant",
        text="Предлагаю создать задачу «Купить молоко».",
        model=LOCAL_MODEL,
        finish_reason="awaiting_approval",
        prompt_tokens=900,
        completion_tokens=40,
        cost_kopecks=0,
        latency_ms=21_000,
        parts=[
            {"type": "text", "text": "Предлагаю создать задачу «Купить молоко»."},
            {"type": "tool_call", "id": "call_1", "name": "create_task", "arguments": ARGS},
            {
                "type": "proposal",
                "proposal_id": str(proposal_id),
                "tool_call_id": "call_1",
                "tool": "create_task",
            },
        ],
    )
    proposal = device.op(
        "ai_tool_proposals",
        proposal_id,
        fields={
            "message_id": message["id"],
            "tool_call_id": "call_1",
            "tool": "create_task",
            "entity_type": "task",
            "entity_id": str(entity_id),
            "original_arguments": ARGS,
            "arguments": ARGS,
            "status": "pending",
            "reject_reason": None,
            "decided_at": None,
            "created_at": device.created(),
        },
    )
    return [message, proposal], proposal_id, entity_id


async def test_client_writes_a_local_conversation_and_the_other_device_gets_it(
    aienv: AiEnv,
) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    conversation = await make_conversation(phone, mode="local", model=LOCAL_MODEL)
    user = message_op(
        phone,
        conversation,
        "user",
        text="Купить молоко завтра в 9",
        parts=[{"type": "text", "text": "Купить молоко завтра в 9"}],
    )
    answer, proposal_id, entity_id = local_answer_ops(phone, conversation)
    tool = message_op(
        phone,
        conversation,
        "tool",
        text="task created",
        parts=[
            {
                "type": "tool_result",
                "tool_call_id": "call_1",
                "name": "create_task",
                "content": "awaiting user approval",
                "is_error": False,
            }
        ],
    )

    results = await phone.push_ok([user, *answer, tool])
    assert [r["status"] for r in results] == ["applied"] * 4, results

    changes = await pc.pull_all()
    rows: dict[str, list[dict[str, Any]]] = {}
    for change in changes:
        rows.setdefault(change["table"], []).append(change["row"])
    conversation_row = next(r for r in rows["ai_conversations"] if r["id"] == str(conversation))
    assert conversation_row["mode"] == "local" and conversation_row["model"] == LOCAL_MODEL
    assert sorted(m["role"] for m in rows["ai_messages"]) == ["assistant", "tool", "user"]
    assistant = next(m for m in rows["ai_messages"] if m["role"] == "assistant")
    assert assistant["cost_kopecks"] == 0 and assistant["model"] == LOCAL_MODEL
    assert [p["type"] for p in assistant["parts"]] == ["text", "tool_call", "proposal"]
    proposal = rows["ai_tool_proposals"][0]
    assert proposal["id"] == str(proposal_id) and proposal["entity_id"] == str(entity_id)
    assert proposal["status"] == "pending" and proposal["message_id"] == assistant["id"]


async def test_one_approval_one_task_for_a_client_written_proposal(aienv: AiEnv) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    conversation = await make_conversation(phone, mode="local", model=LOCAL_MODEL)
    answer, proposal_id, entity_id = local_answer_ops(phone, conversation)
    await phone.push_ok(answer)
    pulled = [c for c in await pc.pull_all() if c["table"] == "ai_tool_proposals"]
    version = pulled[0]["row"]["server_version"]

    def approve(device: DeviceClient) -> list[dict[str, Any]]:
        task = device.op(
            "tasks",
            entity_id,
            fields=task_fields(device, title=ARGS["title"], due_date="2026-10-06", source="ai"),
        )
        decision = device.op(
            "ai_tool_proposals",
            proposal_id,
            fields={"status": "approved", "decided_at": device.created(), "arguments": ARGS},
            base=version,
        )
        return [task, decision]

    # Both devices tap "Approve" (double tap, two devices): one task row, no conflict storm.
    first, second = await asyncio.gather(phone.push_ok(approve(phone)), pc.push_ok(approve(pc)))
    for results in (first, second):
        assert all(r["status"] in {"applied", "merged", "noop"} for r in results), results

    changes = await phone.pull_all()
    tasks = [c["row"] for c in changes if c["table"] == "tasks"]
    assert [t["id"] for t in tasks] == [str(entity_id)]
    assert tasks[0]["source"] == "ai"
    decided = [c["row"] for c in changes if c["table"] == "ai_tool_proposals"][0]
    assert decided["status"] == "approved" and decided["entity_id"] == str(entity_id)


async def test_the_proposal_message_and_entity_are_immutable(aienv: AiEnv) -> None:
    """A client-written proposal keeps the server's immutability rules (entity_id never moves)."""
    phone = await aienv.device("Phone")
    conversation = await make_conversation(phone, mode="local", model=LOCAL_MODEL)
    answer, proposal_id, _ = local_answer_ops(phone, conversation)
    await phone.push_ok(answer)
    row = [c for c in await phone.pull_all() if c["table"] == "ai_tool_proposals"][0]["row"]

    attempt = phone.op(
        "ai_tool_proposals",
        proposal_id,
        fields={"entity_id": str(uuid7())},
        base=row["server_version"],
    )
    result = (await phone.push([attempt])).json()["results"][0]
    assert result["status"] == "rejected"
    assert result["code"] == "immutable_field"


async def test_a_streaming_status_is_accepted_for_local_messages(aienv: AiEnv) -> None:
    """The app may write an assistant message as ``streaming`` first and finish it later."""
    phone = await aienv.device("Phone")
    conversation = await make_conversation(phone, mode="local", model=LOCAL_MODEL)
    draft = message_op(phone, conversation, "assistant", status="streaming", text="Начало")
    assert (await phone.push_ok([draft]))[0]["status"] == "applied"
    final = phone.op(
        "ai_messages",
        uuid.UUID(draft["id"]),
        fields={"status": "done", "text": "Начало и конец"},
        base=1,
    )
    results = await phone.push_ok([final])
    assert results[0]["status"] in {"applied", "merged"}, results
