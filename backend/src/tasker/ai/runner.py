"""One chat answer: the model/tool loop, the event stream, spend accounting and persistence.

``ChatRun.run`` is an independent task (not tied to the HTTP request): the SSE generator only
reads its queue. When the client goes away the generator cancels the run; the run catches the
cancellation, closes the provider connection, settles the spend and saves the partial answer as
``cancelled`` (spec stage3, 5.6).
"""

import asyncio
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any
from zoneinfo import ZoneInfo

import structlog
from sqlalchemy.exc import SQLAlchemyError

from tasker.ai import pricing, spend
from tasker.ai.catalog import ModelInfo
from tasker.ai.chat import ChatInput
from tasker.ai.runtime import AiRuntime
from tasker.ai.serverwrite import WriteOp, write_rows
from tasker.ai.tables import PROPOSAL_ARGUMENTS_BYTES, ai_messages, ai_tool_proposals
from tasker.ai.tools import TOOLS, ToolArgumentError, ToolContext, ToolSpec, clip_result
from tasker.ai.upstream import UpstreamError
from tasker.ids import uuid7
from tasker.runtime import Runtime
from tasker.sync.registry import json_size_bytes
from tasker.textcheck import require_storable_json

log = structlog.get_logger("ai.runner")
MAX_TEXT = 390_000
MAX_PARTS_JSON = 900_000  # UTF-8 bytes (``json_size_bytes``), below the column limit
PREVIEW_CHARS = 200
OMITTED = "[omitted: too large]"
BIG_ARGUMENTS_BYTES = 500


class LoopFailure(Exception):  # noqa: N818 - control flow, carries an event code
    def __init__(self, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.retryable = retryable


@dataclass(slots=True)
class Event:
    name: str
    data: dict[str, Any]


@dataclass(slots=True)
class _Call:
    """The model call in flight: what has arrived so far (for spend on cancel or error)."""

    prompt_chars: int
    usage: dict[str, Any] | None = None
    completion_chars: int = 0
    received: bool = False


@dataclass(slots=True)
class _Iteration:
    text: str
    tool_calls: list[dict[str, Any]]
    finish_reason: str | None


@dataclass(slots=True)
class _Proposal:
    proposal_id: uuid.UUID
    entity_id: uuid.UUID
    tool_call_id: str
    spec: ToolSpec
    arguments: dict[str, Any]


@dataclass(slots=True)
class _State:
    parts: list[dict[str, Any]] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)
    current: list[str] = field(default_factory=list)
    proposals: list[_Proposal] = field(default_factory=list)
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cost_kopecks: int = 0
    finish_reason: str | None = None


def storable(value: Any) -> Any:
    """``value`` without what PostgreSQL cannot store: NUL characters and lone surrogates."""
    if isinstance(value, str):
        return value.replace("\x00", "").encode("utf-8", "replace").decode("utf-8")
    if isinstance(value, list):
        return [storable(item) for item in value]
    if isinstance(value, dict):
        return {storable(key): storable(item) for key, item in value.items()}
    return value


def fit_parts(parts: list[dict[str, Any]], limit: int = MAX_PARTS_JSON) -> list[dict[str, Any]]:
    """``parts`` shrunk until their size by the column's own measure (``json_size_bytes``) fits.

    Order of sacrifice: tool results, then bulky tool-call arguments, then the longest texts. The
    answer is always saved, whatever the language (Cyrillic costs 2 bytes a letter, not 1).
    """
    if json_size_bytes(parts) <= limit:
        return parts
    fitted = [dict(part) for part in parts]
    for part in fitted:
        if part["type"] == "tool_result":
            part["content"] = OMITTED
        elif part["type"] == "tool_call":
            if json_size_bytes(part.get("arguments")) > BIG_ARGUMENTS_BYTES:
                part["arguments"] = {"omitted": "too large"}
            if isinstance(part.get("raw_arguments"), str):
                part["raw_arguments"] = part["raw_arguments"][:200]
    while json_size_bytes(fitted) > limit:
        texts = [part for part in fitted if part["type"] == "text" and part["text"]]
        if not texts:  # pragma: no cover - 400 parts of bounded size cannot reach the limit
            break
        longest = max(texts, key=lambda part: len(part["text"]))
        longest["text"] = longest["text"][: len(longest["text"]) // 2]
    return fitted


def _int_field(usage: dict[str, Any], *names: str) -> int | None:
    for name in names:
        value = pricing.to_decimal(usage.get(name))
        if value is not None and value == value.to_integral_value():
            return int(value)
    return None


class ChatRun:
    def __init__(self, rt: Runtime, ai: AiRuntime, chat: ChatInput) -> None:
        self.rt = rt
        self.ai = ai
        self.chat = chat
        self.message_id = chat.request.assistant_message_id
        self.queue: asyncio.Queue[Event | None] = asyncio.Queue()
        self.task: asyncio.Task[None] | None = None
        self._state = _State()
        self._call: _Call | None = None
        self._cancelling = False
        self._started = time.perf_counter()
        self._created_at = rt.clock.now()
        info: ModelInfo | None = chat.model
        self._prices = info.prices if info is not None else pricing.Prices()
        tools_known_unsupported = info is not None and not info.supports_tools
        self.tools_enabled = bool(chat.tool_names) and not tools_known_unsupported

    # ------------------------------------------------------------------ lifecycle

    def start(self) -> asyncio.Task[None]:
        if self.task is None:
            self.ai.runs[self.message_id] = self
            self.task = self.ai.spawn(self.run())
        return self.task

    def cancel(self) -> bool:
        """Ask the running answer to stop; asking again changes nothing (still ``True``)."""
        if self.task is None or self.task.done():
            return False
        if not self._cancelling:
            self._cancelling = True
            self.task.cancel()
        return True

    def _emit(self, event: str, /, **data: Any) -> None:
        self.queue.put_nowait(Event(event, data))

    async def run(self) -> None:
        status, code, message, retryable = "done", None, "", False
        try:
            self._emit(
                "start",
                message_id=str(self.message_id),
                model=self.chat.request.model,
                agent_id=None if self.chat.agent_id is None else str(self.chat.agent_id),
                prompt_version=self.chat.prompt_version,
                tools_enabled=self.tools_enabled,
            )
            await self._loop()
        except asyncio.CancelledError:
            status = "cancelled"
        except UpstreamError as error:
            status, code, message, retryable = "error", error.code, error.message, error.retryable
        except LoopFailure as failure:
            status, code = "error", failure.code
            message, retryable = failure.message, failure.retryable
        except Exception as exc:  # the run must always end with an event and a saved message
            log.error("chat_run_failed", error_type=type(exc).__name__, exc_info=True)
            status, code, message, retryable = "error", "internal_error", "Internal error", True
        try:
            # Its own task: a further cancellation (the client closing the connection after an
            # explicit cancel, shutdown) must not skip the spend and the saved message.
            finishing = self.ai.spawn(self._finish(status, code, message, retryable))
            while not finishing.done():
                try:
                    await asyncio.shield(finishing)
                except asyncio.CancelledError:
                    continue
        finally:
            self.ai.runs.pop(self.message_id, None)
            self.ai.release(self.message_id)
            self.queue.put_nowait(None)

    async def _finish(self, status: str, code: str | None, message: str, retryable: bool) -> None:
        saved = False
        try:
            await self._settle_call()
            await self._persist(status, code)
            saved = True
        except Exception as exc:  # whatever went wrong, the client gets an event
            log.error("chat_persist_failed", error_type=type(exc).__name__)
            status, code, message, retryable = (
                "error",
                "persist_failed",
                "The answer could not be saved",
                True,
            )
        state = self._state
        if status == "error":
            self._emit(
                "error",
                code=code,
                message=message,
                retryable=retryable,
                message_id=str(self.message_id) if saved else None,
            )
        elif status == "done":
            self._emit(
                "done",
                message_id=str(self.message_id),
                status="done",
                finish_reason=state.finish_reason,
                prompt_tokens=state.prompt_tokens,
                completion_tokens=state.completion_tokens,
                cost_kopecks=state.cost_kopecks,
            )

    # ------------------------------------------------------------------ the loop

    def _payload(self, messages: list[dict[str, Any]], *, last: bool) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.chat.request.model,
            "messages": messages,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
        params = self.chat.request.params
        if params.temperature is not None:
            payload["temperature"] = params.temperature
        if params.max_tokens is not None:
            payload["max_tokens"] = params.max_tokens
        if self.tools_enabled:
            specs = [spec for name in self.chat.tool_names if (spec := TOOLS.get(name))]
            payload["tools"] = [spec.upstream() for spec in specs]
            payload["tool_choice"] = "none" if last else "auto"
        return payload

    async def _loop(self) -> None:
        limit = self.rt.settings.ai_max_tool_iterations
        messages: list[dict[str, Any]] = []
        if self.chat.system_text:
            messages.append({"role": "system", "content": self.chat.system_text})
        messages.extend(message.upstream() for message in self.chat.request.messages)
        state = self._state
        for iteration in range(1, limit + 1):
            if iteration > 1:
                await self._check_limit()
            last = iteration == limit
            result = await self._call_model(self._payload(messages, last=last))
            state.finish_reason = result.finish_reason
            if result.text:
                state.parts.append({"type": "text", "text": result.text})
                state.texts.append(result.text)
            if not result.tool_calls:
                state.finish_reason = result.finish_reason or "stop"
                return
            if not self.tools_enabled or last:
                raise LoopFailure("tool_loop_limit", "The model kept calling tools")
            messages.append(
                {
                    "role": "assistant",
                    "content": result.text or None,
                    "tool_calls": [
                        {
                            "id": call["id"],
                            "type": "function",
                            "function": {"name": call["name"], "arguments": call["arguments"]},
                        }
                        for call in result.tool_calls
                    ],
                }
            )
            made_proposal = False
            for call in result.tool_calls:
                content, proposal = await self._run_tool(call)
                made_proposal = made_proposal or proposal
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": content})
            if made_proposal:
                state.finish_reason = "awaiting_approval"
                return
        raise LoopFailure("tool_loop_limit", "The model kept calling tools")  # pragma: no cover

    async def _check_limit(self) -> None:
        zone = ZoneInfo(self.rt.settings.ai_billing_timezone)
        async with self.rt.sessionmaker() as session, session.begin():
            exceeded = await spend.check_limit(
                session,
                self.rt.clock.now(),
                zone,
                reserved=self.ai.reserved_by_others(self.message_id),
            )
        if exceeded is not None:
            raise LoopFailure("limit_exceeded", "The monthly AI spending limit is reached")

    # ------------------------------------------------------------------ one model call

    async def _call_model(self, payload: dict[str, Any]) -> _Iteration:
        call = self._call = _Call(
            prompt_chars=len(json.dumps(payload["messages"], ensure_ascii=False))
        )
        accumulated: dict[int, dict[str, str]] = {}
        finish: str | None = None
        current = self._state.current = []
        async for chunk in self.ai.upstream.stream_chat(payload):
            call.received = True
            usage = chunk.get("usage")
            if isinstance(usage, dict):
                call.usage = usage
            choices = chunk.get("choices")
            for choice in choices if isinstance(choices, list) else []:
                if not isinstance(choice, dict):
                    continue
                delta = choice.get("delta")
                delta = delta if isinstance(delta, dict) else {}
                content = delta.get("content")
                if isinstance(content, str) and content:
                    current.append(content)
                    call.completion_chars += len(content)
                    self._emit("delta", text=content)
                for position, fragment in enumerate(delta.get("tool_calls") or []):
                    if isinstance(fragment, dict):
                        self._add_tool_fragment(accumulated, fragment, position, call)
                reason = choice.get("finish_reason")
                if isinstance(reason, str) and reason:
                    finish = reason
        if finish is None:
            raise UpstreamError(
                "upstream_error", "The provider stream ended unexpectedly", retryable=True
            )
        await self.ai.shielded(self._settle_call)
        text = "".join(current)
        current.clear()
        calls = [accumulated[index] for index in sorted(accumulated)]
        tool_calls = [
            {
                "id": call_data["id"] or f"call_{uuid.uuid4().hex[:24]}",
                "name": call_data["name"],
                "arguments": call_data["arguments"],
            }
            for call_data in calls
            if call_data["name"]
        ]
        return _Iteration(text, tool_calls, finish)

    @staticmethod
    def _add_tool_fragment(
        accumulated: dict[int, dict[str, str]], fragment: dict[str, Any], position: int, call: _Call
    ) -> None:
        index = fragment.get("index")
        key = index if isinstance(index, int) and not isinstance(index, bool) else position
        entry = accumulated.setdefault(key, {"id": "", "name": "", "arguments": ""})
        if isinstance(fragment.get("id"), str) and fragment["id"]:
            entry["id"] = fragment["id"][:128]
        function = fragment.get("function")
        if isinstance(function, dict):
            name = function.get("name")
            if isinstance(name, str) and name and not entry["name"]:
                entry["name"] = name[:64]
            arguments = function.get("arguments")
            if isinstance(arguments, str):
                entry["arguments"] += arguments
                call.completion_chars += len(arguments)

    # ------------------------------------------------------------------ spend

    async def _settle_call(self) -> None:
        """Write the spend row of the call in flight (if it cost anything) exactly once."""
        call, self._call = self._call, None
        if call is None or not (call.received or call.usage):
            return  # nothing arrived: a failed request is not billed
        usage = call.usage or {}
        prompt = _int_field(usage, "prompt_tokens", "input_tokens")
        completion = _int_field(usage, "completion_tokens", "output_tokens")
        estimated = prompt is None and completion is None and not usage
        if prompt is None:
            prompt = pricing.estimate_tokens(call.prompt_chars)
        if completion is None:
            completion = pricing.estimate_tokens(call.completion_chars)
        cost = pricing.reported_cost_kopecks(usage)
        if not cost:  # not reported, or a reported 0 for a call that did use tokens
            cost = pricing.computed_cost_kopecks(prompt, completion, self._prices)
        state = self._state
        state.prompt_tokens += prompt
        state.completion_tokens += completion
        state.cost_kopecks += cost
        self._emit(
            "usage",
            prompt_tokens=state.prompt_tokens,
            completion_tokens=state.completion_tokens,
            cost_kopecks=state.cost_kopecks,
        )
        try:
            async with self.rt.sessionmaker() as session, session.begin():
                await spend.record(
                    session,
                    now=self.rt.clock.now(),
                    message_id=self.message_id,
                    model=self.chat.request.model,
                    prompt_tokens=prompt,
                    completion_tokens=completion,
                    cost_kopecks=cost,
                    estimated=estimated,
                )
        except (SQLAlchemyError, OSError) as exc:
            log.error("ai_spend_not_recorded", error_type=type(exc).__name__)

    # ------------------------------------------------------------------ tools

    async def _run_tool(self, call: dict[str, Any]) -> tuple[str, bool]:
        """Execute one tool call. Returns ``(result text for the model, proposal created?)``."""
        state = self._state
        call_id, name = call["id"], call["name"]
        arguments: Any = None
        part: dict[str, Any] = {"type": "tool_call", "id": call_id, "name": name}
        try:
            arguments = json.loads(call["arguments"] or "{}")
            require_storable_json(arguments)  # NUL or a lone surrogate cannot be stored
        except ValueError:
            part["arguments"] = None
            part["raw_arguments"] = call["arguments"][:2000]
        else:
            part["arguments"] = arguments
        state.parts.append(part)
        self._emit("tool_call", id=call_id, name=name, arguments=part["arguments"])

        spec = TOOLS.get(name) if name in self.chat.tool_names else None
        if spec is None:
            return self._tool_error(call_id, name, f"unknown tool {name!r}"), False
        if part["arguments"] is None:
            return self._tool_error(call_id, name, "arguments are not valid JSON"), False
        try:
            parsed = spec.parse(arguments)
        except ToolArgumentError as error:
            return self._tool_error(call_id, name, f"invalid arguments: {error}"), False
        if spec.kind == "write":
            return self._propose(call_id, spec, parsed.model_dump(mode="json", exclude_none=True))
        assert spec.handler is not None  # noqa: S101 - checked at registration
        try:
            content = clip_result(
                await spec.handler(ToolContext(self.rt.sessionmaker, self.chat.zone), parsed)
            )
        except Exception as exc:  # a failing tool costs the step, not the answer
            log.error("tool_failed", tool=name, error_type=type(exc).__name__)
            return self._tool_error(call_id, name, "the tool failed, try again later"), False
        self._tool_result(call_id, name, content, is_error=False)
        return content, False

    def _tool_error(self, call_id: str, name: str, message: str) -> str:
        content = json.dumps({"error": message}, ensure_ascii=False)
        self._tool_result(call_id, name, content, is_error=True)
        return content

    def _tool_result(self, call_id: str, name: str, content: str, *, is_error: bool) -> None:
        self._state.parts.append(
            {
                "type": "tool_result",
                "tool_call_id": call_id,
                "name": name,
                "content": content,
                "is_error": is_error,
            }
        )
        self._emit(
            "tool_result",
            tool_call_id=call_id,
            name=name,
            is_error=is_error,
            preview=content[:PREVIEW_CHARS],
        )

    def _propose(self, call_id: str, spec: ToolSpec, arguments: dict[str, Any]) -> tuple[str, bool]:
        """``(result for the model, proposal created?)``; arguments too large to store: an error."""
        if json_size_bytes(arguments) > PROPOSAL_ARGUMENTS_BYTES:
            return self._tool_error(call_id, spec.name, "invalid arguments: too large"), False
        proposal = _Proposal(
            proposal_id=uuid7(),
            entity_id=uuid7(),
            tool_call_id=call_id,
            spec=spec,
            arguments=arguments,
        )
        self._state.proposals.append(proposal)
        self._state.parts.append(
            {
                "type": "proposal",
                "proposal_id": str(proposal.proposal_id),
                "tool_call_id": call_id,
                "tool": spec.name,
            }
        )
        self._emit(
            "proposal",
            proposal_id=str(proposal.proposal_id),
            tool_call_id=call_id,
            tool=spec.name,
            entity_type=spec.entity_type,
            entity_id=str(proposal.entity_id),
            arguments=proposal.arguments,
        )
        result = {
            "status": "proposed",
            "proposal_id": str(proposal.proposal_id),
            "note": "The user must approve it; nothing is created yet.",
        }
        return json.dumps(result), True

    # ------------------------------------------------------------------ persistence

    def _flush_partial(self) -> None:
        state = self._state
        if state.current:  # an interrupted model call: keep the text received so far
            text = "".join(state.current)
            state.current.clear()
            state.parts.append({"type": "text", "text": text})
            state.texts.append(text)

    async def _persist(self, status: str, error_code: str | None) -> None:
        self._flush_partial()
        state = self._state
        text = storable("\n\n".join(state.texts)[:MAX_TEXT])
        for part in state.parts:
            if part["type"] == "text" and len(part["text"]) > MAX_TEXT:
                part["text"] = part["text"][:MAX_TEXT]
        parts = fit_parts(storable(state.parts))
        chat = self.chat
        fields: dict[str, Any] = {
            "conversation_id": str(chat.request.conversation_id),
            "role": "assistant",
            "text": text,
            "parts": parts,
            "status": status,
            "model": chat.request.model,
            "agent_id": None if chat.agent_id is None else str(chat.agent_id),
            "prompt_version": chat.prompt_version,
            "prompt_tokens": state.prompt_tokens,
            "completion_tokens": state.completion_tokens,
            "cost_kopecks": state.cost_kopecks,
            "latency_ms": int((time.perf_counter() - self._started) * 1000),
            "finish_reason": state.finish_reason,
            "error_code": error_code,
        }
        ops = [WriteOp(ai_messages, self.message_id, fields, created_at=self._created_at)]
        for proposal in state.proposals:
            ops.append(
                WriteOp(
                    ai_tool_proposals,
                    proposal.proposal_id,
                    {
                        "message_id": str(self.message_id),
                        "tool_call_id": proposal.tool_call_id,
                        "tool": proposal.spec.name,
                        "entity_type": proposal.spec.entity_type,
                        "entity_id": str(proposal.entity_id),
                        "original_arguments": proposal.arguments,
                        "arguments": proposal.arguments,
                        "status": "pending",
                    },
                    created_at=self._created_at,
                )
            )
        async with self.rt.sessionmaker() as session:
            await write_rows(session, self.rt.registry, ops, self.rt.clock.now())
