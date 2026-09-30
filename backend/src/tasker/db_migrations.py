"""Alembic helpers shared by the api (readiness), the migrate service and tests."""

import asyncio
import sys
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory

from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.epoch import ensure_epoch
from tasker.logging import configure_logging

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def alembic_config(database_url: str) -> Config:
    config = Config()
    config.set_main_option("script_location", str(MIGRATIONS_DIR))
    # configparser treats "%" as interpolation, so it must be escaped.
    config.set_main_option("sqlalchemy.url", database_url.replace("%", "%%"))
    return config


def head_revision() -> str:
    head = ScriptDirectory(str(MIGRATIONS_DIR)).get_current_head()
    if head is None:  # pragma: no cover - the baseline revision always exists
        raise RuntimeError("no alembic revisions found")
    return head


def upgrade_to_head(database_url: str) -> None:
    command.upgrade(alembic_config(database_url), "head")


async def _ensure_epoch(settings: Settings) -> None:
    engine = create_engine(settings)
    try:
        async with create_sessionmaker(engine)() as session, session.begin():
            await ensure_epoch(session, SystemClock().now())
    finally:
        await engine.dispose()


def main() -> int:
    """Entry point of the one-shot ``migrate`` service: ``python -m tasker.db_migrations``.

    Also detects a database restored into another cluster and gives it a new server epoch.
    """
    settings = Settings()
    configure_logging(settings.log_level)
    upgrade_to_head(settings.db_url)
    asyncio.run(_ensure_epoch(settings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
