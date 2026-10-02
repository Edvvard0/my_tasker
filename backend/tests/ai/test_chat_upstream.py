"""Provider failures: 4xx/5xx, retries before the first byte only, cut streams, timeouts."""

import json
from typing import Any

import pytest

from tests.ai.fake_upstream import (
    FakeUpstream,
    Reply,
    abort,
    chunk,
    data,
    error_reply,
    raw,
    sleep,
    text_reply,
)
from tests.ai.support import KEY, AiEnv, chat_body, make_ai_env, make_conversation, run_chat


async def saved_message(aienv: AiEnv) -> dict[str, Any]:
    await aienv.settle()
    device = await aienv.device("Reader")
    rows = [c["row"] for c in await device.pull_all() if c["table"] == "ai_messages"]
    assert len(rows) == 1, rows
    row: dict[str, Any] = rows[0]
    return row


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (402, "upstream_payment_required", False),
        (404, "model_not_found", False),
        (400, "upstream_rejected", False),
        (401, "upstream_rejected", False),
        (422, "upstream_rejected", False),
        (500, "upstream_error", True),
        (503, "upstream_error", True),
        (429, "upstream_rate_limited", True),
        (504, "upstream_timeout", True),
    ],
)
async def test_provider_http_errors_become_error_events(
    aienv: AiEnv, fake: FakeUpstream, status: int, code: str, retryable: bool
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(error_reply(status, f'{{"error": {{"message": "echo {KEY}"}}}}'))

    sse = await run_chat(phone, chat_body(conversation))

    assert sse.status == 200 and sse.names() == ["start", "error"]
    error = sse.of("error")[0]
    assert (error["code"], error["retryable"]) == (code, retryable)
    assert KEY not in sse.text and "echo" not in sse.text  # the provider's body never reaches us
    row = await saved_message(aienv)
    assert (row["status"], row["error_code"], row["text"]) == ("error", code, "")
    assert error["message_id"] == row["id"]
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 0  # a failed call is free


async def test_retries_happen_before_the_first_byte(
    migrated_db_url: str, fake: FakeUpstream
) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_max_retries=2) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        fake.queue(
            error_reply(503),
            error_reply(429, retry_after="0"),
            Reply(steps=[sleep(0)]),  # a 200 that closes before sending anything
            text_reply(["наконец"]),
        )
        sse = await run_chat(phone, chat_body(conversation))
        # three retries are not allowed (max 2), so the fourth reply is never reached
        assert sse.last[0] == "error" and len(fake.chat_requests) == 3

        fake.requests.clear()
        fake.replies.clear()  # the unused fourth reply
        fake.queue(error_reply(500), text_reply(["со второй попытки"]))
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.last[0] == "done" and len(fake.chat_requests) == 2
        assert "".join(d["text"] for d in sse.of("delta")) == "со второй попытки"
        # an error that is not transient is not retried
        fake.requests.clear()
        fake.queue(error_reply(400), text_reply(["не дойдёт"]))
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.last[1]["code"] == "upstream_rejected" and len(fake.chat_requests) == 1


async def test_a_cut_stream_is_never_retried(migrated_db_url: str, fake: FakeUpstream) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_max_retries=2) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        fake.queue(
            Reply(
                steps=[
                    data(chunk({"role": "assistant", "content": ""})),
                    data(chunk({"content": "Начало ответа, "})),
                    data(chunk({"content": "и тут"})),
                    abort(),
                ]
            ),
            text_reply(["не должен запрашиваться"]),
        )

        sse = await run_chat(phone, chat_body(conversation))

        assert sse.names() == ["start", "delta", "delta", "usage", "error"]
        assert sse.last[1]["code"] == "upstream_error" and sse.last[1]["retryable"] is True
        assert len(fake.chat_requests) == 1  # a retry would have duplicated the text
        row = await saved_message(aienv)
        assert (row["status"], row["error_code"]) == ("error", "upstream_error")
        assert row["text"] == "Начало ответа, и тут"  # the partial answer is kept
        assert row["parts"] == [{"type": "text", "text": "Начало ответа, и тут"}]
        # the received part is still billed (estimated: no usage arrived)
        assert await aienv.env.scalar("SELECT estimated FROM ai_spend") is True


async def test_slow_first_byte_times_out(migrated_db_url: str, fake: FakeUpstream) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_first_byte_timeout=0.4) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        fake.queue(Reply(steps=[sleep(3), *text_reply(["поздно"]).steps]))

        sse = await run_chat(phone, chat_body(conversation))

        assert sse.names() == ["start", "error"]
        assert (sse.last[1]["code"], sse.last[1]["retryable"]) == ("upstream_timeout", True)
        assert (await saved_message(aienv))["error_code"] == "upstream_timeout"


async def test_a_slow_first_byte_is_retried_then_succeeds(
    migrated_db_url: str, fake: FakeUpstream
) -> None:
    async with make_ai_env(
        migrated_db_url, fake, polza_first_byte_timeout=0.4, polza_max_retries=1
    ) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        fake.queue(Reply(steps=[sleep(3)]), text_reply(["быстро"]))
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.last[0] == "done" and len(fake.chat_requests) == 2


async def test_a_stall_in_the_middle_hits_the_idle_timeout(
    migrated_db_url: str, fake: FakeUpstream
) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_idle_timeout=0.4) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        fake.queue(
            Reply(
                steps=[data(chunk({"content": "Раз"})), sleep(3), data(chunk({"content": "два"}))]
            )
        )

        sse = await run_chat(phone, chat_body(conversation))

        assert sse.names() == ["start", "delta", "usage", "error"]
        assert sse.last[1]["code"] == "upstream_timeout"
        assert (await saved_message(aienv))["text"] == "Раз"


async def test_the_total_timeout_applies(migrated_db_url: str, fake: FakeUpstream) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_total_timeout=0.6) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        steps = []
        for _ in range(40):
            steps += [data(chunk({"content": "."})), sleep(0.1)]
        fake.queue(Reply(steps=steps))
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.last[1]["code"] == "upstream_timeout"


@pytest.mark.parametrize(
    "steps",
    [
        [raw("data: {not json}\n\n")],
        [raw('data: ["a list"]\n\n')],
        [raw('data: {"error": {"message": "overloaded"}}\n\n')],
        [data(chunk({"content": "без финиша"})), raw("data: [DONE]\n\n")],
        [data(chunk({"content": "без финиша"}))],
    ],
)
async def test_protocol_violations_are_upstream_errors(
    aienv: AiEnv, fake: FakeUpstream, steps: list[Any]
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(Reply(steps=steps))
    sse = await run_chat(phone, chat_body(conversation))
    assert sse.last[0] == "error" and sse.last[1]["code"] == "upstream_error"
    assert "overloaded" not in sse.text


async def test_comments_and_blank_lines_are_ignored(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = text_reply(["ok"])
    reply.steps = [raw(": keep-alive\n\n"), raw("event: ping\n\n"), *reply.steps]
    fake.queue(reply)
    assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"


async def test_the_provider_not_answering_at_all_is_an_error(
    migrated_db_url: str, fake: FakeUpstream
) -> None:
    await fake.stop()  # connection refused
    async with make_ai_env(migrated_db_url, fake) as aienv:
        phone = await aienv.device()
        conversation = await make_conversation(phone)
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.last[1]["code"] == "upstream_error" and "127.0.0.1" not in sse.text
    await fake.start()


async def test_usage_is_missing_and_estimated(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = text_reply(["a" * 300])
    reply.steps = [s for s in reply.steps if not (s.kind == "data" and s.payload["choices"] == [])]
    fake.queue(reply)

    sse = await run_chat(
        phone, chat_body(conversation, messages=[{"role": "user", "content": "x" * 600}])
    )

    done = sse.of("done")[0]
    assert done["completion_tokens"] == 100  # 300 characters / 3
    assert done["prompt_tokens"] > 200
    assert await aienv.env.scalar("SELECT estimated FROM ai_spend") is True
    assert json.dumps(done)  # serialisable
