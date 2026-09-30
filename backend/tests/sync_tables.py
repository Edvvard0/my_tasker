"""Test-only synchronised tables: a parent/child pair to exercise cascades."""

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.sync.registry import (
    SyncRegistry,
    SyncTableSpec,
    bool_column,
    define_sync_table,
    int_column,
    reference_column,
    text_column,
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


def build_test_registry() -> SyncRegistry:
    registry = SyncRegistry()
    for spec in (user_settings, projects, tasks, subtasks):
        registry.register(spec)
    return registry


async def create_test_tables(url: str) -> None:
    engine = create_async_engine(url)
    try:
        async with engine.begin() as connection:
            await connection.run_sync(TEST_METADATA.create_all)
    finally:
        await engine.dispose()
