"""Test-only synchronised tables: a parent/child pair to exercise cascades."""

from collections.abc import Mapping
from typing import Any

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.sync.registry import (
    ColumnSpec,
    SyncRegistry,
    SyncTableSpec,
    bool_column,
    datetime_column,
    define_sync_table,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid_column,
)
from tasker.sync.user_settings import user_settings

TEST_METADATA = sa.MetaData()

projects: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_projects",
    (
        text_column("title", max_length=50),
        int_column("budget", ge=0, required=False),
        bool_column("archived", required=False),
    ),
    validators=(lambda row: "title must not be blank" if not str(row["title"]).strip() else None,),
)
tasks: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_tasks",
    (
        reference_column("project_id", "test_projects"),
        text_column("title", max_length=50),
        text_column("note", max_length=200, nullable=True, required=False),
    ),
)
subtasks: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_subtasks",
    (reference_column("task_id", "test_tasks"), text_column("title", max_length=50)),
)


notes: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_notes",
    (
        text_column("title", max_length=50),
        datetime_column("due", nullable=True, required=False),
        json_column("data", nullable=True, required=False),
    ),
)


class _Unchecked:
    """A deliberately lax adapter: what the validators miss must not be able to break a push."""

    def validate_python(self, value: object) -> object:
        return value

    def dump_python(self, value: object, *, mode: str = "json") -> object:
        return value


def _explode(row: Mapping[str, Any]) -> str | None:
    if row["raw"] == "overflow":
        raise OverflowError("simulated")
    if row["raw"] == "value":
        raise ValueError("simulated")
    return None


raws: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_raws",
    (ColumnSpec("raw", sa.Text(), _Unchecked()),),
    validators=(_explode,),
)


links: SyncTableSpec = define_sync_table(
    TEST_METADATA,
    "test_links",
    (
        reference_column("owner_id", "test_projects", immutable=True),
        uuid_column("ref", nullable=True, required=False),
        uuid_column("fixed_ref", nullable=True, required=False, immutable=True),
        datetime_column("at", nullable=True, required=False),
    ),
)


def build_test_registry() -> SyncRegistry:
    registry = SyncRegistry()
    for spec in (user_settings, projects, tasks, subtasks, notes, raws, links):
        registry.register(spec)
    return registry


async def create_test_tables(url: str) -> None:
    engine = create_async_engine(url)
    try:
        async with engine.begin() as connection:
            await connection.run_sync(TEST_METADATA.create_all)
    finally:
        await engine.dispose()
