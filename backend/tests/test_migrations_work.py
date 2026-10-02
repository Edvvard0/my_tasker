"""Migration 0008 (Work): reversible, keeps Stage 2 rows, matches the table declarations."""

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config, head_revision
from tasker.work.tables import WORK_TABLES
from tests.test_migrations_stage1 import tables

WORK_NAMES = {spec.name for spec in WORK_TABLES}


async def columns(url: str, table: str) -> set[str]:
    engine = create_async_engine(url)
    try:
        async with engine.connect() as connection:
            result = await connection.execute(
                sa.text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema='public' AND table_name=:t"
                ),
                {"t": table},
            )
            return set(result.scalars())
    finally:
        await engine.dispose()


def test_revision_chain_has_one_head_and_work_is_in_it() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0008"
    assert "0008" in [revision.revision for revision in script.walk_revisions()]


async def test_work_migration_is_reversible_and_keeps_stage_2_rows(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0007")
    assert not WORK_NAMES & await tables(db_url)
    assert "status" not in await columns(db_url, "projects")

    project = uuid.uuid4()
    engine = create_async_engine(db_url)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                sa.text(
                    "INSERT INTO projects (id, created_at, updated_at, server_version, "
                    "origin_device_id, title, archived) "
                    "VALUES (:id, :now, 'h', 1, :dev, 'Старый', true)"
                ),
                {"id": project, "now": datetime.now(UTC), "dev": uuid.uuid4()},
            )
    finally:
        await engine.dispose()

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= WORK_NAMES
    assert {"client_id", "status", "base_amount", "links"} <= await columns(db_url, "projects")
    assert {"role", "contact"} <= await columns(db_url, "people")
    engine = create_async_engine(db_url)
    try:
        async with engine.connect() as connection:
            row: Any = (
                await connection.execute(
                    sa.text("SELECT title, archived, status, base_amount FROM projects")
                )
            ).one()
    finally:
        await engine.dispose()
    assert tuple(row) == ("Старый", True, None, None)

    await asyncio.to_thread(command.downgrade, config, "0007")
    assert not WORK_NAMES & await tables(db_url)
    assert "status" not in await columns(db_url, "projects")
    assert "role" not in await columns(db_url, "people")
    assert "title" in await columns(db_url, "projects")

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= WORK_NAMES


async def test_work_child_lookup_indexes_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            rows = await connection.execute(
                sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
            )
            names: set[Any] = set(rows.scalars())
    finally:
        await engine.dispose()
    for spec in WORK_TABLES:
        for column in spec.parents():
            assert f"ix_{spec.name}_{column.name}" in names, (spec.name, column.name)
