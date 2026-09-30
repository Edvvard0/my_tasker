import asyncio

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.db_migrations import head_revision
from tests.support import app_client, make_settings

# Nothing listens on port 1, so connecting fails immediately.
UNREACHABLE_URL = "postgresql+asyncpg://user:pw@127.0.0.1:1/none"


async def test_live_does_not_need_database() -> None:
    async with app_client(make_settings(UNREACHABLE_URL)) as client:
        response = await client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_ready_ok_when_migrated(migrated_db_url: str) -> None:
    async with app_client(make_settings(migrated_db_url)) as client:
        response = await client.get("/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_ready_503_when_database_down() -> None:
    async with app_client(make_settings(UNREACHABLE_URL)) as client:
        response = await client.get("/health/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable", "reason": "database_unavailable"}


async def test_ready_503_when_migrations_not_applied(db_url: str) -> None:
    async with app_client(make_settings(db_url)) as client:
        response = await client.get("/health/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable", "reason": "migrations_not_applied"}


async def test_ready_503_when_alembic_not_at_head(migrated_db_url: str) -> None:
    engine = create_async_engine(migrated_db_url)
    async with engine.begin() as connection:
        await connection.execute(text("UPDATE alembic_version SET version_num = 'stale'"))
    await engine.dispose()
    assert head_revision() != "stale"
    async with app_client(make_settings(migrated_db_url)) as client:
        response = await client.get("/health/ready")
    assert response.status_code == 503
    assert response.json()["reason"] == "migrations_not_applied"


async def test_ready_503_on_timeout(migrated_db_url: str) -> None:
    settings = make_settings(migrated_db_url).model_copy(update={"ready_timeout": 0.000001})
    async with app_client(settings) as client:
        response = await client.get("/health/ready")
    assert response.status_code == 503
    assert response.json()["reason"] == "database_unavailable"
    await asyncio.sleep(0)
