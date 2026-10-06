"""Cancellation: a client that goes away (or says stop) must stop the provider request."""

import asyncio
import json
import uuid
from typing import Any

from tests.ai.fake_upstream import (
    FakeUpstream,
    Reply,
    chunk,
    data,
    hang,
    sleep,
    text_reply,
    tool_reply,
)
from tests.ai.support import AiEnv, chat_body, make_conversation, run_chat


def endless() -> Reply:
    steps = [data(chunk({"role": "assistant", "content": ""}))]
    for _ in range(600):
        steps += [data(chunk({"content": "слово "})), sleep(0.05)]
    return Reply(steps)


async def saved_rows(aienv: AiEnv) -> list[dict[str, Any]]:
    await aienv.settle()
    reader = await aienv.device("Reader")
    return [c["row"] for c in await reader.pull_all() if c["table"] == "ai_messages"]


async def test_closing_the_connection_cancels_the_provider_request(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = endless()
    fake.queue(reply)
    body = chat_body(conversation)

    async with aienv.client.stream(
        "POST", "/ai/chat/completions", json=body, headers=phone.headers
    ) as response:
        async for line in response.aiter_lines():
            if line == "event: delta":
                break
    # leaving the block closed the connection; the server must close the provider's too
    await asyncio.wait_for(reply.client_closed.wait(), timeout=10)

    rows = await saved_rows(aienv)
    assert len(rows) == 1
    row = rows[0]
    assert row["id"] == body["assistant_message_id"]
    assert row["status"] == "cancelled" and row["error_code"] is None
    assert row["text"].startswith("слово")
    assert aienv.ai.runs == {}
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1  # what arrived is billed


async def test_cancel_before_any_provider_byte(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = Reply(steps=[hang()])
    fake.queue(reply)

    async with aienv.client.stream(
        "POST", "/ai/chat/completions", json=chat_body(conversation), headers=phone.headers
    ) as response:
        async for line in response.aiter_lines():
            if line == "event: start":
                break
        while not fake.chat_requests:
            await asyncio.sleep(0.02)
    await asyncio.wait_for(reply.client_closed.wait(), timeout=10)

    rows = await saved_rows(aienv)
    assert [(r["status"], r["text"]) for r in rows] == [("cancelled", "")]
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 0  # nothing arrived


async def test_the_cancel_endpoint_stops_a_running_answer(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = endless()
    fake.queue(reply)
    body = chat_body(conversation)
    stream = asyncio.create_task(run_chat(phone, body))
    while not fake.chat_requests:
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.3)

    stopped = await phone.post(f"/ai/chat/{body['assistant_message_id']}/cancel")
    assert stopped.json() == {"cancelled": True}
    sse = await asyncio.wait_for(stream, timeout=10)

    assert sse.names()[0] == "start" and "done" not in sse.names() and "error" not in sse.names()
    await asyncio.wait_for(reply.client_closed.wait(), timeout=10)
    rows = await saved_rows(aienv)
    assert rows[0]["status"] == "cancelled" and rows[0]["text"].startswith("слово")
    again = await phone.post(f"/ai/chat/{body['assistant_message_id']}/cancel")
    assert again.json() == {"cancelled": False}
    assert (await phone.post(f"/ai/chat/{uuid.uuid4()}/cancel")).json() == {"cancelled": False}


async def test_cancelling_a_finished_answer_changes_nothing(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["готово"]))
    body = chat_body(conversation)
    assert (await run_chat(phone, body)).last[0] == "done"
    await aienv.settle()
    assert (await phone.post(f"/ai/chat/{body['assistant_message_id']}/cancel")).json() == {
        "cancelled": False
    }
    assert [r["status"] for r in await saved_rows(aienv)] == ["done"]


async def test_cancel_during_a_tool_loop_keeps_what_was_done(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    second = endless()
    fake.queue(tool_reply([("c1", "get_tasks", "{}")], cost=0.02), second)
    body = chat_body(conversation)
    stream = asyncio.create_task(run_chat(phone, body))
    while len(fake.chat_requests) < 2:
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.2)
    await phone.post(f"/ai/chat/{body['assistant_message_id']}/cancel")
    sse = await asyncio.wait_for(stream, timeout=10)

    assert "tool_result" in sse.names() and "done" not in sse.names()
    row = (await saved_rows(aienv))[0]
    assert row["status"] == "cancelled"
    assert [p["type"] for p in row["parts"]] == ["tool_call", "tool_result", "text"]


async def test_the_same_message_id_cannot_run_twice(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(endless())
    body = chat_body(conversation)
    stream = asyncio.create_task(run_chat(phone, body))
    while not fake.chat_requests:
        await asyncio.sleep(0.02)

    twin = await run_chat(phone, body)

    assert twin.status == 409 and json.loads(twin.text)["error"]["details"] == {"status": "running"}
    await phone.post(f"/ai/chat/{body['assistant_message_id']}/cancel")
    await asyncio.wait_for(stream, timeout=10)
    await aienv.settle()


async def test_cancelling_twice_still_saves_the_answer_once(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    """The client closing the stream after an explicit cancel is a second cancel: no effect."""
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(endless())
    body = chat_body(conversation)
    stream = asyncio.create_task(run_chat(phone, body))
    while not fake.chat_requests:
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.3)
    run = aienv.ai.runs[uuid.UUID(body["assistant_message_id"])]

    assert run.cancel() is True
    for _ in range(300):  # more cancels while the first one is being settled and saved
        run.cancel()
        await asyncio.sleep(0)
    await asyncio.wait_for(stream, timeout=10)

    rows = await saved_rows(aienv)
    assert [(r["id"], r["status"]) for r in rows] == [(body["assistant_message_id"], "cancelled")]
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1
    assert aienv.ai.runs == {} and aienv.ai.reserved == {}


async def test_a_raw_cancel_of_the_task_while_it_is_saving_loses_nothing(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(endless())
    body = chat_body(conversation)
    stream = asyncio.create_task(run_chat(phone, body))
    while not fake.chat_requests:
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.3)
    task = aienv.ai.runs[uuid.UUID(body["assistant_message_id"])].task
    assert task is not None

    for _ in range(300):  # not through ``ChatRun.cancel``: any cancellation of the task
        task.cancel()
        await asyncio.sleep(0)
    await asyncio.wait_for(stream, timeout=10)

    assert [r["status"] for r in await saved_rows(aienv)] == ["cancelled"]
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1
