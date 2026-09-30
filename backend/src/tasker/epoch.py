"""Server epoch: a random id that changes whenever the database content may have gone back in time.

Clients remember the epoch they synchronised with; a different epoch means the server was
restored from a dump, so they must do a full resync (spec 3.10). The epoch lives in ``app_meta``.

It is rotated by (a) ``python -m tasker.cli epoch rotate``, part of the documented restore
procedure, and (b) automatically when the database fingerprint (cluster system identifier plus
database OID) differs from the one stored in the data: a dump restored into another cluster or a
re-created database carries the *old* fingerprint, so the mismatch is detected on the next start
of the ``migrate`` service.
"""

import uuid
from datetime import datetime

import sqlalchemy as sa
import structlog
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.tables import app_meta

log = structlog.get_logger("epoch")
EPOCH_KEY = "server_epoch"
FINGERPRINT_KEY = "db_fingerprint"


async def _get(session: AsyncSession, key: str) -> str | None:
    result = await session.execute(sa.select(app_meta.c.value).where(app_meta.c.key == key))
    value: str | None = result.scalar_one_or_none()
    return value


async def _put(session: AsyncSession, key: str, value: str, now: datetime) -> None:
    await session.execute(
        sa.text(
            "INSERT INTO app_meta (key, value, updated_at) VALUES (:k, :v, :t)"
            " ON CONFLICT (key) DO UPDATE"
            " SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at"
        ),
        {"k": key, "v": value, "t": now},
    )


async def read_epoch(session: AsyncSession) -> str:
    """The current epoch (inside the caller's transaction)."""
    value = await _get(session, EPOCH_KEY)
    if value is None:  # pragma: no cover - the migration creates it
        raise RuntimeError("server_epoch is missing from app_meta: run the migrations")
    return value


async def rotate_epoch(session: AsyncSession, now: datetime) -> str:
    """Give the database a new epoch (inside the caller's transaction)."""
    new = str(uuid.uuid4())
    await _put(session, EPOCH_KEY, new, now)
    return new


async def database_fingerprint(session: AsyncSession) -> str:
    oid: int = (
        await session.execute(
            sa.text("SELECT oid FROM pg_database WHERE datname = current_database()")
        )
    ).scalar_one()
    system_id = "-"
    try:
        async with session.begin_nested():
            system_id = str(
                (
                    await session.execute(
                        sa.text("SELECT system_identifier FROM pg_control_system()")
                    )
                ).scalar_one()
            )
    except DBAPIError:  # the role may not run pg_control_system(); the OID alone still helps
        log.info("epoch_fingerprint_without_system_identifier")
    return f"{system_id}:{oid}"


async def ensure_epoch(session: AsyncSession, now: datetime) -> str | None:
    """Rotate the epoch when the database moved to another cluster; return the new epoch if so.

    Idempotent, run at every start of the migrate service (inside the caller's transaction).
    """
    current = await database_fingerprint(session)
    stored = await _get(session, FINGERPRINT_KEY)
    if stored == current:
        return None
    await _put(session, FINGERPRINT_KEY, current, now)
    if stored is None:
        return None  # first start on this database: the epoch from the migration is fresh
    new = await rotate_epoch(session, now)
    log.warning("server_epoch_rotated", reason="database_fingerprint_changed")
    return new
