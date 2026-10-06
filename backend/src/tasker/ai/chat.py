"""``POST /ai/chat/completions``: the request, its pre-flight checks and the system message."""

import uuid
from dataclasses import dataclass
from typing import Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator

from tasker.ai import agents, context, pricing, spend
from tasker.ai.catalog import ModelInfo
from tasker.ai.runtime import AiRuntime
from tasker.ai.tables import ai_agent_profiles, ai_context_presets, ai_conversations, ai_messages
from tasker.ai.tools import TOOLS
from tasker.errors import ApiError
from tasker.ids import is_uuid7
from tasker.runtime import Runtime
from tasker.sync.user_settings import user_settings

MAX_MESSAGES = 400
MAX_CONTENT = 100_000
MAX_CONTEXT = 200_000
DEFAULT_MAX_COMPLETION_TOKENS = 8192  # the reserve of a call when nothing else bounds the answer
WEEK_CYCLE_KEY = "calendar.week_cycle"


class ToolCallFunction(BaseModel):
    model_config = ConfigDict(extra="ignore")

    name: str = Field(min_length=1, max_length=64)
    arguments: str = Field(max_length=200_000)


class ToolCallIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(min_length=1, max_length=128)
    type: Literal["function"] = "function"
    function: ToolCallFunction


class MessageIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    role: Literal["user", "assistant", "tool"]
    content: str | None = Field(default=None, max_length=MAX_CONTENT)
    tool_calls: list[ToolCallIn] | None = Field(default=None, max_length=32)
    tool_call_id: str | None = Field(default=None, min_length=1, max_length=128)

    @model_validator(mode="after")
    def _shape(self) -> "MessageIn":
        if self.role == "assistant":
            if self.content is None and not self.tool_calls:
                raise ValueError("an assistant message needs content or tool_calls")
        elif self.content is None:
            raise ValueError("content is required")
        if self.role == "tool" and self.tool_call_id is None:
            raise ValueError("a tool message needs tool_call_id")
        if self.role != "assistant" and self.tool_calls:
            raise ValueError("only assistant messages carry tool_calls")
        return self

    def upstream(self) -> dict[str, Any]:
        return self.model_dump(exclude_none=True)


class ContextIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    text: str = Field(default="", max_length=MAX_CONTEXT)
    preset_id: uuid.UUID | None = None
    contains_sensitive: StrictBool = False


class ParamsIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    temperature: float | None = Field(default=None, ge=0, le=2)
    max_tokens: int | None = Field(default=None, ge=1, le=32768)


class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    conversation_id: uuid.UUID
    assistant_message_id: uuid.UUID
    model: str = Field(min_length=1, max_length=200)
    agent_id: uuid.UUID | None = None
    context: ContextIn = Field(default_factory=ContextIn)
    messages: list[MessageIn] = Field(min_length=1, max_length=MAX_MESSAGES)
    tools: list[str] | None = Field(default=None, max_length=64)
    sensitive_tools_consent: StrictBool = False
    timezone: str = "UTC"
    params: ParamsIn = Field(default_factory=ParamsIn)

    @field_validator("assistant_message_id")
    @classmethod
    def _uuid7(cls, value: uuid.UUID) -> uuid.UUID:
        if not is_uuid7(value):
            raise ValueError("assistant_message_id must be a UUIDv7")
        return value

    @field_validator("timezone")
    @classmethod
    def _zone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError, OSError) as exc:
            raise ValueError("timezone must be an IANA time zone") from exc
        return value


@dataclass(slots=True)
class ChatInput:
    """Everything the runner needs; built by :func:`prepare` after the pre-flight checks."""

    request: ChatRequest
    zone: ZoneInfo
    system_text: str
    agent_id: uuid.UUID | None
    prompt_version: int | None
    tool_names: list[str]
    model: ModelInfo | None  # ``None``: the catalog could not be loaded


async def _exists(session: Any, table: sa.Table, row_id: uuid.UUID) -> bool:
    found = await session.execute(
        sa.select(table.c.id).where(table.c.id == row_id, table.c.deleted_at.is_(None))
    )
    return found.first() is not None


async def prepare(rt: Runtime, ai: AiRuntime, request: ChatRequest) -> ChatInput:
    """The pre-flight checks of spec 5.2 (in their documented order) and the claim on the id.

    The id of the answer is claimed before the first ``await``: two requests with the same
    ``assistant_message_id`` arriving at once cannot both pass. The claim (with the money reserved
    for the answer) lives until the run ends, or until this function fails.
    """
    if not ai.upstream.configured:
        raise ApiError(503, "ai_not_configured", "The AI provider is not configured")
    message_id = request.assistant_message_id
    if not ai.claim(message_id):
        raise ApiError(
            409,
            "message_exists",
            "A message with this id already exists",
            details={"status": "running"},
        )
    try:
        return await _prepare(rt, ai, request)
    except BaseException:
        ai.release(message_id)
        raise


def _prompt_chars(request: ChatRequest, system_prompt: str | None) -> int:
    """About how long the prompt is (characters): the same for every request of a chat."""
    total = len(system_prompt or "") + len(request.context.text) + 1000
    for message in request.messages:
        total += len(message.content or "")
        total += sum(len(call.function.arguments) for call in message.tool_calls or [])
    return total


async def _prepare(rt: Runtime, ai: AiRuntime, request: ChatRequest) -> ChatInput:
    now = rt.clock.now()
    zone = ZoneInfo(request.timezone)

    sensitive = request.context.contains_sensitive
    async with rt.sessionmaker() as session:
        await agents.ensure_seeded(session, rt.registry, now)
        async with session.begin():
            if request.context.preset_id is not None and not sensitive:
                preset = (
                    await session.execute(
                        sa.select(ai_context_presets.table.c.sensitive).where(
                            ai_context_presets.table.c.id == request.context.preset_id,
                            ai_context_presets.table.c.deleted_at.is_(None),
                        )
                    )
                ).scalar_one_or_none()
                sensitive = bool(preset)
            if sensitive:
                raise ApiError(
                    403,
                    "sensitive_context_forbidden",
                    "This context is marked as not to be sent to the cloud",
                )
            if not await _exists(session, ai_conversations.table, request.conversation_id):
                raise ApiError(
                    404,
                    "conversation_not_found",
                    "The conversation is not on the server yet: synchronise first",
                )
            system_prompt, prompt_version, profile_tools = await _agent(session, request.agent_id)
            week_cycle = await _week_cycle(session)
    names = _tool_names(request.tools, profile_tools)
    withheld = False
    if not request.sensitive_tools_consent:  # Finance data goes to the cloud only with consent
        allowed = [name for name in names if not _is_sensitive(name)]
        withheld = len(allowed) != len(names)
        names = allowed

    info, known = await ai.catalog.find(request.model)
    if known and info is None:
        raise ApiError(404, "model_not_found", "The model is not in the provider catalog")

    prices = info.prices if info is not None else pricing.Prices()
    max_completion = (
        request.params.max_tokens
        or (info.max_completion_tokens if info is not None else None)
        or DEFAULT_MAX_COMPLETION_TOKENS
    )
    # From here on the answer holds back what one call may cost; it is set before the ledger is
    # read, so of two parallel requests the later one always sees the earlier one.
    ai.reserve(
        request.assistant_message_id,
        pricing.call_reserve_kopecks(_prompt_chars(request, system_prompt), max_completion, prices),
    )

    async with rt.sessionmaker() as session:
        async with session.begin():
            if await _exists_any(session, request.assistant_message_id):
                raise ApiError(
                    409,
                    "message_exists",
                    "A message with this id already exists",
                    details={
                        "status": await _message_status(session, request.assistant_message_id)
                    },
                )
            limit, exceeded = await spend.limit_status(
                session,
                now,
                ZoneInfo(rt.settings.ai_billing_timezone),
                ai.reserved_by_others(request.assistant_message_id),
            )
        if exceeded is not None:
            details: dict[str, Any] = {
                "limit_kopecks": exceeded.limit_kopecks,
                "spent_kopecks": exceeded.spent_kopecks,
                "month": exceeded.month,
            }
            if exceeded.reserved_kopecks:
                details["reserved_kopecks"] = exceeded.reserved_kopecks
            raise ApiError(
                402, "limit_exceeded", "The monthly AI spending limit is reached", details=details
            )
        if limit is not None and not prices.known:
            raise ApiError(
                422,
                "price_unknown",
                "The price of the model is unknown, so the spending limit cannot be kept",
                details={"model": request.model[:200], "catalog_available": known},
            )

    parts = [
        system_prompt,
        context.render(context.ContextRequest(now, zone, week_cycle)),
        agents.SENSITIVE_WITHHELD_NOTE if withheld else None,
        request.context.text.strip() or None,
    ]
    return ChatInput(
        request=request,
        zone=zone,
        system_text="\n\n".join(part for part in parts if part),
        agent_id=request.agent_id,
        prompt_version=prompt_version,
        tool_names=names,
        model=info,
    )


async def _agent(session: Any, agent_id: uuid.UUID | None) -> tuple[str | None, int | None, Any]:
    if agent_id is None:
        return None, None, None
    table = ai_agent_profiles.table
    row = (
        await session.execute(
            sa.select(
                table.c.system_prompt,
                table.c.prompt_version,
                table.c.enabled_tools,
                table.c.seed_key,
            ).where(table.c.id == agent_id, table.c.deleted_at.is_(None))
        )
    ).first()
    if row is None:
        raise ApiError(404, "agent_not_found", "The agent profile is not on the server")
    tools = row.enabled_tools
    if row.seed_key in agents.SEED_BY_KEY:  # built-in: the tool list comes from code
        tools = agents.builtin_tools(row.seed_key)
    return row.system_prompt, int(row.prompt_version), tools


async def _week_cycle(session: Any) -> Any:
    table = user_settings.table
    return (
        await session.execute(
            sa.select(table.c.value).where(
                table.c.key == WEEK_CYCLE_KEY, table.c.deleted_at.is_(None)
            )
        )
    ).scalar_one_or_none()


def _tool_names(requested: list[str] | None, profile_tools: Any) -> list[str]:
    if requested is not None:
        unknown = sorted(name for name in requested if TOOLS.get(name) is None)
        if unknown:
            raise ApiError(422, "unknown_tool", "Unknown tool", details={"tools": unknown[:10]})
        return list(dict.fromkeys(requested))
    if isinstance(profile_tools, list):
        return [name for name in dict.fromkeys(profile_tools) if TOOLS.get(str(name)) is not None]
    return TOOLS.names()


def _is_sensitive(name: str) -> bool:
    spec = TOOLS.get(name)
    return spec is not None and spec.sensitive


async def _exists_any(session: Any, message_id: uuid.UUID) -> bool:
    found = await session.execute(
        sa.select(ai_messages.table.c.id).where(ai_messages.table.c.id == message_id)
    )
    return found.first() is not None


async def _message_status(session: Any, message_id: uuid.UUID) -> str:
    status = (
        await session.execute(
            sa.select(ai_messages.table.c.status).where(ai_messages.table.c.id == message_id)
        )
    ).scalar_one_or_none()
    return str(status) if status is not None else "running"
