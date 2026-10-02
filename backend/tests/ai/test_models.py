"""The model catalog: normalisation, filters, TTL cache, stale copy, failures."""

import json
from datetime import UTC, datetime
from typing import Any

import pytest

from tasker.ai.catalog import ModelCatalog, parse_model
from tasker.ai.upstream import UpstreamError
from tests.ai.fake_upstream import MODELS, FakeUpstream, error_reply
from tests.ai.support import AiEnv, make_ai_env


async def test_catalog_is_normalised(aienv: AiEnv) -> None:
    phone = await aienv.device()
    body = (await phone.get("/ai/models")).json()
    assert body["stale"] is False and body["fetched_at"].endswith("Z")
    by_id = {m["id"]: m for m in body["models"]}
    assert set(by_id) == {"openai/gpt-4o", "vendor/plain-model"}  # the embedding model is out
    assert by_id["openai/gpt-4o"] == {
        "id": "openai/gpt-4o",
        "name": "GPT-4o",
        "context_length": 128000,
        "max_completion_tokens": 16384,
        "supports_tools": True,
        "price_input_kopecks_per_mtok": 25000,
        "price_output_kopecks_per_mtok": 100000,
    }
    plain = by_id["vendor/plain-model"]
    assert plain["supports_tools"] is False and plain["max_completion_tokens"] is None
    assert (plain["price_input_kopecks_per_mtok"], plain["price_output_kopecks_per_mtok"]) == (
        1000,
        2000,
    )


async def test_filters(aienv: AiEnv) -> None:
    phone = await aienv.device()
    only_tools = (await phone.get("/ai/models", tools="true")).json()["models"]
    assert [m["id"] for m in only_tools] == ["openai/gpt-4o"]
    found = (await phone.get("/ai/models", q="PLAIN")).json()["models"]
    assert [m["id"] for m in found] == ["vendor/plain-model"]
    assert (await phone.get("/ai/models", q="gpt")).json()["models"][0]["id"] == "openai/gpt-4o"
    assert (await phone.get("/ai/models", q="zzz")).json()["models"] == []


async def test_the_catalog_is_cached_and_the_key_is_not_sent(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    await phone.get("/ai/models")
    await phone.get("/ai/models", q="x")
    assert fake.models_calls == 1
    await phone.get("/ai/models", refresh="true")
    assert fake.models_calls == 2
    assert all(
        "authorization" not in r.headers for r in fake.requests if r.path.endswith("/models")
    )


async def test_ttl_expiry_refetches(migrated_db_url: str, fake: FakeUpstream) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_models_ttl_seconds=0.2) as aienv:
        phone = await aienv.device()
        await phone.get("/ai/models")
        await phone.get("/ai/models")
        assert fake.models_calls == 1
        import asyncio  # noqa: PLC0415

        await asyncio.sleep(0.3)
        await phone.get("/ai/models")
        assert fake.models_calls == 2


async def test_a_stale_copy_is_served_when_the_provider_fails(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    first = (await phone.get("/ai/models")).json()
    fake.models_reply = error_reply(500)
    again = (await phone.get("/ai/models", refresh="true")).json()
    assert again["stale"] is True and again["models"] == first["models"]
    assert again["fetched_at"] == first["fetched_at"]
    # a failing provider is not hammered: the next plain read does not call it again
    calls = fake.models_calls
    await phone.get("/ai/models")
    assert fake.models_calls == calls
    fake.models_reply = None
    assert (await phone.get("/ai/models", refresh="true")).json()["stale"] is False


@pytest.mark.parametrize(
    ("reply", "status", "code"),
    [(error_reply(500), 502, "upstream_error"), (error_reply(504), 504, "upstream_timeout")],
)
async def test_no_catalog_and_a_failing_provider(
    aienv: AiEnv, fake: FakeUpstream, reply: Any, status: int, code: str
) -> None:
    fake.models_reply = reply
    phone = await aienv.device()
    response = await phone.get("/ai/models")
    assert response.status_code == status and response.json()["error"]["code"] == code


async def test_a_bad_catalog_shape_is_an_upstream_error(aienv: AiEnv, fake: FakeUpstream) -> None:
    from tests.ai.fake_upstream import Reply  # noqa: PLC0415

    phone = await aienv.device()
    for body in ('"nope"', "not json", '{"data": 5}'):
        fake.models_reply = Reply(body=body)
        response = await phone.get("/ai/models", refresh="true")
        assert response.status_code == 502, body
    fake.models_reply = Reply(body=json.dumps(MODELS["data"]))  # a bare list is fine
    assert (await phone.get("/ai/models", refresh="true")).status_code == 200


async def test_chat_still_works_when_the_catalog_is_down(aienv: AiEnv, fake: FakeUpstream) -> None:
    from tests.ai.support import chat_body, make_conversation, run_chat  # noqa: PLC0415

    fake.models_reply = error_reply(500)
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    sse = await run_chat(phone, chat_body(conversation, model="any/model"))
    assert sse.last[0] == "done"  # unknown model, unknown prices: the provider decides
    assert sse.last[1]["cost_kopecks"] == 0


def test_parse_model_variants() -> None:
    assert parse_model({"name": "no id"}) is None
    assert parse_model({"id": ""}) is None
    assert parse_model({"id": "x" * 201}) is None
    assert parse_model({"id": "a", "type": "embedding"}) is None
    assert parse_model({"id": "a", "type": "chat"}) is not None
    assert parse_model({"id": "a", "architecture": {"output_modalities": ["image"]}}) is None
    nested = parse_model(
        {"id": "a", "top_provider": {"max_completion_tokens": 4096}, "supports_tools": True}
    )
    assert nested is not None and nested.max_completion_tokens == 4096 and nested.supports_tools
    assert nested.name == "a"
    odd = parse_model({"id": "a", "context_length": "8000", "max_completion_tokens": 12.5})
    assert odd is not None and odd.context_length == 8000 and odd.max_completion_tokens is None


async def test_catalog_unit_behaviour() -> None:
    class Source:
        def __init__(self) -> None:
            self.calls = 0
            self.fail = False

        async def get_models(self) -> list[dict[str, Any]]:
            self.calls += 1
            if self.fail:
                raise UpstreamError("upstream_error", "down", retryable=True)
            return [{"id": "m1"}] if self.calls == 1 else [{"id": "m1"}, {"id": "m2"}]

    source = Source()
    clock = {"t": 0.0}
    catalog = ModelCatalog(
        source,  # type: ignore[arg-type]
        100,
        now=lambda: datetime(2026, 10, 1, tzinfo=UTC),
        monotonic=lambda: clock["t"],
    )
    info, known = await catalog.find("m1")
    assert info is not None and known
    # an unknown model within a minute of the fetch: no refetch
    assert await catalog.find("m2") == (None, True) and source.calls == 1
    clock["t"] = 61  # older than a minute: a new model may have appeared
    info, _ = await catalog.find("m2")
    assert info is not None and source.calls == 2
    source.fail = True
    clock["t"] = 500
    stale = await catalog.get()
    assert stale.stale and "m2" in stale.models
    empty = ModelCatalog(source, 100)  # type: ignore[arg-type]
    assert await empty.find("m1") == (None, False)  # nothing known: the caller must not refuse
