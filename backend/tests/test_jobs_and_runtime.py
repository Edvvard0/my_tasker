import asyncio

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_sessionmaker
from tasker.main import create_app
from tasker.runtime import build_runtime
from tasker.sync.jobs import sync_housekeeping
from tasker.sync.modules import build_registry
from tasker.worker.registry import registry
from tests.api_support import SCHEMA, Env, FakeClock
from tests.test_auth_api import error_code
from tests.test_sync_push import create_setting


def test_housekeeping_is_registered_hourly() -> None:
    job = next(job for job in registry.jobs() if job.name == "sync_housekeeping")
    assert job.interval == 3600
    assert job.func is sync_housekeeping


async def test_housekeeping_job_purges_old_tombstones(
    migrated_db_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = create_async_engine(migrated_db_url)
    async with engine.begin() as connection:
        await connection.execute(
            sa.text(
                "INSERT INTO user_settings (id, created_at, updated_at, deleted_at, server_version,"
                " origin_device_id, field_meta, key, value) VALUES"
                " (gen_random_uuid(), now(), 'x', now() - interval '31 days', 1,"
                "  gen_random_uuid(), '{}', 'old', '1'),"
                " (gen_random_uuid(), now(), 'x', now() - interval '1 day', 2,"
                "  gen_random_uuid(), '{}', 'young', '1')"
            )
        )
    monkeypatch.setenv("DATABASE_URL", migrated_db_url)
    await sync_housekeeping()
    async with engine.connect() as connection:
        result = await connection.execute(sa.text("SELECT key FROM user_settings"))
        keys: list[str] = list(result.scalars())
    await engine.dispose()
    assert keys == ["young"]


def test_runtime_requires_a_secret_key_outside_tests() -> None:
    engine = create_async_engine("postgresql+asyncpg://u:p@127.0.0.1:1/x")
    sessionmaker = create_sessionmaker(engine)
    for env_name in ("dev", "prod"):
        settings = Settings(database_url="postgresql://u:p@h/d", app_env=env_name)
        with pytest.raises(RuntimeError, match="APP_SECRET_KEY"):
            build_runtime(settings, sessionmaker, build_registry(), SystemClock())
    test = Settings(database_url="postgresql://u:p@h/d", app_env="test")
    assert build_runtime(test, sessionmaker, build_registry(), FakeClock()).codec is not None


async def test_prod_app_refuses_to_start_without_a_secret_key() -> None:
    app = create_app(Settings(database_url="postgresql://u:p@127.0.0.1:1/x", app_env="prod"))
    with pytest.raises(RuntimeError, match="APP_SECRET_KEY"):
        async with app.router.lifespan_context(app):
            pass
    await asyncio.sleep(0)


async def test_concurrent_logins_cannot_share_one_totp_code(env: Env) -> None:
    body = env.login_body()
    responses = await asyncio.gather(
        *(env.client.post("/auth/login", json=body, headers=SCHEMA) for _ in range(4))
    )
    assert sorted(r.status_code for r in responses) == [200, 401, 401, 401]
    assert error_code(next(r for r in responses if r.status_code == 401)) == "invalid_credentials"
    assert await env.scalar("SELECT count(*) FROM devices") == 1


async def test_created_at_must_be_a_string(env: Env) -> None:
    phone = await env.login()
    op = create_setting(phone)
    op["fields"]["created_at"] = 5
    (result,) = await phone.push_ok([op])
    assert (result["code"], result["message"]) == ("invalid_field", "created_at must be a string")
