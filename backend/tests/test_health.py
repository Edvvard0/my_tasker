import asyncio
import time

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


async def test_ready_503_within_timeout_when_database_accepts_but_never_answers() -> None:
    # A DB that completes the TCP handshake and then says nothing (hung server, half-open
    # network): the readiness probe must still answer 503 in about ready_timeout.
    connections: list[asyncio.StreamWriter] = []

    async def hang(_reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        connections.append(writer)
        await asyncio.sleep(3600)

    server = await asyncio.start_server(hang, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    settings = make_settings(f"postgresql+asyncpg://user:pw@127.0.0.1:{port}/none").model_copy(
        update={"ready_timeout": 0.5}
    )
    try:
        async with app_client(settings) as client:
            started = time.perf_counter()
            response = await asyncio.wait_for(client.get("/health/ready"), timeout=5)
            elapsed = time.perf_counter() - started
    finally:
        for writer in connections:
            writer.close()
        server.close()
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable", "reason": "database_unavailable"}
    assert 0.4 <= elapsed < 3
    assert connections, "the probe never reached the fake database"
