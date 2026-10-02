"""Model catalog: ``GET /models`` of the provider, normalised and cached with a TTL."""

import asyncio
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

import structlog

from tasker.ai import pricing
from tasker.ai.upstream import UpstreamClient, UpstreamError

log = structlog.get_logger("ai.catalog")
CHAT_TYPES = frozenset({"chat", "text", "llm", "chat.completions", "chat_completion"})
MAX_MODELS = 5000


@dataclass(frozen=True, slots=True)
class ModelInfo:
    id: str
    name: str
    context_length: int | None
    max_completion_tokens: int | None
    supports_tools: bool
    prices: pricing.Prices = field(default_factory=pricing.Prices)

    def public(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "context_length": self.context_length,
            "max_completion_tokens": self.max_completion_tokens,
            "supports_tools": self.supports_tools,
            "price_input_kopecks_per_mtok": pricing.display_price_kopecks_per_mtok(
                self.prices.input
            ),
            "price_output_kopecks_per_mtok": pricing.display_price_kopecks_per_mtok(
                self.prices.output
            ),
        }


def _positive_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        return None
    number = pricing.to_decimal(value)
    return None if number is None or number != number.to_integral_value() else int(number)


def _is_chat_model(raw: Mapping[str, Any]) -> bool:
    for key in ("type", "model_type"):
        kind = raw.get(key)
        if isinstance(kind, str):
            return kind.lower() in CHAT_TYPES
    architecture = raw.get("architecture")
    if isinstance(architecture, Mapping):
        outputs = architecture.get("output_modalities")
        if isinstance(outputs, list) and outputs:
            return "text" in outputs
    return True


def _supports_tools(raw: Mapping[str, Any]) -> bool:
    parameters = raw.get("supported_parameters")
    if isinstance(parameters, list):
        return any(item in ("tools", "tool_choice", "functions") for item in parameters)
    flag = raw.get("supports_tools", raw.get("tools"))
    return flag is True


def parse_model(raw: Mapping[str, Any]) -> ModelInfo | None:
    model_id = raw.get("id")
    if not isinstance(model_id, str) or not model_id or len(model_id) > 200:
        return None
    if not _is_chat_model(raw):
        return None
    name = raw.get("name")
    top = raw.get("top_provider")
    max_out = raw.get("max_completion_tokens")
    if max_out is None and isinstance(top, Mapping):
        max_out = top.get("max_completion_tokens")
    return ModelInfo(
        id=model_id,
        name=name if isinstance(name, str) and name else model_id,
        context_length=_positive_int(raw.get("context_length")),
        max_completion_tokens=_positive_int(max_out),
        supports_tools=_supports_tools(raw),
        prices=pricing.parse_prices(raw),
    )


@dataclass(frozen=True, slots=True)
class Catalog:
    models: dict[str, ModelInfo]
    fetched_at: datetime
    stale: bool = False


class ModelCatalog:
    def __init__(
        self,
        upstream: UpstreamClient,
        ttl_seconds: float,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._upstream = upstream
        self._ttl = ttl_seconds
        self._now = now
        self._monotonic = monotonic
        self._catalog: Catalog | None = None
        self._loaded_at = 0.0
        self._lock = asyncio.Lock()

    def _fresh(self) -> bool:
        return self._catalog is not None and self._monotonic() - self._loaded_at < self._ttl

    async def get(self, *, refresh: bool = False) -> Catalog:
        """The catalog; refetched when older than the TTL (or ``refresh``).

        When the refresh fails and an older copy exists, that copy is returned flagged stale;
        without a copy the ``UpstreamError`` propagates.
        """
        if not refresh and self._fresh():
            assert self._catalog is not None  # noqa: S101 - ``_fresh`` implies it
            return self._catalog
        async with self._lock:
            if not refresh and self._fresh():
                assert self._catalog is not None  # noqa: S101
                return self._catalog
            try:
                raw = await self._upstream.get_models()
            except UpstreamError as error:
                if self._catalog is None:
                    raise
                log.warning("catalog_refresh_failed", code=error.code, status=error.status)
                self._catalog = Catalog(self._catalog.models, self._catalog.fetched_at, stale=True)
                # Do not hammer a failing provider: serve the old copy for a short while.
                self._loaded_at = self._monotonic() - self._ttl + min(self._ttl, 30.0)
                return self._catalog
            models: dict[str, ModelInfo] = {}
            for item in raw[:MAX_MODELS]:
                info = parse_model(item)
                if info is not None:
                    models[info.id] = info
            self._catalog = Catalog(models, self._now())
            self._loaded_at = self._monotonic()
            return self._catalog

    async def find(self, model_id: str) -> tuple[ModelInfo | None, bool]:
        """``(model, known)``: ``known`` is false when no catalog could be loaded at all."""
        try:
            catalog = await self.get()
            info = catalog.models.get(model_id)
            if info is None and self._monotonic() - self._loaded_at > 60 and not catalog.stale:
                info = (await self.get(refresh=True)).models.get(model_id)  # a new model, maybe
        except UpstreamError:
            return None, False
        return info, True
