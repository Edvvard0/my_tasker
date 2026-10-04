"""Worker job: purge tombstones and trim journals. Imported by ``tasker.worker.__main__``."""

import structlog

from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.files.housekeeping import purge_hook, sweep_orphans
from tasker.runtime import build_file_store
from tasker.sync.modules import build_registry
from tasker.sync.purge import cleanup_records, purge_tombstones
from tasker.worker.registry import registry

log = structlog.get_logger("sync.jobs")


@registry.register("sync_housekeeping", interval=3600)
async def sync_housekeeping() -> None:
    settings = Settings()
    engine = create_engine(settings)
    try:
        sessionmaker = create_sessionmaker(engine)
        now = SystemClock().now()
        store = build_file_store(settings)
        hook = purge_hook(store) if store is not None else None
        purged = await purge_tombstones(sessionmaker, build_registry(), now, hook)
        await cleanup_records(sessionmaker, now)
        swept = await sweep_orphans(sessionmaker, store) if store is not None else 0
        log.info("sync_housekeeping_done", purged_tombstones=purged, orphan_files=swept)
    finally:
        await engine.dispose()
