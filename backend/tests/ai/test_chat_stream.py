"""Text streaming, persistence as synced rows, and the pre-flight errors."""

import json
import uuid

from tasker.ai import agents
from tasker.ids import uuid7
from tasker.sync.user_settings import settings_id
from tests.ai.fake_upstream import FakeUpstream, text_reply
from tests.ai.support import KEY, AiEnv, Sse, chat_body, make_ai_env, make_conversation, run_chat


async def test_text_stream_is_relayed_and_saved(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device("Phone")
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["Привет", ", мир"], prompt=100, completion=20))
    body = chat_body(conversation)

    sse = await run_chat(phone, body)

    assert sse.status == 200
    assert sse.names() == ["start", "delta", "delta", "usage", "done"]
    assert "".join(d["text"] for d in sse.of("delta")) == "Привет, мир"
    assert sse.of("start")[0]["message_id"] == body["assistant_message_id"]
    done = sse.of("done")[0]
    assert done["status"] == "done" and done["finish_reason"] == "stop"
    # gpt-4o in the fake catalog: 250 / 1000 rubles per 1M tokens -> 100*250/1e6 + 20*1000/1e6
    # = 0.025 + 0.02 = 0.045 RUB -> rounded up to 5 kopecks
    assert (done["prompt_tokens"], done["completion_tokens"], done["cost_kopecks"]) == (100, 20, 5)

    await aienv.settle()
    changes = await phone.pull_all()
    messages = [c["row"] for c in changes if c["table"] == "ai_messages"]
    assert len(messages) == 1
    row = messages[0]
    assert row["id"] == body["assistant_message_id"]
    assert (row["role"], row["status"], row["text"]) == ("assistant", "done", "Привет, мир")
    assert row["parts"] == [{"type": "text", "text": "Привет, мир"}]
    assert row["cost_kopecks"] == 5 and row["model"] == "openai/gpt-4o"
    assert row["conversation_id"] == str(conversation)
    assert row["origin_device_id"] == "00000000-0000-7000-8000-000000000a11"


async def test_system_message_and_provider_request(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    boot = await phone.post("/ai/bootstrap")
    calendar_agent = next(a for a in boot.json()["agents"] if a["seed_key"] == "calendar_tasks")
    # a week cycle: 2026-10-01 is a Thursday of the week that starts on Monday 2026-09-28
    cycle = {"length": 2, "week1_start": "2026-09-28"}
    await phone.push_ok(
        [
            phone.op(
                "user_settings",
                settings_id("calendar.week_cycle"),
                fields={
                    "key": "calendar.week_cycle",
                    "value": cycle,
                    "created_at": phone.created(),
                },
            )
        ]
    )
    fake.queue(text_reply(["ok"]))
    body = chat_body(
        conversation,
        agent_id=calendar_agent["id"],
        context={"text": "Контекст: три задачи", "contains_sensitive": False},
        params={"temperature": 0.3, "max_tokens": 500},
    )

    sse = await run_chat(phone, body)

    assert sse.last[0] == "done"
    sent = fake.chat_requests[0]
    assert sent.headers["authorization"] == f"Bearer {KEY}"
    payload = sent.json
    assert payload["model"] == "openai/gpt-4o" and payload["stream"] is True
    assert payload["stream_options"] == {"include_usage": True}
    assert (payload["temperature"], payload["max_tokens"]) == (0.3, 500)
    system = payload["messages"][0]
    assert system["role"] == "system"
    assert agents.SEED_BY_KEY["calendar_tasks"].prompt in system["content"]
    assert "2026-10-01 15:00" in system["content"] and "четверг" in system["content"]
    assert "Europe/Moscow" in system["content"] and "Нечётная" in system["content"]
    assert system["content"].endswith("Контекст: три задачи")
    assert payload["messages"][1] == {"role": "user", "content": "Привет"}
    assert [t["function"]["name"] for t in payload["tools"]] == [
        "get_tasks",
        "get_events",
        "create_task",
    ]
    assert payload["tool_choice"] == "auto"
    start = sse.of("start")[0]
    assert (start["agent_id"], start["prompt_version"], start["tools_enabled"]) == (
        calendar_agent["id"],
        1,
        True,
    )
    await aienv.settle()
    rows = [c["row"] for c in await phone.pull_all() if c["table"] == "ai_messages"]
    assert rows[0]["agent_id"] == calendar_agent["id"] and rows[0]["prompt_version"] == 1


async def test_a_model_without_tool_support_gets_no_tools(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    sse = await run_chat(phone, chat_body(conversation, model="vendor/plain-model"))
    assert sse.of("start")[0]["tools_enabled"] is False
    assert "tools" not in fake.chat_requests[0].json


async def test_preflight_errors(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)

    def code(sse: Sse) -> str:
        return str(json.loads(sse.text)["error"]["code"])

    sse = await run_chat(phone, chat_body(uuid.uuid4()))
    assert (sse.status, code(sse)) == (404, "conversation_not_found")
    sse = await run_chat(phone, chat_body(conversation, agent_id=str(uuid.uuid4())))
    assert (sse.status, code(sse)) == (404, "agent_not_found")
    sse = await run_chat(phone, chat_body(conversation, tools=["get_tasks", "rm_rf"]))
    assert (sse.status, code(sse)) == (422, "unknown_tool")
    sse = await run_chat(phone, chat_body(conversation, model="nobody/nothing"))
    assert (sse.status, code(sse)) == (404, "model_not_found")
    sse = await run_chat(phone, chat_body(conversation, messages=[]))
    assert (sse.status, code(sse)) == (422, "validation_error")
    sse = await run_chat(phone, chat_body(conversation, assistant_message_id=str(uuid.uuid4())))
    assert (sse.status, code(sse)) == (422, "validation_error")  # not a UUIDv7
    sse = await run_chat(phone, chat_body(conversation, timezone="Mars/Base"))
    assert (sse.status, code(sse)) == (422, "validation_error")
    bad_tool = [{"role": "tool", "content": "x"}]
    sse = await run_chat(phone, chat_body(conversation, messages=bad_tool))
    assert (sse.status, code(sse)) == (422, "validation_error")
    assert fake.chat_requests == []  # nothing reached the provider

    first = chat_body(conversation)
    assert (await run_chat(phone, first)).last[0] == "done"
    await aienv.settle()
    again = await run_chat(phone, first)
    assert (again.status, code(again)) == (409, "message_exists")
    unauthenticated = await aienv.client.post("/ai/chat/completions", json=first)
    assert unauthenticated.status_code in (401, 400)


async def test_not_configured_without_a_key(migrated_db_url: str, fake: FakeUpstream) -> None:
    async with make_ai_env(migrated_db_url, fake, polza_api_key=None) as env:
        phone = await env.device()
        conversation = await make_conversation(phone)
        sse = await run_chat(phone, chat_body(conversation))
        assert sse.status == 503 and '"ai_not_configured"' in sse.text


async def test_sensitive_context_is_refused(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    flagged = await run_chat(
        phone, chat_body(conversation, context={"text": "secret", "contains_sensitive": True})
    )
    assert flagged.status == 403 and '"sensitive_context_forbidden"' in flagged.text

    preset_id, calm_id = uuid7(), uuid7()
    base = {"name": "Финансы", "sources": [], "created_at": phone.created()}
    await phone.push_ok(
        [
            phone.op("ai_context_presets", preset_id, fields={**base, "sensitive": True}),
            phone.op("ai_context_presets", calm_id, fields={**base, "sensitive": False}),
        ]
    )
    by_preset = await run_chat(
        phone, chat_body(conversation, context={"preset_id": str(preset_id)})
    )
    assert by_preset.status == 403
    assert (
        await run_chat(phone, chat_body(conversation, context={"preset_id": str(calm_id)}))
    ).status == 200
    assert len(fake.chat_requests) == 1


async def test_every_device_is_told_about_the_saved_answer(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    import asyncio  # noqa: PLC0415

    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    conversation = await make_conversation(phone)
    head = (await phone.pull_ok())["head_version"]
    fake.queue(text_reply(["привет"]))

    async with aienv.client.stream("GET", "/events", headers=phone.headers) as events:
        lines = events.aiter_lines()

        async def until(name: str) -> None:
            async for line in lines:
                if line == f"event: {name}":
                    return

        await asyncio.wait_for(until("hello"), 10)
        # the phone asks, and still hears about the server-authored row (not "its own" commit)
        assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"
        await asyncio.wait_for(until("changes"), 10)
        await asyncio.sleep(0.5)  # let the server finish its queries before the stream is closed
    pulled = await pc.pull_ok(head)
    tables = {c["table"] for c in pulled["changes"]}
    assert tables == {"ai_messages", "ai_agent_profiles", "ai_prompt_versions"}  # seeded lazily


async def test_endpoints_need_auth_and_the_schema_header(aienv: AiEnv) -> None:
    for method, path in (
        ("POST", "/ai/bootstrap"),
        ("GET", "/ai/models"),
        ("GET", "/ai/usage"),
        ("POST", "/ai/agents/general/reset"),
        ("POST", f"/ai/chat/{uuid.uuid4()}/cancel"),
    ):
        anonymous = await aienv.client.request(
            method, path, headers={"X-Client-Schema-Version": "1"}
        )
        assert anonymous.status_code == 401, path
        phone = await aienv.device()
        no_schema = await aienv.client.request(
            method, path, headers={"Authorization": phone.headers["Authorization"]}
        )
        assert no_schema.status_code == 400, path
        assert json.loads(no_schema.text)["error"]["code"] == "schema_version_required"


async def test_profile_tools_decide_and_unknown_future_tools_are_skipped(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await phone.post("/ai/bootstrap")
    custom = uuid7()
    await phone.push_ok(
        [
            phone.op(
                "ai_agent_profiles",
                custom,
                fields={
                    "name": "Мой",
                    "topic": "work",
                    "system_prompt": "Ты помощник.",
                    "prompt_version": 1,
                    "enabled_tools": ["get_events", "add_expense", "get_events"],
                    "position": 9,
                    "created_at": phone.created(),
                },
            )
        ]
    )
    agent = {"id": str(custom)}

    await run_chat(phone, chat_body(conversation, agent_id=agent["id"]))
    assert [t["function"]["name"] for t in fake.chat_requests[0].json["tools"]] == ["get_events"]

    sse = await run_chat(phone, chat_body(conversation, agent_id=agent["id"], tools=[]))
    assert sse.of("start")[0]["tools_enabled"] is False
    assert "tools" not in fake.chat_requests[1].json


async def test_builtin_profiles_take_their_tools_from_code_not_from_storage(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    boot = (await phone.post("/ai/bootstrap")).json()
    work = next(a for a in boot["agents"] if a["seed_key"] == "work")
    row = next(
        c["row"]
        for c in await phone.pull_all()
        if c["table"] == "ai_agent_profiles" and c["id"] == work["id"]
    )
    await phone.push_ok(
        [
            phone.op(
                "ai_agent_profiles",
                uuid.UUID(work["id"]),
                fields={"enabled_tools": ["get_events"]},  # a stale snapshot
                base=row["server_version"],
            )
        ]
    )
    await run_chat(phone, chat_body(conversation, agent_id=work["id"]))
    names = [t["function"]["name"] for t in fake.chat_requests[0].json["tools"]]
    assert names == [
        "get_tasks",
        "get_events",
        "create_task",
        "get_projects",
        "get_receivables",
        "get_work_hours",
    ]
