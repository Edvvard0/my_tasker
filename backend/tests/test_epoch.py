"""Server epoch (spec 3.10): every response names it, a restore gives the database a new one."""

import asyncio
import uuid

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine

from tasker import cli, db_migrations
from tasker.epoch import (
    FINGERPRINT_KEY,
    database_fingerprint,
    ensure_epoch,
    read_epoch,
    rotate_epoch,
)
from tasker.sync.user_settings import settings_id
from tests.api_support import SCHEMA, Env
from tests.sync_sim.client import SimClient
from tests.sync_sim.server import FlakyServer
from tests.test_auth_api import error_code
from tests.test_sync_push import create_setting


async def stored_epoch(env: Env) -> str:
    value: str = await env.scalar("SELECT value FROM app_meta WHERE key = 'server_epoch'")
    return value


async def test_epoch_is_a_uuid4_created_by_the_migration(env: Env) -> None:
    assert uuid.UUID(await stored_epoch(env)).version == 4


async def test_every_sync_and_auth_response_carries_the_same_epoch(env: Env) -> None:
    epoch = await stored_epoch(env)
    login = (await env.client.post("/auth/login", json=env.login_body(), headers=SCHEMA)).json()
    assert login["server_epoch"] == epoch
    device = await env.login("PC")
    refreshed = await env.client.post(
        "/auth/refresh", json={"refresh_token": login["refresh_token"]}, headers=SCHEMA
    )
    assert refreshed.json()["server_epoch"] == epoch
    pushed = await device.push([create_setting(device)])
    assert pushed.json()["server_epoch"] == epoch
    assert (await device.pull_ok())["server_epoch"] == epoch
    empty_push = await device.push([{"op_id": "nope"}])  # nothing applied: still carries it
    assert empty_push.json()["server_epoch"] == epoch
    assert (await env.client.get("/version")).json()["server_epoch"] == epoch


async def test_rotating_changes_the_epoch_everywhere(env: Env) -> None:
    device = await env.login()
    before = (await device.pull_ok())["server_epoch"]
    async with env.sessionmaker() as session, session.begin():
        new = await rotate_epoch(session, env.clock.now())
    assert new != before
    assert (await device.pull_ok())["server_epoch"] == new
    assert (await env.client.get("/version")).json()["server_epoch"] == new


async def test_fingerprint_change_rotates_the_epoch_and_a_repeat_does_not(env: Env) -> None:
    async def ensure() -> str | None:
        async with env.sessionmaker() as session, session.begin():
            return await ensure_epoch(session, env.clock.now())

    epoch = await stored_epoch(env)
    assert await ensure() is None  # first start on this database: fingerprint recorded
    assert await ensure() is None  # unchanged
    assert await stored_epoch(env) == epoch
    # A dump restored into another cluster brings the old cluster's fingerprint along.
    await env.execute("UPDATE app_meta SET value = '1234:5678' WHERE key = :k", k=FINGERPRINT_KEY)
    rotated = await ensure()
    assert rotated is not None
    assert rotated != epoch
    assert await stored_epoch(env) == rotated
    assert await ensure() is None  # the new fingerprint is stored


async def test_fingerprint_names_the_cluster_and_the_database(env: Env) -> None:
    async with env.sessionmaker() as session, session.begin():
        fingerprint = await database_fingerprint(session)
    system_id, oid = fingerprint.split(":")
    assert system_id.isdigit()
    assert oid.isdigit()


async def test_epoch_read_inside_a_transaction(env: Env) -> None:
    async with env.sessionmaker() as session, session.begin():
        assert await read_epoch(session) == await stored_epoch(env)


async def test_migrate_service_records_the_fingerprint(
    migrated_db_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABASE_URL", migrated_db_url)
    monkeypatch.setenv("LOG_LEVEL", "WARNING")
    assert await asyncio.to_thread(db_migrations.main) == 0
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            row: str = (
                await connection.execute(
                    sa.text("SELECT value FROM app_meta WHERE key = :k"), {"k": FINGERPRINT_KEY}
                )
            ).scalar_one()
            assert row
            await connection.execute(
                sa.text("UPDATE app_meta SET value = 'x:y' WHERE key = :k"), {"k": FINGERPRINT_KEY}
            )
            before: str = (
                await connection.execute(
                    sa.text("SELECT value FROM app_meta WHERE key='server_epoch'")
                )
            ).scalar_one()
            await connection.commit()
    finally:
        await engine.dispose()
    assert await asyncio.to_thread(db_migrations.main) == 0  # detects the "restore"
    engine = create_async_engine(migrated_db_url)
    try:
        async with engine.connect() as connection:
            after: str = (
                await connection.execute(
                    sa.text("SELECT value FROM app_meta WHERE key='server_epoch'")
                )
            ).scalar_one()
    finally:
        await engine.dispose()
    assert after != before


async def test_cli_shows_and_rotates_the_epoch(
    env: Env, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DATABASE_URL", env.url)
    monkeypatch.setenv("LOG_LEVEL", "WARNING")
    before = await stored_epoch(env)
    assert await asyncio.to_thread(cli.main, ["epoch", "show"]) == 0
    assert capsys.readouterr().out.strip() == before
    assert await asyncio.to_thread(cli.main, ["epoch", "rotate"]) == 0
    printed = capsys.readouterr().out.strip()
    assert printed == await stored_epoch(env)
    assert printed != before


async def test_cursor_ahead_of_the_server_needs_a_resync(env: Env) -> None:
    device = await env.login()
    await device.push_ok([create_setting(device)])
    response = await device.pull(since=5)
    assert (response.status_code, error_code(response)) == (410, "resync_required")
    details = response.json()["error"]["details"]
    assert (details["reason"], details["head_version"]) == ("cursor_ahead", 1)
    # The cursor of a device is never stored above the head.
    assert await env.scalar("SELECT last_pulled_version FROM devices") == 0
    assert (await device.pull(since=1)).status_code == 200  # equal to head is fine
    assert await env.scalar("SELECT last_pulled_version FROM devices") == 1
    assert (await device.pull(since=0)).status_code == 200


async def test_client_keeps_its_outbox_and_resyncs_after_the_server_was_restored(
    env: Env,
) -> None:
    """Reference client (spec 5.3): a restore loses server data, the outbox survives."""
    device = await env.login()
    clock_ms = lambda: env.clock.ms  # noqa: E731
    client = SimClient(device.device_id, clock_ms)
    server = FlakyServer(env.sessionmaker, env.rt.registry, env.clock)
    client.create("user_settings", str(settings_id("kept")), {"key": "kept", "value": 1})
    await client.sync(server)
    epoch = client.epoch
    assert epoch == await stored_epoch(env)
    client.create("user_settings", str(settings_id("offline")), {"key": "offline", "value": 2})

    # The operator restores an older dump: the row is gone, the counter went back, new epoch.
    await env.execute("DELETE FROM user_settings")
    await env.execute("UPDATE sync_state SET head_version = 0")
    async with env.sessionmaker() as session, session.begin():
        new = await rotate_epoch(session, env.clock.now())

    await client.sync(server)  # the outbox is pushed, then the epoch change is noticed
    assert client.epoch == new != epoch
    assert client.outbox == []
    assert {row["key"] for row in client.rows.values()} == {"offline"}
    assert client.cursor == 1
