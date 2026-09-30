"""Migration 0005 (calendar and tasks): reversible, and it matches the table declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.calendar.tables import CALENDAR_TABLES
from tasker.db_migrations import alembic_config, head_revision
from tasker.tables import metadata
from tests.test_migrations_stage1 import tables

STAGE2_TABLES = {spec.name for spec in CALENDAR_TABLES}


async def test_stage2_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= STAGE2_TABLES

    await asyncio.to_thread(command.downgrade, config, "0004")
    present = await tables(db_url)
    assert not STAGE2_TABLES & present
    assert "user_settings" in present

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= STAGE2_TABLES


def test_revision_chain_has_one_head_and_stage2_is_in_it() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0005"
    chain = [revision.revision for revision in script.walk_revisions()]
    assert "0005" in chain


def _mine(obj: Any, _name: str | None, type_: str, _reflected: bool, _compare_to: Any) -> bool:
    if type_ == "table":
        return bool(obj.name in STAGE2_TABLES)
    table = getattr(obj, "table", None)
    return table is None or bool(table.name in STAGE2_TABLES)


async def test_migrated_schema_matches_the_declared_tables(migrated_db_url: str) -> None:
    """No drift: columns, types, nullability, foreign keys and indexes equal the metadata."""
    engine = create_async_engine(migrated_db_url)

    def diff(connection: sa.Connection) -> list[Any]:
        context = MigrationContext.configure(
            connection,
            opts={"compare_type": True, "include_object": _mine},
        )
        return list(compare_metadata(context, metadata))

    try:
        async with engine.connect() as connection:
            differences = await connection.run_sync(diff)
    finally:
        await engine.dispose()
    assert differences == []


async def test_child_lookup_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in CALENDAR_TABLES:
        for column in spec.parents():
            assert any(
                name.startswith(f"ix_{spec.name}_") and column.name in name for name in names
            ), (spec.name, column.name)
