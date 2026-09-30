"""The SQLAlchemy metadata and the hand-written migrations must describe the same schema.

Every synchronised table of every stage lives in ``tasker.tables.metadata`` (through
``define_sync_table``), so a new table whose migration forgets a column, an index or a constraint
fails here. Test-only tables use their own metadata and are not compared.
"""

from typing import Any

import sqlalchemy as sa
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.sync.modules import build_registry
from tasker.tables import metadata


def _diff(connection: Connection) -> list[Any]:
    context = MigrationContext.configure(
        connection,
        opts={
            "compare_type": True,
            "compare_server_default": False,
            "include_object": lambda _obj, name, type_, _reflected, _compare_to: (
                not (type_ == "table" and name == "alembic_version")
            ),
        },
    )
    return list(compare_metadata(context, metadata))


async def test_metadata_matches_the_migrated_schema(migrated_db_url: str) -> None:
    registry = build_registry()  # importing the modules registers their tables on ``metadata``
    assert {spec.name for spec in registry.tables()} <= set(metadata.tables)
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            diff = await connection.run_sync(_diff)
    finally:
        await engine.dispose()
    assert diff == []


async def test_the_comparison_notices_drift(migrated_db_url: str) -> None:
    """Guard against a vacuous test: a schema change the metadata does not know is reported."""
    build_registry()
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.begin() as connection:
            await connection.execute(sa.text("CREATE INDEX drift_probe ON devices (name)"))
            await connection.execute(sa.text("ALTER TABLE devices ADD COLUMN drift_probe text"))
            diff = await connection.run_sync(_diff)
    finally:
        await engine.dispose()
    kinds = {item[0] for item in diff}
    assert {"remove_index", "remove_column"} <= kinds
