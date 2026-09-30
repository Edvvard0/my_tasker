import asyncio

import pytest
from alembic import command
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from tasker import db_migrations
from tasker.db_migrations import alembic_config, head_revision, upgrade_to_head


async def _tables(url: str) -> set[str]:
    engine = create_async_engine(url)
    try:
        async with engine.connect() as connection:
            result = await connection.execute(
                text("SELECT table_name FROM information_schema.tables WHERE table_schema='public'")
            )
            return set(result.scalars())
    finally:
        await engine.dispose()


async def _current(url: str) -> list[str]:
    engine = create_async_engine(url)
    try:
        async with engine.connect() as connection:
            result = await connection.execute(text("SELECT version_num FROM alembic_version"))
            return list(result.scalars())
    finally:
        await engine.dispose()


async def test_upgrade_downgrade_upgrade(db_url: str) -> None:
    config = alembic_config(db_url)

    await asyncio.to_thread(command.upgrade, config, "head")
    assert "app_meta" in await _tables(db_url)
    assert await _current(db_url) == [head_revision()]

    await asyncio.to_thread(command.downgrade, config, "base")
    assert "app_meta" not in await _tables(db_url)
    assert await _current(db_url) == []

    await asyncio.to_thread(command.upgrade, config, "head")
    assert "app_meta" in await _tables(db_url)
    assert await _current(db_url) == [head_revision()]


async def test_upgrade_is_idempotent(db_url: str) -> None:
    await asyncio.to_thread(upgrade_to_head, db_url)
    await asyncio.to_thread(upgrade_to_head, db_url)
    assert await _current(db_url) == [head_revision()]


async def test_password_with_percent_survives_config(db_url: str) -> None:
    assert (
        alembic_config("postgresql+asyncpg://u:p%40ss@h/db").get_main_option("sqlalchemy.url")
        == "postgresql+asyncpg://u:p%40ss@h/db"
    )


async def test_migrate_entrypoint_applies_head(
    db_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABASE_URL", db_url)
    assert await asyncio.to_thread(db_migrations.main) == 0
    assert await _current(db_url) == [head_revision()]
