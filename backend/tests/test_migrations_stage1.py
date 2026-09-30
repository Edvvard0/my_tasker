import asyncio

from alembic import command
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config

STAGE1_TABLES = {
    "users",
    "devices",
    "login_failures",
    "sync_state",
    "sync_ops",
    "sync_conflicts",
    "user_settings",
}


async def tables(url: str) -> set[str]:
    engine = create_async_engine(url)
    try:
        async with engine.connect() as connection:
            result = await connection.execute(
                text("SELECT table_name FROM information_schema.tables WHERE table_schema='public'")
            )
            return set(result.scalars())
    finally:
        await engine.dispose()


async def test_stage1_migrations_are_reversible_step_by_step(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= STAGE1_TABLES

    for revision, gone in (
        ("0003", {"user_settings"}),
        ("0002", {"sync_state", "sync_ops", "sync_conflicts"}),
        ("0001", {"users", "devices", "login_failures"}),
    ):
        await asyncio.to_thread(command.downgrade, config, revision)
        present = await tables(db_url)
        assert not gone & present, (revision, gone & present)
        assert "app_meta" in present

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= STAGE1_TABLES


async def test_sync_state_is_a_singleton_starting_at_zero(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            row = (
                await connection.execute(
                    text("SELECT id, head_version, purge_watermark FROM sync_state")
                )
            ).one()
    finally:
        await engine.dispose()
    assert tuple(row) == (1, 0, 0)
