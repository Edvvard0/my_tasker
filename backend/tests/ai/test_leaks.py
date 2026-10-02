"""The provider key never leaves the server: responses, streams, errors, logs, database."""

import json
import logging

import pytest
import structlog
from pydantic import ValidationError

from tasker.config import Settings
from tasker.logging import REDACTED, make_redactor
from tests.ai.fake_upstream import FakeUpstream, error_reply, tool_reply
from tests.ai.support import KEY, AiEnv, chat_body, make_conversation, run_chat


async def database_text(aienv: AiEnv) -> str:
    """Every row of every table as text."""
    tables = await aienv.env.scalar(
        "SELECT string_agg(table_name, ',') FROM information_schema.tables WHERE table_schema = 'public'"
    )
    chunks = []
    for table in tables.split(","):
        dump = await aienv.env.scalar(
            f"SELECT coalesce(string_agg(t::text, E'\\n'), '') FROM \"{table}\" t"
        )
        chunks.append(dump)
    return "\n".join(chunks)


async def test_the_key_is_used_upstream_and_nowhere_else(
    aienv: AiEnv, fake: FakeUpstream, monkeypatch: pytest.MonkeyPatch
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    seen: list[str] = []

    # a normal answer with tools and a proposal
    fake.queue(
        tool_reply([("c1", "get_tasks", "{}")]),
        tool_reply([("c2", "create_task", '{"title": "x"}')]),
    )
    sse = await run_chat(phone, chat_body(conversation))
    seen.append(sse.text)
    # every kind of provider failure, with the key echoed in the provider's body and headers
    for status in (400, 401, 402, 404, 429, 500, 503):
        fake.queue(
            error_reply(status, f'{{"error": "bad key {KEY}", "key": "{KEY}"}}', **{"x-echo": KEY})
        )
        seen.append((await run_chat(phone, chat_body(conversation))).text)
    # an unexpected crash inside the run, whose exception text carries the key
    from tasker.ai import runner  # noqa: PLC0415

    async def boom(self: object, payload: object) -> None:
        raise RuntimeError(f"failed with Authorization: Bearer {KEY} and key={KEY}")

    monkeypatch.setattr(runner.ChatRun, "_call_model", boom)
    crashed = await run_chat(phone, chat_body(conversation))
    seen.append(crashed.text)
    assert (
        crashed.last[1]["code"] == "internal_error"
        and crashed.last[1]["message"] == "Internal error"
    )
    monkeypatch.undo()
    # the other endpoints, errors included
    seen.append((await phone.post("/ai/bootstrap")).text)
    seen.append((await phone.get("/ai/models")).text)
    fake.models_reply = error_reply(500, KEY)
    seen.append((await phone.get("/ai/models", refresh="true")).text)
    seen.append((await phone.get("/ai/usage")).text)
    seen.append((await aienv.client.get("/openapi.json")).text)
    await aienv.settle()
    reader = await aienv.device("Reader")
    seen.append(json.dumps(await reader.pull_all()))

    for text in seen:
        assert KEY not in text
    logs = aienv.logs.getvalue()
    assert "Traceback" in logs and "chat_run_failed" in logs  # the crash was logged ...
    assert KEY not in logs and REDACTED in logs  # ... without the key
    assert "bad key" not in logs  # the provider's body is not logged either
    assert KEY not in await database_text(aienv)
    # positive control: the provider did receive the key, in the header only
    assert {r.headers["authorization"] for r in fake.chat_requests} == {f"Bearer {KEY}"}
    assert all(KEY not in json.dumps(r.json) for r in fake.requests)


async def test_the_key_is_not_in_settings_output() -> None:
    settings = Settings(database_url="postgresql://u:p@h/d", polza_api_key=KEY, _env_file=None)
    assert (
        KEY not in repr(settings)
        and KEY not in str(settings)
        and KEY not in str(settings.model_dump())
    )
    assert KEY not in settings.model_dump_json()
    assert settings.polza_api_key is not None and settings.polza_api_key.get_secret_value() == KEY


def test_blank_variables_mean_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("POLZA_API_KEY", "")
    monkeypatch.setenv("POLZA_BASE_URL", "  ")
    settings = Settings(database_url="postgresql://u:p@h/d", _env_file=None)
    assert settings.polza_api_key is None
    assert settings.polza_base_url == "https://polza.ai/api/v1"
    with pytest.raises(ValidationError):
        Settings(
            database_url="postgresql://u:p@h/d", ai_billing_timezone="Mars/Base", _env_file=None
        )


# ------------------------------------------------------------------ the redaction processor


def run(processor: structlog.typing.Processor, **event: object) -> dict[str, object]:
    result: dict[str, object] = dict(processor(None, "info", dict(event)))  # type: ignore[arg-type]
    return result


def test_redactor_scrubs_by_key_by_shape_and_by_value() -> None:
    redact = make_redactor([KEY, "short"])
    out = run(
        redact,
        event="request",
        authorization="Bearer abc.def",
        api_key="whatever",
        headers={"Authorization": "x", "X-Api-Key": "y", "accept": "json"},
        nested=[{"password": "p", "note": f"the key {KEY} appears"}],
        refresh_token="r",
        text="Bearer abc123 and sk-abcdefghij12345 and basic dXNlcjpwYXNz",
        exception=f"RuntimeError: {KEY}",
        count=3,
        prompt_tokens=10,
        max_tokens=5,
    )
    assert out["authorization"] == out["api_key"] == out["refresh_token"] == REDACTED
    assert out["headers"] == {"Authorization": REDACTED, "X-Api-Key": REDACTED, "accept": "json"}
    assert out["nested"] == [{"password": REDACTED, "note": f"the key {REDACTED} appears"}]
    assert out["text"] == f"Bearer {REDACTED} and {REDACTED} and basic {REDACTED}"
    assert out["exception"] == f"RuntimeError: {REDACTED}"
    # numbers and token counts are not secrets
    assert (out["count"], out["prompt_tokens"], out["max_tokens"]) == (3, 10, 5)
    # a secret shorter than six characters is too ordinary to scrub by value
    assert run(redact, event="short thing")["event"] == "short thing"


def test_redactor_handles_deep_and_odd_structures() -> None:
    redact = make_redactor([KEY])
    deep: object = KEY
    for _ in range(12):
        deep = [deep]
    assert run(redact, event="e", deep=deep)["event"] == "e"
    assert run(redact, event="e", obj=object, data=(1, KEY))["data"] == [1, REDACTED]
    assert make_redactor()(None, "info", {"event": "plain"}) == {"event": "plain"}


async def test_stdlib_logging_goes_through_the_redactor(aienv: AiEnv) -> None:
    logging.getLogger("some.library").error("connection to %s failed with key %s", "host", KEY)
    try:
        raise ValueError(f"inner {KEY}")
    except ValueError:
        logging.getLogger("some.library").exception("oops")
    logs = aienv.logs.getvalue()
    assert "oops" in logs and "connection to host failed" in logs
    assert KEY not in logs
