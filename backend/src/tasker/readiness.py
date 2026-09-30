import asyncio
from enum import StrEnum

import structlog
from sqlalchemy import text
from sqlalchemy.exc import ProgrammingError, SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.db_migrations import head_revision

log = structlog.get_logger()


class NotReady(StrEnum):
    DATABASE_UNAVAILABLE = "database_unavailable"
    MIGRATIONS_NOT_APPLIED = "migrations_not_applied"


async def check_readiness(session: AsyncSession, limit: float) -> NotReady | None:
    """Return why the service is not ready, or ``None`` when DB is up and alembic is at head."""
    try:
        async with asyncio.timeout(limit):
            await session.execute(text("SELECT 1"))
            try:
                result = await session.execute(text("SELECT version_num FROM alembic_version"))
            except ProgrammingError:
                return NotReady.MIGRATIONS_NOT_APPLIED
            current: list[str] = list(result.scalars())
    except (SQLAlchemyError, OSError, TimeoutError) as exc:
        log.warning("readiness_db_check_failed", error_type=type(exc).__name__)
        return NotReady.DATABASE_UNAVAILABLE
    if current != [head_revision()]:
        return NotReady.MIGRATIONS_NOT_APPLIED
    return None
