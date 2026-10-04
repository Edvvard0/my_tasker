"""Migration 0010 (Banks): reversible, leaves Finance intact, matches the table declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.banks.tables import BANKS_TABLES
from tasker.db_migrations import alembic_config, head_revision
from tests.test_migrations_stage1 import tables
from tests.test_migrations_work import columns

BANKS_NAMES = {spec.name for spec in BANKS_TABLES}


def test_revision_chain_has_one_head_and_banks_follow_finance() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0010"
    revision = script.get_revision("0010")
    assert revision is not None
    assert revision.down_revision == "0009"


async def test_banks_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0009")
    assert not BANKS_NAMES & await tables(db_url)

    await asyncio.to_thread(command.upgrade, config, "0010")
    assert await tables(db_url) >= BANKS_NAMES
    assert {"merchant_key", "match_type", "kind", "category_id"} <= await columns(
        db_url, "merchant_category_rules"
    )

    await asyncio.to_thread(command.downgrade, config, "0009")
    assert not BANKS_NAMES & await tables(db_url)
    assert "dedup_hash" in await columns(db_url, "transactions")  # Stage 5 is untouched

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= BANKS_NAMES


async def test_banks_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in BANKS_TABLES:
        assert f"ix_{spec.name}_server_version" in names
        assert f"{spec.name}_tombstones" in names
