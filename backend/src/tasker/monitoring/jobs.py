"""Worker jobs of Stage 9. Imported by ``tasker.worker.__main__`` (registers them).

Each job opens what it needs, does one pass and closes; a job that fails is logged and runs again
at the next interval (``tasker.worker.runner``). Nothing here is secret: the token and chat id are
read from the environment inside ``MonitoringRuntime`` only.
"""

import structlog

from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.monitoring import service
from tasker.monitoring.config_gen import system_resolver
from tasker.monitoring.runtime import MonitoringRuntime
from tasker.worker.registry import registry

log = structlog.get_logger("monitoring.jobs")


@registry.register("monitor_config", interval=60)
async def monitor_config() -> None:
    """Regenerate the engine configuration from the owner's servers, services and checks."""
    settings = Settings()
    runtime = MonitoringRuntime(settings)
    engine = create_engine(settings)
    try:
        await service.sync_config(
            create_sessionmaker(engine), runtime.settings, SystemClock(), system_resolver
        )
    finally:
        await runtime.aclose()
        await engine.dispose()


@registry.register("monitor_poll", interval=10)
async def monitor_poll() -> None:
    """Read the engine, advance alert states, queue messages."""
    settings = Settings()
    runtime = MonitoringRuntime(settings)
    if runtime.engine is None:
        await runtime.aclose()
        return
    engine = create_engine(settings)
    try:
        await service.poll_cycle(
            create_sessionmaker(engine), runtime.engine, runtime.settings, SystemClock()
        )
    finally:
        await runtime.aclose()
        await engine.dispose()


@registry.register("monitor_deliver", interval=5)
async def monitor_deliver() -> None:
    """Send the queued messages to Telegram."""
    settings = Settings()
    runtime = MonitoringRuntime(settings)
    engine = create_engine(settings)
    try:
        await service.deliver_outbox(create_sessionmaker(engine), runtime.notifier, SystemClock())
    finally:
        await runtime.aclose()
        await engine.dispose()


@registry.register("monitor_cleanup", interval=3600)
async def monitor_cleanup() -> None:
    settings = Settings()
    engine = create_engine(settings)
    try:
        await service.cleanup(create_sessionmaker(engine), SystemClock())
    finally:
        await engine.dispose()
