"""Process-wide AI collaborators (kept on ``app.state.ai``): provider client, catalog, live runs."""

import asyncio
import contextlib
import uuid
from collections.abc import Awaitable, Callable, Coroutine
from typing import TYPE_CHECKING, Any

from fastapi import Request

from tasker.ai.catalog import ModelCatalog
from tasker.ai.upstream import UpstreamClient
from tasker.clock import Clock
from tasker.config import Settings

if TYPE_CHECKING:
    from tasker.ai.runner import ChatRun


class AiRuntime:
    def __init__(
        self,
        settings: Settings,
        clock: Clock,
        upstream: UpstreamClient | None = None,
    ) -> None:
        self.settings = settings
        self.clock = clock
        self.upstream = upstream or UpstreamClient(settings)
        self.catalog = ModelCatalog(self.upstream, settings.polza_models_ttl_seconds, now=clock.now)
        self.runs: dict[uuid.UUID, ChatRun] = {}
        # Answers in progress, by assistant message id, from the first line of the pre-flight
        # checks to the end of the run: the claim on the id and the money held back for the
        # answer (kopecks), so that parallel requests cannot all pass the limit together.
        self.reserved: dict[uuid.UUID, int] = {}
        self._background: set[asyncio.Task[Any]] = set()

    def spawn(self, coro: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]:
        """A task the runtime keeps alive (and waits for at shutdown) on its own."""
        task = asyncio.ensure_future(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)
        return task

    def claim(self, message_id: uuid.UUID) -> bool:
        """Take the id for a new answer; ``False`` if an answer with it is in progress."""
        if message_id in self.reserved:
            return False
        self.reserved[message_id] = 0
        return True

    def reserve(self, message_id: uuid.UUID, kopecks: int) -> None:
        if message_id in self.reserved:
            self.reserved[message_id] = kopecks

    def release(self, message_id: uuid.UUID) -> None:
        self.reserved.pop(message_id, None)

    def reserved_by_others(self, message_id: uuid.UUID) -> int:
        return sum(kopecks for key, kopecks in self.reserved.items() if key != message_id)

    async def shielded[T](self, make: Callable[[], Awaitable[T]]) -> T:
        """Run ``make()`` to completion even if the caller is cancelled meanwhile."""

        async def run() -> T:
            return await make()

        return await asyncio.shield(self.spawn(run()))

    async def wait_idle(self, limit: float = 10.0) -> None:
        """Wait until no chat run and no background write is pending (shutdown, tests)."""
        async with asyncio.timeout(limit):
            while self._background or self.runs:
                pending = list(self._background)
                if pending:
                    await asyncio.wait(pending)
                else:
                    await asyncio.sleep(0.01)

    async def aclose(self) -> None:
        for run in list(self.runs.values()):
            run.cancel()
        with contextlib.suppress(TimeoutError):
            await self.wait_idle(limit=10.0)
        await self.upstream.aclose()


def get_ai(request: Request) -> AiRuntime:
    ai: AiRuntime = request.app.state.ai
    return ai
