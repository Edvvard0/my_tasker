"""Worker side of the file store: remove the content of purged attachments, sweep orphans."""

import uuid

import sqlalchemy as sa
import structlog
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tasker.files.store import FileStore
from tasker.study.tables import attachments
from tasker.sync.purge import PurgeHook

log = structlog.get_logger("files.housekeeping")
STALE_TEMP_SECONDS = 3600
BATCH = 500


def purge_hook(store: FileStore) -> PurgeHook:
    """A hook for ``purge_tombstones``: rows of ``attachments`` that were physically removed lose
    their files too."""

    async def hook(table: str, ids: list[uuid.UUID]) -> None:
        if table == attachments.name:
            for key in ids:
                await store.delete(key)

    return hook


async def sweep_orphans(sessionmaker: async_sessionmaker[AsyncSession], store: FileStore) -> int:
    """Delete files that have no ``attachments`` row at all (a crash between the removal of the
    row and of the file, or a file whose row was purged by an older version), and temporary files
    of interrupted uploads older than an hour. Returns the number of removed files."""
    removed = await store.remove_stale_temporaries(STALE_TEMP_SECONDS)
    keys = await store.keys()
    for start in range(0, len(keys), BATCH):
        batch = keys[start : start + BATCH]
        async with sessionmaker() as session:
            found = await session.execute(
                sa.select(attachments.table.c.id).where(attachments.table.c.id.in_(batch))
            )
            known: set[uuid.UUID] = set(found.scalars())
        for key in batch:
            if key not in known:
                await store.delete(key)
                removed += 1
    if removed:
        log.info("orphan_files_removed", count=removed)
    return removed
