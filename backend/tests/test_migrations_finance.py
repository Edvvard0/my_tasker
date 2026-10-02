"""Migration 0009 (Finance): reversible, leaves Stage 4 intact, matches the table declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config, head_revision
from tasker.finance.tables import FINANCE_TABLES
from tests.test_migrations_stage1 import tables
from tests.test_migrations_work import columns

FINANCE_NAMES = {spec.name for spec in FINANCE_TABLES}


def test_revision_chain_has_one_head_and_finance_follows_work() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0009"
    revision = script.get_revision("0009")
    assert revision is not None
    assert revision.down_revision == "0008"


async def test_finance_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0008")
    assert not FINANCE_NAMES & await tables(db_url)

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= FINANCE_NAMES
    assert {"opening_balance", "opening_date", "credit_limit", "include_in_total"} <= await columns(
        db_url, "accounts"
    )
    assert {"to_account_id", "external_id", "dedup_hash", "work_payment_id", "debt_id"} <= (
        await columns(db_url, "transactions")
    )
    assert {"formula", "target_amount"} <= await columns(db_url, "goals")

    await asyncio.to_thread(command.downgrade, config, "0008")
    assert not FINANCE_NAMES & await tables(db_url)
    assert "status" in await columns(db_url, "projects")  # Stage 4 is untouched

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= FINANCE_NAMES


async def test_finance_lookup_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in FINANCE_TABLES:
        assert f"ix_{spec.name}_server_version" in names
        for column in spec.parents():
            assert f"ix_{spec.name}_{column.name}" in names, (spec.name, column.name)
