"""Migration 0012 (Sleep and rituals): reversible, leaves Study intact, matches the declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config, head_revision
from tasker.sleep.tables import SLEEP_TABLES
from tests.test_migrations_stage1 import tables
from tests.test_migrations_work import columns

SLEEP_NAMES = {spec.name for spec in SLEEP_TABLES}


def test_revision_chain_has_one_head_and_sleep_follows_study() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0012"
    revision = script.get_revision("0012")
    assert revision is not None
    assert revision.down_revision == "0011"


async def test_sleep_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0011")
    assert not SLEEP_NAMES & await tables(db_url)

    await asyncio.to_thread(command.upgrade, config, "0012")
    assert await tables(db_url) >= SLEEP_NAMES
    assert {"bed_at", "wake_at", "bed_tz", "wake_tz", "quality"} <= await columns(
        db_url, "sleep_entries"
    )
    assert {"task_ids", "main_task_id"} <= await columns(db_url, "daily_plans")
    assert {"rating", "done_task_ids", "carry_over"} <= await columns(db_url, "evening_checkins")

    await asyncio.to_thread(command.downgrade, config, "0011")
    assert not SLEEP_NAMES & await tables(db_url)
    assert "hide_regular" in await columns(db_url, "study_day_rules")  # Stage 7 is intact

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= SLEEP_NAMES


async def test_sleep_lookup_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in SLEEP_TABLES:
        assert f"ix_{spec.name}_server_version" in names
        assert f"{spec.name}_tombstones" in names
