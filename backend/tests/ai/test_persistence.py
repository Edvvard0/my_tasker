"""An answer is never lost to its size: Cyrillic costs two bytes a letter, and the server's
validator and the runner measure the JSON the same way (``json_size_bytes``)."""

import json
from typing import Any

import pytest

from tasker.ai.runner import MAX_PARTS_JSON, OMITTED, fit_parts, storable
from tasker.ai.tables import MAX_PARTS_BYTES, PROPOSAL_ARGUMENTS_BYTES, ai_messages
from tasker.ai.tools_tasks import NOTES_MAX_CHARS
from tasker.sync.registry import json_column, json_size_bytes
from tests.ai.fake_upstream import FakeUpstream, text_reply, tool_reply
from tests.ai.support import AiEnv, chat_body, make_conversation, run_chat

# ------------------------------------------------------------------ the one measure


def test_the_measure_counts_utf8_bytes_of_compact_json() -> None:
    assert json_size_bytes({"a": "ж"}) == len('{"a":"') + 2 + len('"}')
    assert json_size_bytes("😀") == 6  # four bytes and two quotes
    assert json_size_bytes([1, None]) == len("[1,null]")


def test_ai_columns_use_the_measure_and_old_columns_keep_theirs() -> None:
    value = {"t": "ж" * 3000}  # 6 KB as UTF-8, 18 KB with ASCII escapes
    ai_column = ai_messages.by_name["parts"]
    assert ai_column.adapter.validate_python([value]) == [value]  # well inside 1 MiB
    old_style = json_column("x", max_bytes=16384)
    with pytest.raises(ValueError, match="larger than"):
        old_style.adapter.validate_python(value)  # other tables: behaviour unchanged
    assert json_column("x", max_bytes=16384, utf8=True).adapter.validate_python(value) == value
    with pytest.raises(ValueError, match="larger than"):
        json_column("x", max_bytes=1000, utf8=True).adapter.validate_python(value)


# ------------------------------------------------------------------ fit_parts / storable


def _result(index: int, size: int) -> dict[str, Any]:
    return {
        "type": "tool_result",
        "tool_call_id": f"c{index}",
        "name": "get_tasks",
        "content": "я" * size,
        "is_error": False,
    }


def test_fit_parts_leaves_small_parts_alone() -> None:
    parts = [{"type": "text", "text": "привет"}, _result(1, 100)]
    assert fit_parts(parts) is parts


def test_fit_parts_drops_tool_results_first_and_measures_utf8() -> None:
    parts: list[dict[str, Any]] = [{"type": "text", "text": "ответ"}]
    parts += [_result(i, 20_000) for i in range(30)]  # 30 x 40 KB of Cyrillic: 1.2 MB
    assert json_size_bytes(parts) > MAX_PARTS_JSON
    fitted = fit_parts(parts)
    assert json_size_bytes(fitted) <= MAX_PARTS_JSON < MAX_PARTS_BYTES
    assert [p["content"] for p in fitted if p["type"] == "tool_result"] == [OMITTED] * 30
    assert fitted[0] == {"type": "text", "text": "ответ"}  # the text survived
    assert parts[1]["content"] == "я" * 20_000  # the input is not modified


def test_fit_parts_shortens_the_longest_text_and_big_arguments() -> None:
    parts: list[dict[str, Any]] = [
        {"type": "text", "text": "ж" * 600_000},
        {"type": "text", "text": "короткий"},
        {"type": "tool_call", "id": "c", "name": "n", "arguments": {"x": "я" * 5000}},
        {
            "type": "tool_call",
            "id": "d",
            "name": "n",
            "arguments": None,
            "raw_arguments": "{" * 2000,
        },
    ]
    fitted = fit_parts(parts, limit=300_000)
    assert json_size_bytes(fitted) <= 300_000
    assert 0 < len(fitted[0]["text"]) < 600_000 and fitted[1]["text"] == "короткий"
    assert fitted[2]["arguments"] == {"omitted": "too large"}
    assert len(fitted[3]["raw_arguments"]) == 200


def test_storable_removes_nul_and_lone_surrogates() -> None:
    dirty = {"a\x00": ["x\x00y", "\ud800z", 5, None]}
    clean = storable(dirty)
    assert clean == {"a": ["xy", "?z", 5, None]}
    json_size_bytes(clean)  # encodable


# ------------------------------------------------------------------ through the API


async def test_a_task_proposal_in_cyrillic_at_every_limit_is_saved(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    args = {
        "title": "я" * 500,
        "notes": "ж" * NOTES_MAX_CHARS,
        "project": "п" * 200,
        "tags": ["т" * 50] * 5,
        "due_date": "2026-10-09",
        "due_time": "15:30",
        "priority": 1,
        "duration_minutes": 60,
    }
    assert len(json.dumps(args).encode()) > PROPOSAL_ARGUMENTS_BYTES  # the old measure refused it
    fake.queue(tool_reply([("t1", "create_task", json.dumps(args, ensure_ascii=False))]))

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.names() == ["start", "usage", "tool_call", "proposal", "done"], sse.text[:500]
    assert sse.last[1]["finish_reason"] == "awaiting_approval"
    await aienv.settle()
    assert await aienv.env.scalar("SELECT count(*) FROM ai_messages") == 1
    assert await aienv.env.scalar("SELECT count(*) FROM ai_tool_proposals") == 1
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1  # charged exactly once
    saved = await aienv.env.scalar("SELECT arguments FROM ai_tool_proposals")
    assert saved["notes"] == "ж" * NOTES_MAX_CHARS and saved["title"] == "я" * 500


async def test_notes_over_the_limit_go_back_to_the_model(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    too_long = {"title": "Задача", "notes": "ж" * (NOTES_MAX_CHARS + 1)}
    fixed = {"title": "Задача", "notes": "ж" * NOTES_MAX_CHARS}
    fake.queue(
        tool_reply([("t1", "create_task", json.dumps(too_long, ensure_ascii=False))]),
        tool_reply([("t2", "create_task", json.dumps(fixed, ensure_ascii=False))]),
    )

    sse = await run_chat(phone, chat_body(conversation))

    assert [r["is_error"] for r in sse.of("tool_result")] == [True]
    assert len(sse.of("proposal")) == 1 and sse.last[0] == "done"
    schema = next(
        spec["function"]["parameters"]
        for spec in fake.chat_requests[0].json["tools"]
        if spec["function"]["name"] == "create_task"
    )
    assert schema["properties"]["notes"]["maxLength"] == NOTES_MAX_CHARS


async def test_arguments_too_large_to_store_are_an_error_not_a_lost_answer(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    # control characters cost 6 bytes each once escaped: valid by length, too big to store
    args = {
        "title": "\x01" * 500,
        "notes": "\x01" * NOTES_MAX_CHARS,
        "project": "\x01" * 200,
        "tags": ["\x01" * 50] * 5,
    }
    fake.queue(tool_reply([("t1", "create_task", json.dumps(args))]), text_reply(["ок"]))

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.of("proposal") == [] and sse.of("tool_result")[0]["is_error"] is True
    assert sse.last[0] == "done"
    await aienv.settle()
    assert await aienv.env.scalar("SELECT count(*) FROM ai_messages") == 1


@pytest.mark.parametrize(("letters", "kept"), [(200_000, 200_000), (450_000, 390_000)])
async def test_a_very_long_russian_answer_is_saved(
    aienv: AiEnv, fake: FakeUpstream, letters: int, kept: int
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    piece = "слово " * 1000  # 6000 characters
    pieces = [piece] * (letters // len(piece)) + ["я" * (letters % len(piece))]
    fake.queue(text_reply(pieces, cost=0.5))

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.last[0] == "done", sse.last
    await aienv.settle()
    assert await aienv.env.scalar("SELECT length(text) FROM ai_messages") == kept
    size = await aienv.env.scalar("SELECT pg_column_size(parts) FROM ai_messages")
    assert size > 0
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1
    assert await aienv.env.scalar("SELECT sum(cost_kopecks) FROM ai_spend") == 50


async def test_a_nul_in_the_answer_does_not_lose_it(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["до\x00после"]))
    bad_args = json.dumps({"title": "a\u0000b"})
    sse = await run_chat(phone, chat_body(conversation))
    assert sse.last[0] == "done"
    await aienv.settle()
    assert await aienv.env.scalar("SELECT text FROM ai_messages") == "допосле"
    fake.queue(tool_reply([("t1", "create_task", bad_args)]), text_reply(["ок"]))
    again = await run_chat(phone, chat_body(conversation))
    assert again.of("proposal") == [] and again.last[0] == "done"
    await aienv.settle()
    assert await aienv.env.scalar("SELECT count(*) FROM ai_messages") == 2
