"""Worker job: purge tombstones and trim journals. Imported by ``tasker.worker.__main__``."""

import structlog

from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.sync.modules import build_registry
from tasker.sync.purge import cleanup_records, purge_tombstones
from tasker.worker.registry import registry

log = structlog.get_logger("sync.jobs")


@registry.register("sync_housekeeping", interval=3600)
async def sync_housekeeping() -> None:
    engine = create_engine(Settings())
    try:
        sessionmaker = create_sessionmaker(engine)
        now = SystemClock().now()
        purged = await purge_tombstones(sessionmaker, build_registry(), now)
        await cleanup_records(sessionmaker, now)
        log.info("sync_housekeeping_done", purged_tombstones=purged)
    finally:
        await engine.dispose()
