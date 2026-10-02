"""Tool registry. Stages 4-8 add their tools here (see spec stage3, 6.1).

A tool is a ``ToolSpec``: a name, a JSON Schema for the model, a pydantic model that validates
(and normalises) the arguments, and either a handler (``kind="read"``: runs on the server, the
result goes back to the model) or an ``entity_type`` (``kind="write"``: the call becomes a
proposal the user approves; the client creates the entity).
"""

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Literal
from zoneinfo import ZoneInfo

from pydantic import BaseModel, ValidationError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

MAX_TOOL_RESULT_CHARS = 20_000
_CUT = "…[truncated]"


class ToolArgumentError(ValueError):
    """The model sent arguments that do not fit the tool's schema."""


@dataclass(frozen=True, slots=True)
class ToolContext:
    sessionmaker: async_sessionmaker[AsyncSession]
    timezone: ZoneInfo


ToolHandler = Callable[[ToolContext, BaseModel], Awaitable[str]]


@dataclass(frozen=True, slots=True)
class ToolSpec:
    name: str
    description: str
    parameters: dict[str, Any]
    args_model: type[BaseModel]
    kind: Literal["read", "write"]
    handler: ToolHandler | None = None
    entity_type: str | None = None

    def __post_init__(self) -> None:
        if self.kind == "read" and self.handler is None:
            raise ValueError(f"read tool {self.name!r} needs a handler")
        if self.kind == "write" and self.entity_type is None:
            raise ValueError(f"write tool {self.name!r} needs an entity_type")

    def parse(self, raw: object) -> BaseModel:
        """Validate model-made arguments; ``ToolArgumentError`` names the problems, not values."""
        if not isinstance(raw, dict):
            raise ToolArgumentError("arguments must be a JSON object")
        try:
            return self.args_model.model_validate(raw)
        except ValidationError as exc:
            problems = "; ".join(
                f"{'.'.join(str(part) for part in err['loc']) or 'arguments'}: {err['msg']}"
                for err in exc.errors()
            )
            raise ToolArgumentError(problems[:500]) from exc

    def public(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "kind": self.kind,
            "description": self.description,
            "parameters": self.parameters,
        }

    def upstream(self) -> dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, ToolSpec] = {}

    def register(self, spec: ToolSpec) -> ToolSpec:
        if spec.name in self._tools:
            raise ValueError(f"tool {spec.name!r} is already registered")
        self._tools[spec.name] = spec
        return spec

    def get(self, name: str) -> ToolSpec | None:
        return self._tools.get(name)

    def names(self) -> list[str]:
        return list(self._tools)

    def all(self) -> list[ToolSpec]:
        return list(self._tools.values())


TOOLS = ToolRegistry()


def clip_result(text: str) -> str:
    """Tool results are bounded; the cut is marked so the model knows."""
    if len(text) <= MAX_TOOL_RESULT_CHARS:
        return text
    return text[: MAX_TOOL_RESULT_CHARS - len(_CUT)] + _CUT
