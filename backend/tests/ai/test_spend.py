"""Cost in kopecks, the spend ledger, the monthly limit and the usage summary."""

import asyncio
import json
from datetime import UTC, datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

import pytest

from tasker.ai import pricing, spend
from tasker.sync.user_settings import settings_id
from tests.ai.fake_upstream import (
    MODELS,
    FakeUpstream,
    Reply,
    error_reply,
    sleep,
    text_reply,
    tool_reply,
)
from tests.ai.support import AiEnv, chat_body, make_conversation, run_chat
from tests.api_support import DeviceClient

MOSCOW = ZoneInfo("Europe/Moscow")


async def set_setting(device: DeviceClient, key: str, value: object) -> None:
    op = device.op(
        "user_settings",
        settings_id(key),
        fields={"key": key, "value": value, "created_at": device.created()},
    )
    results = await device.push_ok([op])
    assert results[0]["status"] == "applied"


# ------------------------------------------------------------------ pure arithmetic


@pytest.mark.parametrize(
    ("usage", "expected"),
    [
        ({"cost": 0.1234}, 13),  # rounded up: the ledger never undercharges
        ({"cost": "0.125"}, 13),
        ({"cost": "0.001"}, 1),  # a call cheaper than half a kopeck is not free
        ({"cost": "0.12"}, 12),
        ({"cost_rub": 1}, 100),
        ({"total_cost": "2.5"}, 250),
        ({"cost": 0}, 0),
        ({"cost": -1}, None),
        ({"cost": True}, None),
        ({"cost": "abc"}, None),
        ({"cost": float("nan")}, None),
        ({"cost": float("inf")}, None),
        ({"cost": [1]}, None),
        ({"other": 1}, None),
        ({"cost": 10**30}, pricing.MAX_KOPECKS),
    ],
)
def test_cost_reported_by_the_provider(usage: dict[str, object], expected: int | None) -> None:
    assert pricing.reported_cost_kopecks(usage) == expected


@pytest.mark.parametrize(
    ("prompt", "completion", "price_in", "price_out", "expected"),
    [
        (100, 20, "250", "1000", 5),  # 0.045 rub -> 4.5 kop -> up
        (1_000_000, 500_000, "10", "20", 2000),
        (1, 0, "250", "1000", 1),  # never free once it has a price
        (0, 0, "250", "1000", 0),
        (1000, 1000, None, None, 0),  # no price: nothing to charge
        (1_000_000, 0, "0.5", None, 50),
    ],
)
def test_cost_by_catalog_prices(
    prompt: int, completion: int, price_in: str | None, price_out: str | None, expected: int
) -> None:
    prices = pricing.Prices(
        None if price_in is None else Decimal(price_in),
        None if price_out is None else Decimal(price_out),
    )
    assert pricing.computed_cost_kopecks(prompt, completion, prices) == expected


def test_no_float_rounding_in_kopecks() -> None:
    # 0.29 rub as a float is 0.28999999999999998: the Decimal reading keeps 29 kopecks
    assert pricing.reported_cost_kopecks({"cost": 0.29}) == 29
    assert pricing.reported_cost_kopecks({"cost": 1.15}) == 115
    assert pricing.estimate_tokens(0) == 0 and pricing.estimate_tokens(7) == 3


@pytest.mark.parametrize(
    ("model", "expected"),
    [
        ({"pricing": {"prompt": "250.00", "completion": "1000.00"}}, ("250.00", "1000.00")),
        ({"prices": {"input_per_1m": 10, "output_per_1m": 20}}, ("10", "20")),
        ({"input_price": 1.5, "output_price": 3}, ("1.5", "3")),
        ({"pricing": {"prompt": {"rub": "7"}, "completion": {"rub": 9}}}, ("7", "9")),
        ({"pricing": {"prompt": "1", "completion": "2", "input_cache_read": "9"}}, ("1", "2")),
        ({"max_completion_tokens": 16384, "context_length": 8000}, (None, None)),
        ({"pricing": {"prompt": "free"}}, (None, None)),
        ({}, (None, None)),
    ],
)
def test_prices_are_parsed_tolerantly(
    model: dict[str, object], expected: tuple[str | None, ...]
) -> None:
    parsed = pricing.parse_prices(model)
    as_text = tuple(None if p is None else str(p) for p in (parsed.input, parsed.output))
    assert as_text == expected


def test_display_prices_are_whole_kopecks() -> None:
    assert pricing.display_price_kopecks_per_mtok(Decimal("250.00")) == 25000
    assert pricing.display_price_kopecks_per_mtok(Decimal("0.005")) == 1
    assert pricing.display_price_kopecks_per_mtok(None) is None


def test_month_boundaries_follow_the_billing_time_zone() -> None:
    october = spend.month_of(datetime(2026, 9, 30, 21, 0, tzinfo=UTC), MOSCOW)  # 00:00 on the 1st
    assert october.label == "2026-10"
    assert october.start == datetime(2026, 9, 30, 21, 0, tzinfo=UTC)
    assert october.end == datetime(2026, 10, 31, 21, 0, tzinfo=UTC)
    assert spend.month_of(datetime(2026, 9, 30, 20, 59, tzinfo=UTC), MOSCOW).label == "2026-09"
    december = spend.parse_month("2026-12", MOSCOW)
    assert december.end == datetime(2026, 12, 31, 21, 0, tzinfo=UTC)


# ------------------------------------------------------------------ cost through the API


async def test_a_reported_cost_wins_over_the_catalog(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["a"], prompt=1_000_000, completion=1_000_000, cost=0.1234))
    sse = await run_chat(phone, chat_body(conversation))
    assert sse.of("done")[0]["cost_kopecks"] == 13
    assert await aienv.env.scalar("SELECT cost_kopecks FROM ai_spend") == 13


async def test_cost_from_catalog_prices_for_each_model(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["a"], prompt=1_000_000, completion=500_000))
    sse = await run_chat(phone, chat_body(conversation, model="vendor/plain-model"))
    assert sse.of("done")[0]["cost_kopecks"] == 2000
    fake.queue(text_reply(["a"], prompt=2_000_000, completion=1_000_000))
    sse = await run_chat(phone, chat_body(conversation, model="openai/gpt-4o"))
    assert sse.of("done")[0]["cost_kopecks"] == 150_000  # 2*250 + 1*1000 rubles


async def test_a_tool_loop_adds_up_every_call(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(
        tool_reply([("c1", "get_tasks", "{}")], cost=0.03),
        tool_reply([("c2", "get_tasks", "{}")], cost=0.04),
        text_reply(["итог"], cost=0.05),
    )
    sse = await run_chat(phone, chat_body(conversation))
    assert sse.of("done")[0]["cost_kopecks"] == 12
    assert [u["cost_kopecks"] for u in sse.of("usage")] == [3, 7, 12]  # cumulative
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 3
    assert await aienv.env.scalar("SELECT sum(cost_kopecks) FROM ai_spend") == 12


# ------------------------------------------------------------------ the limit


async def test_the_limit_blocks_before_anything_is_sent(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["a"], cost=0.12))
    assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"  # 12 kopecks spent
    await set_setting(phone, "ai.monthly_limit_kopecks", 12)
    fake.requests.clear()

    blocked = await run_chat(phone, chat_body(conversation))

    assert blocked.status == 402
    error = json.loads(blocked.text)["error"]
    assert error["code"] == "limit_exceeded"
    assert error["details"] == {"limit_kopecks": 12, "spent_kopecks": 12, "month": "2026-10"}
    assert fake.chat_requests == []  # nothing was sent to the provider
    assert await aienv.env.scalar("SELECT count(*) FROM ai_messages") == 1  # no message either

    await set_setting(phone, "ai.monthly_limit_kopecks", 13)  # raising the limit unblocks
    fake.queue(text_reply(["b"], cost=0.01))
    assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"


@pytest.mark.parametrize(
    ("value", "blocked"),
    [(0, True), ("100", False), (-5, False), (True, False), (1.5, False)],
)
async def test_limit_values(aienv: AiEnv, fake: FakeUpstream, value: object, blocked: bool) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await set_setting(phone, "ai.monthly_limit_kopecks", value)
    sse = await run_chat(phone, chat_body(conversation))
    assert (sse.status == 402) is blocked


async def test_no_limit_row_and_a_deleted_limit_mean_no_limit(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    assert (await run_chat(phone, chat_body(conversation))).status == 200
    await set_setting(phone, "ai.monthly_limit_kopecks", 0)
    assert (await run_chat(phone, chat_body(conversation))).status == 402
    await phone.push_ok(
        [phone.op("user_settings", settings_id("ai.monthly_limit_kopecks"), "delete", base=1)]
    )
    assert (await run_chat(phone, chat_body(conversation))).status == 200


async def test_the_limit_is_checked_between_tool_calls(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await set_setting(phone, "ai.monthly_limit_kopecks", 20)
    fake.queue(tool_reply([("c1", "get_tasks", "{}")], cost=0.25), text_reply(["не будет"]))

    sse = await run_chat(phone, chat_body(conversation))

    assert len(fake.chat_requests) == 1  # the second call was not made
    assert sse.last[0] == "error" and sse.last[1]["code"] == "limit_exceeded"
    await aienv.settle()
    assert await aienv.env.scalar("SELECT error_code FROM ai_messages") == "limit_exceeded"
    assert await aienv.env.scalar("SELECT cost_kopecks FROM ai_messages") == 25


async def test_last_month_does_not_count(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await aienv.env.execute(
        "INSERT INTO ai_spend VALUES (gen_random_uuid(), :at, gen_random_uuid(), 'm', 1, 1, 9999, false)",
        at=datetime(2026, 9, 30, 20, 59, tzinfo=UTC),  # 23:59 on 30 September in Moscow
    )
    await set_setting(phone, "ai.monthly_limit_kopecks", 100)
    assert (await run_chat(phone, chat_body(conversation))).status == 200
    await aienv.env.execute(
        "INSERT INTO ai_spend VALUES (gen_random_uuid(), :at, gen_random_uuid(), 'm', 1, 1, 100, false)",
        at=datetime(2026, 9, 30, 21, 0, tzinfo=UTC),  # 00:00 on 1 October
    )
    assert (await run_chat(phone, chat_body(conversation))).status == 402


# ------------------------------------------------------------------ the summary


async def test_usage_summary(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    empty = (await phone.get("/ai/usage")).json()
    assert empty == {
        "month": "2026-10",
        "limit_kopecks": None,
        "spent_kopecks": 0,
        "remaining_kopecks": None,
        "requests": 0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "by_model": [],
    }
    fake.queue(text_reply(["a"], prompt=100, completion=10, cost=0.50))
    fake.queue(text_reply(["b"], prompt=200, completion=20, cost=0.25))
    fake.queue(text_reply(["c"], prompt=5, completion=5, cost=0.03))
    await run_chat(phone, chat_body(conversation))
    await run_chat(phone, chat_body(conversation))
    await run_chat(phone, chat_body(conversation, model="vendor/plain-model"))
    await set_setting(phone, "ai.monthly_limit_kopecks", 50)

    summary = (await phone.get("/ai/usage")).json()

    assert summary["spent_kopecks"] == 78 and summary["limit_kopecks"] == 50
    assert summary["remaining_kopecks"] == 0  # never negative
    assert (summary["requests"], summary["prompt_tokens"], summary["completion_tokens"]) == (
        3,
        305,
        35,
    )
    assert summary["by_model"] == [
        {
            "model": "openai/gpt-4o",
            "requests": 2,
            "prompt_tokens": 300,
            "completion_tokens": 30,
            "cost_kopecks": 75,
        },
        {
            "model": "vendor/plain-model",
            "requests": 1,
            "prompt_tokens": 5,
            "completion_tokens": 5,
            "cost_kopecks": 3,
        },
    ]
    assert (await phone.get("/ai/usage", month="2026-09")).json()["spent_kopecks"] == 0
    for bad in ("2026-13", "2026-1", "october", "1969-12"):
        response = await phone.get("/ai/usage", month=bad)
        assert response.status_code == 422, bad


async def test_spend_survives_deleting_the_chat(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["a"], cost=0.40))
    await run_chat(phone, chat_body(conversation))
    await aienv.settle()
    await phone.push_ok([phone.op("ai_conversations", conversation, "delete", base=1)])
    assert (await phone.get("/ai/usage")).json()["spent_kopecks"] == 40


# ------------------------------------------------------------------ review fixes: accounting


async def test_cheap_calls_are_not_free(aienv: AiEnv, fake: FakeUpstream) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(*[text_reply(["a"], cost=0.001) for _ in range(3)])
    for _ in range(3):
        assert (await run_chat(phone, chat_body(conversation))).of("done")[0]["cost_kopecks"] == 1
    assert await aienv.env.scalar("SELECT sum(cost_kopecks) FROM ai_spend") == 3


async def test_a_reported_zero_cost_falls_back_to_the_catalog(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.queue(text_reply(["a"], prompt=1_000_000, completion=0, cost=0))
    sse = await run_chat(phone, chat_body(conversation))
    assert sse.of("done")[0]["cost_kopecks"] == 25_000  # 250 rubles per 1M prompt tokens
    fake.queue(text_reply(["a"], prompt=0, completion=0, cost=0))
    assert (await run_chat(phone, chat_body(conversation))).of("done")[0]["cost_kopecks"] == 0


async def test_a_cut_stream_in_cyrillic_is_estimated_by_characters(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    reply = text_reply(["я" * 300])
    reply.steps = [s for s in reply.steps if not (s.kind == "data" and s.payload["choices"] == [])]
    fake.queue(reply)
    content = "ж" * 32

    sse = await run_chat(
        phone, chat_body(conversation, messages=[{"role": "user", "content": content}])
    )

    sent = fake.chat_requests[0].json["messages"]
    characters = len(json.dumps(sent, ensure_ascii=False))
    assert sse.of("done")[0]["prompt_tokens"] == pricing.estimate_tokens(characters)
    assert sse.of("done")[0]["prompt_tokens"] < len(json.dumps(sent)) // 3  # not by escapes


# ------------------------------------------------------------------ review fixes: the limit


async def test_a_model_without_a_price_cannot_run_under_a_limit(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    priced = MODELS["data"][0]
    free = {"id": "vendor/free", "name": "No price", "context_length": 8000}
    fake.models_reply = Reply(body=json.dumps({"data": [priced, free]}))
    body = chat_body(conversation, model="vendor/free")
    fake.queue(text_reply(["без лимита можно"]))
    assert (await run_chat(phone, body)).last[0] == "done"  # no limit: nothing to protect

    await set_setting(phone, "ai.monthly_limit_kopecks", 100_000)
    fake.requests.clear()
    blocked = await run_chat(phone, chat_body(conversation, model="vendor/free"))

    assert blocked.status == 422
    error = json.loads(blocked.text)["error"]
    assert error["code"] == "price_unknown"
    assert error["details"] == {"model": "vendor/free", "catalog_available": True}
    assert fake.chat_requests == []
    assert aienv.ai.reserved == {}
    fake.queue(text_reply(["a"]))  # a model with a price works under the same limit
    assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"


async def test_an_unavailable_catalog_cannot_run_under_a_limit(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    fake.models_reply = error_reply(500)
    fake.queue(text_reply(["a"]))
    assert (await run_chat(phone, chat_body(conversation))).last[0] == "done"  # no limit
    await set_setting(phone, "ai.monthly_limit_kopecks", 100_000)

    blocked = await run_chat(phone, chat_body(conversation))

    assert blocked.status == 422
    error = json.loads(blocked.text)["error"]
    assert error["code"] == "price_unknown" and error["details"]["catalog_available"] is False


async def test_a_running_answer_holds_back_money_from_the_next_request(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await set_setting(phone, "ai.monthly_limit_kopecks", 100)
    # max_tokens 1000 at 1000 rubles per 1M tokens: one call may cost up to 100 kopecks
    first_body = chat_body(conversation, params={"max_tokens": 1000})
    slow = text_reply(["медленно"])
    slow.steps.insert(0, sleep(0.8))
    fake.queue(slow)
    first = asyncio.create_task(run_chat(phone, first_body))
    while not fake.chat_requests:
        await asyncio.sleep(0.02)

    blocked = await run_chat(phone, chat_body(conversation, params={"max_tokens": 1000}))

    assert blocked.status == 402
    details = json.loads(blocked.text)["error"]["details"]
    assert details["limit_kopecks"] == 100 and details["spent_kopecks"] == 0
    assert details["reserved_kopecks"] >= 100
    assert (await first).last[0] == "done"
    await aienv.settle()
    assert aienv.ai.reserved == {}  # the hold ended with the answer
    fake.queue(text_reply(["теперь можно"], cost=0.01))
    assert (await run_chat(phone, chat_body(conversation, params={"max_tokens": 1000}))).last[
        0
    ] == "done"


async def test_parallel_requests_cannot_all_pass_the_limit(
    aienv: AiEnv, fake: FakeUpstream
) -> None:
    phone = await aienv.device()
    conversation = await make_conversation(phone)
    await set_setting(phone, "ai.monthly_limit_kopecks", 100)
    replies = []
    for _ in range(3):
        reply = text_reply(["a"], cost=0.01)
        reply.steps.insert(0, sleep(0.5))
        replies.append(reply)
    fake.queue(*replies)

    results = await asyncio.gather(
        *[run_chat(phone, chat_body(conversation, params={"max_tokens": 1000})) for _ in range(3)]
    )

    assert sorted(r.status for r in results) == [200, 402, 402]
    await aienv.settle()
    assert await aienv.env.scalar("SELECT count(*) FROM ai_spend") == 1
