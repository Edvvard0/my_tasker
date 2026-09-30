"""Fan-out of Postgres ``LISTEN/NOTIFY`` commits to ``/events`` subscribers."""

import asyncio
import contextlib
import json
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import asyncpg
import structlog
from sqlalchemy.engine import make_url

from tasker.sync.engine import NOTIFY_CHANNEL

log = structlog.get_logger("sync.notify")


class Subscription:
    """Collects "something changed" signals from devices other than the owner."""

    def __init__(self, device_id: uuid.UUID) -> None:
        self.device_id = device_id
        self.event = asyncio.Event()

    def offer(self, origin: str | None) -> None:
        if origin != str(self.device_id):
            self.event.set()


class ChangeHub:
    def __init__(
        self, database_url: str, *, retry_delay: float = 1.0, ready_timeout: float = 5.0
    ) -> None:
        self._dsn = (
            make_url(database_url)
            .set(drivername="postgresql")
            .render_as_string(hide_password=False)
        )
        self._retry_delay = retry_delay
        self._ready_timeout = ready_timeout
        self._subscriptions: set[Subscription] = set()
        self._task: asyncio.Task[None] | None = None
        self._ready = asyncio.Event()
        self.closed = asyncio.Event()

    @asynccontextmanager
    async def subscribe(self, device_id: uuid.UUID) -> AsyncIterator[Subscription]:
        subscription = Subscription(device_id)
        self._subscriptions.add(subscription)
        if self._task is None:
            self._task = asyncio.create_task(self._run())
        try:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._ready.wait(), timeout=self._ready_timeout)
            yield subscription
        finally:
            self._subscriptions.discard(subscription)

    def _on_notify(self, _conn: object, _pid: int, _channel: str, payload: str) -> None:
        try:
            origin = json.loads(payload).get("device")
        except (ValueError, AttributeError):
            origin = None
        for subscription in list(self._subscriptions):
            subscription.offer(origin)

    async def _run(self) -> None:
        reconnecting = False
        while not self.closed.is_set():
            connection: asyncpg.Connection | None = None
            try:
                connection = await asyncpg.connect(self._dsn, timeout=5)
                await connection.add_listener(NOTIFY_CHANNEL, self._on_notify)
                self._ready.set()
                if reconnecting:
                    # Anything committed while we were not listening is unknown: wake everyone.
                    for subscription in list(self._subscriptions):
                        subscription.offer(None)
                while not connection.is_closed() and not self.closed.is_set():
                    with contextlib.suppress(TimeoutError):
                        await asyncio.wait_for(self.closed.wait(), timeout=1)
            except (OSError, asyncpg.PostgresError, TimeoutError) as exc:
                log.warning("notify_listener_failed", error_type=type(exc).__name__)
            finally:
                reconnecting = True
                self._ready.clear()
                if connection is not None and not connection.is_closed():
                    with contextlib.suppress(Exception):
                        await connection.close(timeout=2)
            if not self.closed.is_set():
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self.closed.wait(), timeout=self._retry_delay)

    async def close(self) -> None:
        self.closed.set()
        for subscription in list(self._subscriptions):
            subscription.event.set()
        if self._task is not None:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(self._task, timeout=5)
