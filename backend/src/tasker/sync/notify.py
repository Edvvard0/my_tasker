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
        # Subscribed while the listener was down: commits before it attached went unseen.
        self.missed_start = False

    def offer(self, origin: str | None) -> None:
        if origin != str(self.device_id):
            self.event.set()


class ChangeHub:
    def __init__(
        self,
        database_url: str,
        *,
        retry_delay: float = 1.0,
        max_retry_delay: float = 30.0,
        ready_timeout: float = 5.0,
    ) -> None:
        self._dsn = (
            make_url(database_url)
            .set(drivername="postgresql")
            .render_as_string(hide_password=False)
        )
        self._retry_delay = retry_delay
        self._max_retry_delay = max_retry_delay
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
            try:
                await asyncio.wait_for(self._ready.wait(), timeout=self._ready_timeout)
            except TimeoutError:
                subscription.missed_start = True  # woken as soon as the listener attaches
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

    def backoff(self, failures: int) -> float:
        """Pause before the next connection attempt: doubles per consecutive failure, capped."""
        doubled = self._retry_delay * 2 ** min(max(failures - 1, 0), 10)
        return float(min(self._max_retry_delay, doubled))

    def _wake_all(self, *, only_missed: bool) -> None:
        for subscription in list(self._subscriptions):
            if not only_missed or subscription.missed_start:
                subscription.missed_start = False
                subscription.offer(None)

    async def _run(self) -> None:
        """Keep one LISTEN connection alive; never let an error end the loop (backoff, retry)."""
        reconnecting = False
        failures = 0
        while not self.closed.is_set():
            connection: asyncpg.Connection | None = None
            try:
                connection = await asyncpg.connect(self._dsn, timeout=5)
                await connection.add_listener(NOTIFY_CHANNEL, self._on_notify)
                self._ready.set()
                failures = 0
                # After a reconnect anything committed meanwhile is unknown: wake everyone. On
                # the first connect only those who subscribed before we were listening.
                self._wake_all(only_missed=not reconnecting)
                while not connection.is_closed() and not self.closed.is_set():
                    with contextlib.suppress(TimeoutError):
                        await asyncio.wait_for(self.closed.wait(), timeout=1)
            except Exception as exc:  # the listener must survive any failure
                failures += 1
                log.warning(
                    "notify_listener_failed",
                    error_type=type(exc).__name__,
                    exc_info=not isinstance(exc, OSError | asyncpg.PostgresError | TimeoutError),
                )
            finally:
                reconnecting = True
                self._ready.clear()
                if connection is not None and not connection.is_closed():
                    with contextlib.suppress(Exception):
                        await connection.close(timeout=2)
            if not self.closed.is_set():
                delay = min(
                    self._max_retry_delay, self._retry_delay * 2 ** min(max(failures - 1, 0), 10)
                )
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self.closed.wait(), timeout=delay)

    async def close(self) -> None:
        self.closed.set()
        for subscription in list(self._subscriptions):
            subscription.event.set()
        if self._task is not None:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(self._task, timeout=5)
