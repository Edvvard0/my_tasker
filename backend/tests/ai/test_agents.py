"""Seeded agents, prompt versions, reset, and the validation of the AI sync tables."""

import uuid
from typing import Any

from tasker.ai import agents, ids
from tasker.ai.ids import SERVER_DEVICE_ID
from tasker.ids import uuid7
from tests.ai.support import AiEnv, make_conversation
from tests.api_support import DeviceClient


async def rows_of(device: DeviceClient, table: str) -> list[dict[str, Any]]:
    return [c["row"] for c in await device.pull_all() if c["table"] == table]


def profile_op(device: DeviceClient, row: dict[str, Any], **fields: Any) -> dict[str, Any]:
    return device.op(
        "ai_agent_profiles", uuid.UUID(row["id"]), fields=fields, base=row["server_version"]
    )


async def test_bootstrap_seeds_six_agents_once(aienv: AiEnv) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    assert await rows_of(phone, "ai_agent_profiles") == []  # nothing until asked

    first = (await phone.post("/ai/bootstrap")).json()

    keys = [a["seed_key"] for a in first["agents"]]
    assert keys == ["general", "calendar_tasks", "work", "finance", "study", "sleep"]
    assert [a["name"] for a in first["agents"]] == [
        "Общий", "Календарь и задачи", "Работа", "Финансы", "Учёба", "Сон"
    ]  # fmt: skip
    assert first["seed_prompt_version"] == 1
    assert {t["name"]: t["kind"] for t in first["tools"]} == {
        "get_tasks": "read",
        "get_events": "read",
        "create_task": "write",
        "get_projects": "read",
        "get_receivables": "read",
        "get_work_hours": "read",
        "get_accounts": "read",
        "get_finance_summary": "read",
        "get_goals": "read",
        "get_debts": "read",
    }
    create = [t for t in first["tools"] if t["name"] == "create_task"][0]
    assert create["parameters"]["required"] == ["title"]
    for agent in first["agents"]:
        assert agent["id"] == str(ids.profile_id(agent["seed_key"]))

    again = (await pc.post("/ai/bootstrap")).json()
    assert again == first
    for device in (phone, pc):  # every device receives the same rows by pull
        profiles = await rows_of(device, "ai_agent_profiles")
        versions = await rows_of(device, "ai_prompt_versions")
        assert len(profiles) == 6 and len(versions) == 6
        general = [p for p in profiles if p["seed_key"] == "general"][0]
        assert general["prompt_version"] == 1 and general["origin_device_id"] == str(
            SERVER_DEVICE_ID
        )
        assert general["enabled_tools"] == ["get_tasks", "get_events", "create_task"]
        work = [p for p in profiles if p["seed_key"] == "work"][0]
        assert work["enabled_tools"] == [
            "get_tasks",
            "get_events",
            "create_task",
            "get_projects",
            "get_receivables",
            "get_work_hours",
        ]
        finance = [p for p in profiles if p["seed_key"] == "finance"][0]
        assert finance["enabled_tools"] == [
            "get_tasks",
            "get_events",
            "create_task",
            "get_accounts",
            "get_finance_summary",
            "get_goals",
            "get_debts",
        ]
        assert general["system_prompt"] == agents.SEED_BY_KEY["general"].prompt
        version = [v for v in versions if v["profile_id"] == general["id"]][0]
        assert (version["version"], version["source"]) == (1, "seed")
        assert version["id"] == str(ids.prompt_version_id(general["id"], 1))
    assert await aienv.env.scalar("SELECT count(*) FROM ai_agent_profiles") == 6


async def test_seeding_does_not_resurrect_what_the_user_removed(aienv: AiEnv) -> None:
    phone = await aienv.device()
    await phone.post("/ai/bootstrap")
    sleep = [p for p in await rows_of(phone, "ai_agent_profiles") if p["seed_key"] == "sleep"][0]
    await phone.push_ok(
        [
            phone.op(
                "ai_agent_profiles", uuid.UUID(sleep["id"]), "delete", base=sleep["server_version"]
            )
        ]
    )
    names = [a["seed_key"] for a in (await phone.post("/ai/bootstrap")).json()["agents"]]
    assert "sleep" not in names and len(names) == 5


async def test_the_user_edits_a_prompt_and_reset_restores_the_default(aienv: AiEnv) -> None:
    phone, pc = await aienv.device("Phone"), await aienv.device("PC")
    await phone.post("/ai/bootstrap")
    work = [p for p in await rows_of(phone, "ai_agent_profiles") if p["seed_key"] == "work"][0]
    profile_id = uuid.UUID(work["id"])

    # the client edits: a new version row and the profile, in one batch
    edit = await phone.push_ok(
        [
            phone.op(
                "ai_prompt_versions",
                ids.prompt_version_id(profile_id, 2),
                fields={
                    "profile_id": work["id"],
                    "version": 2,
                    "text": "Мой промт",
                    "source": "user",
                    "created_at": phone.created(),
                },
            ),
            profile_op(phone, work, system_prompt="Мой промт", prompt_version=2),
        ]
    )
    assert [r["status"] for r in edit] == ["applied", "applied"]

    reset = await pc.post("/ai/agents/work/reset")

    assert reset.status_code == 200
    changes = reset.json()["changes"]
    assert [c["table"] for c in changes] == ["ai_agent_profiles", "ai_prompt_versions"]
    profile, version = changes[0]["row"], changes[1]["row"]
    assert profile["system_prompt"] == agents.SEED_BY_KEY["work"].prompt
    assert profile["prompt_version"] == 3 and profile["origin_device_id"] == str(SERVER_DEVICE_ID)
    assert (version["version"], version["source"], version["text"]) == (
        3,
        "reset",
        profile["system_prompt"],
    )
    # the reset wins over the earlier edit on the phone as well, and the history keeps all three
    on_phone = await rows_of(phone, "ai_agent_profiles")
    assert [p["system_prompt"] for p in on_phone if p["seed_key"] == "work"] == [
        profile["system_prompt"]
    ]
    texts = {
        v["version"]: v["text"]
        for v in await rows_of(phone, "ai_prompt_versions")
        if v["profile_id"] == work["id"]
    }
    assert texts[1] == agents.SEED_BY_KEY["work"].prompt and texts[2] == "Мой промт"
    assert texts[3] == agents.SEED_BY_KEY["work"].prompt
    # an edit made after the reset (newer clock, saw the reset) is accepted again
    phone.hlc.receive(profile["updated_at"], aienv.env.clock.ms)
    again = await phone.push_ok(
        [profile_op(phone, profile, system_prompt="Снова мой", prompt_version=4)]
    )
    assert again[0]["status"] == "applied"


async def test_reset_restores_a_deleted_profile_and_rejects_unknown_keys(aienv: AiEnv) -> None:
    phone = await aienv.device()
    await phone.post("/ai/bootstrap")
    study = [p for p in await rows_of(phone, "ai_agent_profiles") if p["seed_key"] == "study"][0]
    await phone.push_ok(
        [
            phone.op(
                "ai_agent_profiles", uuid.UUID(study["id"]), "delete", base=study["server_version"]
            )
        ]
    )
    assert (await phone.post("/ai/agents/study/reset")).status_code == 200
    study_now = [p for p in await rows_of(phone, "ai_agent_profiles") if p["seed_key"] == "study"][
        0
    ]
    assert study_now["deleted_at"] is None and study_now["prompt_version"] == 2
    missing = await phone.post("/ai/agents/astrology/reset")
    assert (missing.status_code, missing.json()["error"]["code"]) == (404, "agent_not_found")


async def test_reset_before_bootstrap_seeds_first(aienv: AiEnv) -> None:
    phone = await aienv.device()
    assert (await phone.post("/ai/agents/general/reset")).status_code == 200
    assert await aienv.env.scalar("SELECT count(*) FROM ai_agent_profiles") == 6
    assert (
        await aienv.env.scalar(
            "SELECT prompt_version FROM ai_agent_profiles WHERE seed_key = 'general'"
        )
        == 2
    )


async def test_profile_validation(aienv: AiEnv) -> None:
    phone = await aienv.device()
    await phone.post("/ai/bootstrap")
    base = {
        "name": "Мой агент",
        "topic": "custom",
        "system_prompt": "Ты помощник",
        "prompt_version": 1,
        "enabled_tools": ["get_tasks"],
        "position": 7,
        "created_at": phone.created(),
    }

    def create(row_id: uuid.UUID, **over: Any) -> dict[str, Any]:
        return phone.op("ai_agent_profiles", row_id, fields={**base, **over})

    results = await phone.push_ok(
        [
            create(uuid7()),  # a custom agent
            create(uuid7(), name="   "),
            create(uuid7(), system_prompt=" "),
            create(uuid7(), system_prompt="x" * 20001),
            create(uuid7(), enabled_tools="get_tasks"),
            create(uuid7(), enabled_tools=[1]),
            create(uuid7(), enabled_tools=["t"] * 33),
            create(uuid7(), topic="cooking"),
            create(uuid7(), prompt_version=0),
            create(uuid7(), seed_key="general"),  # a seeded key needs the deterministic id
            create(
                ids.profile_id("general"), seed_key="general"
            ),  # ... which already exists: a merge
            create(ids.profile_id("sleep"), seed_key="unknown"),
            create(uuid.uuid4()),  # not a UUIDv7
        ]
    )
    assert [r["status"] for r in results[:2]] == ["applied", "rejected"]
    assert [r["code"] for r in results[1:]] == [
        "validation_failed", "validation_failed", "invalid_field", "validation_failed",
        "validation_failed", "validation_failed", "invalid_field", "invalid_field",
        "invalid_id",  # a seeded key needs the deterministic id
        None,  # the deterministic id of an existing profile: an ordinary merge
        "immutable_field",  # the seed key of a profile never changes
        "invalid_id",  # not a UUIDv7
    ]  # fmt: skip


async def test_version_favourite_preset_and_conversation_rules(aienv: AiEnv) -> None:
    phone = await aienv.device()
    await phone.post("/ai/bootstrap")
    general = ids.profile_id("general")
    favorite = ids.favorite_id("openai/gpt-4o")
    ghost = uuid7()

    def op(table: str, row_id: uuid.UUID, **fields: Any) -> dict[str, Any]:
        return phone.op(table, row_id, fields={"created_at": phone.created(), **fields})

    results = await phone.push_ok(
        [
            op("ai_prompt_versions", uuid7(), profile_id=str(general), version=9, text="t", source="user"),
            op("ai_prompt_versions", ids.prompt_version_id(general, 9), profile_id=str(general), version=9, text="  ", source="user"),
            op("ai_prompt_versions", ids.prompt_version_id(general, 9), profile_id=str(general), version=9, text="ok", source="vandal"),
            op("ai_prompt_versions", ids.prompt_version_id(ghost, 9), profile_id=str(ghost), version=9, text="ok", source="user"),
            op("ai_model_favorites", uuid7(), model_id="openai/gpt-4o", display_name="GPT", position=0, supports_tools=True),
            op("ai_model_favorites", favorite, model_id="openai/gpt-4o", display_name="GPT-4o", position=0, supports_tools=True),
            op("ai_context_presets", uuid7(), name="P", sources=[{"source": "tasks"}], sensitive=False),
            op("ai_context_presets", uuid7(), name="P", sources=["tasks"], sensitive=False),
            op("ai_context_presets", uuid7(), name="  ", sources=[], sensitive=False),
            op("ai_context_presets", uuid7(), name="P", sources=[{}] * 33, sensitive=True),
            op("ai_conversations", uuid7(), title="", topic="general", pinned=False, archived=False, mode="cloud"),
            op("ai_conversations", uuid7(), title="x" * 201, topic="general", pinned=False, archived=False, mode="cloud"),
            op("ai_conversations", uuid7(), title="", topic="general", pinned=False, archived=False, mode="telepathy"),
        ]
    )  # fmt: skip
    assert [r["code"] for r in results] == [
        "invalid_id", "validation_failed", "invalid_field", "parent_not_found",
        "invalid_id", None, None, "validation_failed", "validation_failed",
        "validation_failed", None, "invalid_field", "invalid_field",
    ]  # fmt: skip


async def test_message_rules_and_immutability(aienv: AiEnv) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    message = uuid7()

    def fields(**over: Any) -> dict[str, Any]:
        return {
            "conversation_id": str(conversation),
            "role": "user",
            "text": "Привет",
            "parts": [{"type": "text", "text": "Привет"}],
            "status": "done",
            "created_at": phone.created(),
            **over,
        }

    results = await phone.push_ok(
        [
            phone.op("ai_messages", message, fields=fields()),
            phone.op("ai_messages", uuid7(), fields=fields(parts="text")),
            phone.op("ai_messages", uuid7(), fields=fields(parts=[{"type": "video"}])),
            phone.op("ai_messages", uuid7(), fields=fields(parts=[{"type": "text", "text": 5}])),
            phone.op(
                "ai_messages", uuid7(), fields=fields(parts=[{"type": "text", "text": "x"}] * 401)
            ),
            phone.op("ai_messages", uuid7(), fields=fields(role="wizard")),
            phone.op("ai_messages", uuid7(), fields=fields(status="exploded")),
            phone.op("ai_messages", uuid7(), fields=fields(cost_kopecks=-1)),
            phone.op("ai_messages", uuid7(), fields=fields(conversation_id=str(uuid7()))),
            phone.op("ai_messages", message, fields={"role": "assistant"}, base=1),
            phone.op("ai_messages", message, fields={"conversation_id": str(uuid7())}, base=1),
            phone.op("ai_messages", message, fields={"text": "Исправлено"}, base=1),
        ]
    )
    assert [r["code"] for r in results] == [
        None, "validation_failed", "validation_failed", "validation_failed",
        "validation_failed", "invalid_field", "invalid_field", "invalid_field",
        "parent_not_found", "immutable_field", "immutable_field", None,
    ]  # fmt: skip
