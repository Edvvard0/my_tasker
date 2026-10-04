"""Migration 0011 (Study): reversible, leaves Banks intact, matches the table declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config, head_revision
from tasker.study.tables import STUDY_TABLES
from tests.test_migrations_stage1 import tables
from tests.test_migrations_work import columns

STUDY_NAMES = {spec.name for spec in STUDY_TABLES}


def test_revision_chain_has_one_head_and_study_follows_banks() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0011"
    revision = script.get_revision("0011")
    assert revision is not None
    assert revision.down_revision == "0010"


async def test_study_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0010")
    assert not STUDY_NAMES & await tables(db_url)

    await asyncio.to_thread(command.upgrade, config, "0011")
    assert await tables(db_url) >= STUDY_NAMES
    assert {"week1_start", "cycle_length", "week_shifts"} <= await columns(
        db_url, "study_semesters"
    )
    assert {"hide_regular", "items", "on_date"} <= await columns(db_url, "study_day_rules")
    assert {"sha256", "size_bytes", "debt_id", "subject_id"} <= await columns(db_url, "attachments")

    await asyncio.to_thread(command.downgrade, config, "0010")
    assert not STUDY_NAMES & await tables(db_url)
    assert "merchant_key" in await columns(db_url, "merchant_category_rules")  # Stage 6 is intact

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= STUDY_NAMES


async def test_study_lookup_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in STUDY_TABLES:
        assert f"ix_{spec.name}_server_version" in names
        assert f"{spec.name}_tombstones" in names
        for column in spec.parents():
            assert f"ix_{spec.name}_{column.name}" in names, (spec.name, column.name)
