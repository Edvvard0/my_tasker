"""Migration 0013 (monitoring): reversible, leaves Sleep intact, matches the declarations."""

import asyncio
from typing import Any

import sqlalchemy as sa
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import alembic_config, head_revision
from tasker.monitoring.storage import (
    monitor_incidents,
    monitor_outbox,
    monitor_results,
    monitor_rollups,
    monitor_state,
)
from tasker.monitoring.tables import MONITORING_TABLES
from tests.test_migrations_stage1 import tables
from tests.test_migrations_work import columns

SYNCED = {spec.name for spec in MONITORING_TABLES}
SERVER_ONLY = {
    t.name
    for t in (monitor_results, monitor_rollups, monitor_state, monitor_incidents, monitor_outbox)
}


def test_revision_chain_has_one_head_and_monitoring_follows_sleep() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://u:p@h/db"))
    assert len(script.get_heads()) == 1
    assert head_revision() >= "0013"
    revision = script.get_revision("0013")
    assert revision is not None
    assert revision.down_revision == "0012"


async def test_monitoring_migration_is_reversible(db_url: str) -> None:
    config = alembic_config(db_url)
    await asyncio.to_thread(command.upgrade, config, "0012")
    assert not (SYNCED | SERVER_ONLY) & await tables(db_url)

    await asyncio.to_thread(command.upgrade, config, "0013")
    assert await tables(db_url) >= SYNCED | SERVER_ONLY
    assert {"interval_seconds", "timeout_seconds", "keyword", "ssl_min_days"} <= await columns(
        db_url, "monitor_checks"
    )
    assert {"dedup_key", "next_attempt_at", "sent_at"} <= await columns(db_url, "monitor_outbox")

    await asyncio.to_thread(command.downgrade, config, "0012")
    assert not (SYNCED | SERVER_ONLY) & await tables(db_url)
    assert "bed_at" in await columns(db_url, "sleep_entries")  # Stage 8 is intact

    await asyncio.to_thread(command.upgrade, config, "head")
    assert await tables(db_url) >= SYNCED | SERVER_ONLY


async def test_monitoring_indexes_and_constraints_exist(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            indexes: set[Any] = set(
                (
                    await connection.execute(
                        sa.text("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
                    )
                ).scalars()
            )
            constraints: set[Any] = set(
                (await connection.execute(sa.text("SELECT conname FROM pg_constraint"))).scalars()
            )
    finally:
        await engine.dispose()
    for spec in MONITORING_TABLES:
        assert f"ix_{spec.name}_server_version" in indexes
        assert f"{spec.name}_tombstones" in indexes
        for column in spec.parents():
            assert f"ix_{spec.name}_{column.name}" in indexes
    assert {
        "ix_monitor_results_at",
        "ix_monitor_rollups_hour_start",
        "ix_monitor_outbox_due",
    } <= indexes
    assert {"uq_monitor_outbox_dedup_key", "uq_monitor_incidents_service_n"} <= constraints
