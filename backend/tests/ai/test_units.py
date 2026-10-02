"""Pure units: error mapping, SSE decoding, the tool registry, context providers."""

import json
from datetime import UTC, date, datetime
from zoneinfo import ZoneInfo

import pytest
from pydantic import BaseModel

from tasker.ai import builtin, context
from tasker.ai.tools import (
    MAX_TOOL_RESULT_CHARS,
    TOOLS,
    ToolArgumentError,
    ToolRegistry,
    ToolSpec,
    clip_result,
)
from tasker.ai.tools_events import GetEventsArgs
from tasker.ai.tools_tasks import CreateTaskArgs, GetTasksArgs, _like
from tasker.ai.upstream import UpstreamError, _decode_line, error_for_status

assert builtin  # the built-in tools are registered by importing it


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (402, "upstream_payment_required", False),
        (404, "model_not_found", False),
        (429, "upstream_rate_limited", True),
        (408, "upstream_timeout", True),
        (504, "upstream_timeout", True),
        (500, "upstream_error", True),
        (599, "upstream_error", True),
        (400, "upstream_rejected", False),
        (403, "upstream_rejected", False),
    ],
)
def test_status_mapping(status: int, code: str, retryable: bool) -> None:
    error = error_for_status(status, 2.0)
    assert (error.code, error.retryable, error.status) == (code, retryable, status)
    assert "key" not in error.message.lower()


def test_decode_line() -> None:
    assert _decode_line("") is None and _decode_line(": ping") is None
    assert _decode_line("event: x") is None and _decode_line("id: 1") is None
    assert _decode_line("data: [DONE]") == "done" and _decode_line("data:[DONE]") == "done"
    assert _decode_line('data: {"a": 1}') == {"a": 1}
    assert _decode_line('data:{"choices": [], "error": 1}') == {"choices": [], "error": 1}
    for bad in ("data: nope", "data: [1]", 'data: {"error": {}}', "data: 5"):
        with pytest.raises(UpstreamError):
            _decode_line(bad)


def test_the_registry_has_the_builtin_tools() -> None:
    assert sorted(TOOLS.names()) == [
        "create_task",
        "get_accounts",
        "get_debts",
        "get_events",
        "get_finance_summary",
        "get_goals",
        "get_projects",
        "get_receivables",
        "get_tasks",
        "get_work_hours",
    ]
    assert {s.name: s.kind for s in TOOLS.all()} == {
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
    assert TOOLS.get("nothing") is None
    spec = TOOLS.get("get_tasks")
    assert spec is not None and spec.upstream()["function"]["name"] == "get_tasks"
    assert spec.public()["parameters"]["type"] == "object"


def test_registering_tools() -> None:
    registry = ToolRegistry()

    class Args(BaseModel):
        n: int

    async def handler(_ctx: object, _args: BaseModel) -> str:
        return "{}"

    read = ToolSpec("t", "d", {"type": "object"}, Args, "read", handler=handler)
    registry.register(read)
    with pytest.raises(ValueError, match="already registered"):
        registry.register(read)
    with pytest.raises(ValueError, match="needs a handler"):
        ToolSpec("r", "d", {}, Args, "read")
    with pytest.raises(ValueError, match="needs an entity_type"):
        ToolSpec("w", "d", {}, Args, "write")
    assert registry.names() == ["t"]
    with pytest.raises(ToolArgumentError, match="JSON object"):
        read.parse([1])
    with pytest.raises(ToolArgumentError, match="n"):
        read.parse({"n": "x"})
    assert read.parse({"n": 1}) == Args(n=1)


def test_argument_errors_do_not_echo_values() -> None:
    spec = TOOLS.get("create_task")
    assert spec is not None
    with pytest.raises(ToolArgumentError) as caught:
        spec.parse({"title": "ok", "priority": "SECRET-VALUE"})
    assert "SECRET-VALUE" not in str(caught.value) and "priority" in str(caught.value)


@pytest.mark.parametrize(
    "args",
    [
        {"title": ""},
        {"title": "x" * 501},
        {"title": "x", "priority": 0},
        {"title": "x", "priority": True},
        {"title": "x", "due_date": "2026-13-01"},
        {"title": "x", "due_date": "26-1-1"},
        {"title": "x", "due_time": "10:00"},
        {"title": "x", "due_date": "2026-10-01", "due_time": "24:00"},
        {"title": "x", "due_date": "2026-10-01", "due_time": "9:00"},
        {"title": "x", "duration_minutes": 1441},
        {"title": "x", "tags": ["a"] * 6},
        {"title": "x", "tags": ["has space"]},
        {"title": "x", "tags": ["#hash"]},
        {"title": "x", "project": "p" * 201},
    ],
)
def test_create_task_rejects(args: dict[str, object]) -> None:
    with pytest.raises(ToolArgumentError):
        TOOLS.get("create_task").parse(args)  # type: ignore[union-attr]


def test_create_task_normalises() -> None:
    parsed = CreateTaskArgs.model_validate(
        {"title": " Позвонить ", "due_date": "2026-10-09", "due_time": "09:05", "extra": 1}
    )
    assert parsed.normalised() == {
        "title": " Позвонить ",
        "due_date": "2026-10-09",
        "due_time": "09:05",
    }


@pytest.mark.parametrize(
    "args",
    [
        {"limit": 0},
        {"limit": 101},
        {"status": ["lost"]},
        {"priority_min": 6},
        {"due_from": "2026-02-30"},
        {"due_to": "soon"},
    ],
)
def test_get_tasks_rejects(args: dict[str, object]) -> None:
    with pytest.raises(ValueError):  # noqa: PT011
        GetTasksArgs.model_validate(args)


def test_get_events_range_rules() -> None:
    assert GetEventsArgs(from_date="2026-10-01", to_date="2026-10-01").limit == 50
    for args in (
        {"from_date": "2026-10-02", "to_date": "2026-10-01"},
        {"from_date": "2026-10-01", "to_date": "2026-12-31"},
        {"from_date": "2026-02-30", "to_date": "2026-03-01"},
        {"from_date": "2026-10-01"},
    ):
        with pytest.raises(ValueError):  # noqa: PT011
            GetEventsArgs.model_validate(args)


def test_like_escapes_wildcards() -> None:
    assert _like("50%_off\\") == "%50\\%\\_off\\\\%"


def test_results_are_clipped_and_marked() -> None:
    assert clip_result("short") == "short"
    clipped = clip_result("x" * (MAX_TOOL_RESULT_CHARS + 50))
    assert len(clipped) == MAX_TOOL_RESULT_CHARS and clipped.endswith("[truncated]")


# ------------------------------------------------------------------ context providers


def test_now_block_and_week_parity() -> None:
    now = datetime(2026, 10, 1, 12, 0, tzinfo=UTC)
    moscow = ZoneInfo("Europe/Moscow")
    cycle = {"length": 2, "week1_start": "2026-09-28"}
    text = context.render(context.ContextRequest(now, moscow, cycle))
    assert "2026-10-01 15:00 (четверг), часовой пояс Europe/Moscow." in text
    assert "Текущая неделя: Нечётная." in text
    later = context.render(
        context.ContextRequest(datetime(2026, 10, 6, 12, tzinfo=UTC), moscow, cycle)
    )
    assert "Чётная" in later
    assert "Текущая неделя" not in context.render(context.ContextRequest(now, moscow, None))
    # the evening in UTC is already the next day in Vladivostok
    far = context.render(
        context.ContextRequest(
            datetime(2026, 10, 1, 20, 0, tzinfo=UTC), ZoneInfo("Asia/Vladivostok"), None
        )
    )
    assert "2026-10-02 06:00 (пятница)" in far


@pytest.mark.parametrize(
    ("setting", "expected"),
    [
        (None, None),
        ("nope", None),
        ({"length": 1, "week1_start": "2026-09-28"}, None),
        ({"length": 9, "week1_start": "2026-09-28"}, None),
        ({"length": True, "week1_start": "2026-09-28"}, None),
        ({"length": 2, "week1_start": "garbage"}, None),
        ({"length": 2}, None),
        ({"length": 3, "week1_start": "2026-09-28"}, "Неделя 1"),
        ({"length": 2, "week1_start": "2026-09-28", "labels": ["А", "Б"]}, "А"),
        ({"length": 2, "week1_start": "2026-09-28", "labels": ["А"]}, "Нечётная"),
        ({"length": 2, "week1_start": "2026-09-28", "labels": ["А", ""]}, "Нечётная"),
        (
            {
                "length": 2,
                "week1_start": "2026-09-28",
                "shifts": [{"from": "2026-09-28", "weeks": 1}, "bad", {"from": 5}],
            },
            "Чётная",
        ),
    ],
)
def test_week_label(setting: object, expected: str | None) -> None:
    assert context.week_label(date(2026, 10, 1), setting) == expected  # type: ignore[arg-type]


def test_providers_can_be_added() -> None:
    before = list(context.CONTEXT_PROVIDERS)
    try:
        context.register_context_provider(lambda _request: "Доп. блок")
        context.register_context_provider(lambda _request: None)
        text = context.render(
            context.ContextRequest(datetime(2026, 10, 1, tzinfo=UTC), ZoneInfo("UTC"), None)
        )
        assert text.endswith("\n\nДоп. блок")
    finally:
        context.CONTEXT_PROVIDERS[:] = before


def test_upstream_error_carries_only_safe_fields() -> None:
    error = UpstreamError("upstream_error", "The provider failed", retryable=True, status=500)
    assert json.dumps({"code": error.code, "message": error.message})
