"""Fixtures. Tests run against a real PostgreSQL.

If ``DATABASE_URL`` is set it is used as the *server* (a fresh database is created per test,
so the role needs CREATEDB). Otherwise a throw-away container is started with the docker CLI;
override the image with ``TEST_POSTGRES_IMAGE``.
"""

import asyncio
import os
import secrets
import subprocess
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Iterator
from concurrent.futures import ThreadPoolExecutor

import asyncpg
import pytest
from sqlalchemy.engine import make_url

from tasker.config import Settings
from tasker.db_migrations import upgrade_to_head
from tests.api_support import Env, make_env
from tests.sync_tables import build_test_registry, create_test_tables

DEFAULT_IMAGE = "mirror.gcr.io/library/postgres:17-alpine"


def run_async[T](coro: Awaitable[T]) -> T:
    """Run a coroutine to completion on a private loop in a helper thread."""

    async def wrapper() -> T:
        return await coro

    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, wrapper()).result()


def _dsn(url: str) -> str:
    return make_url(url).set(drivername="postgresql").render_as_string(hide_password=False)


async def _admin_execute(url: str, statement: str) -> None:
    connection = await asyncpg.connect(_dsn(url), timeout=10)
    try:
        await connection.execute(statement)
    finally:
        await connection.close()


async def _wait_for_postgres(url: str, deadline: float) -> None:
    while True:
        try:
            await _admin_execute(url, "SELECT 1")
        except (OSError, asyncpg.PostgresError):
            if time.monotonic() > deadline:
                raise
            await asyncio.sleep(0.3)
        else:
            return


def _docker(*args: str) -> str:
    return subprocess.run(
        ["docker", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


@pytest.fixture(scope="session")
def postgres_server_url() -> Iterator[str]:
    """SQLAlchemy URL of a PostgreSQL server with CREATEDB rights."""
    external = os.environ.get("DATABASE_URL")
    if external:
        yield Settings(database_url=external).db_url
        return

    image = os.environ.get("TEST_POSTGRES_IMAGE", DEFAULT_IMAGE)
    password = secrets.token_urlsafe(16)
    try:
        container = _docker(
            "run", "-d", "--rm", "-p", "127.0.0.1::5432",
            "-e", f"POSTGRES_PASSWORD={password}", image, "-c", "fsync=off",
        )  # fmt: skip
    except (OSError, subprocess.CalledProcessError) as exc:
        pytest.fail(
            "No PostgreSQL for tests: set DATABASE_URL or make `docker run "
            f"{image}` work (override with TEST_POSTGRES_IMAGE). Cause: {exc}"
        )
    try:
        port = _docker("port", container, "5432/tcp").splitlines()[0].rsplit(":", 1)[1]
        url = f"postgresql+asyncpg://postgres:{password}@127.0.0.1:{port}/postgres"
        run_async(_wait_for_postgres(url, time.monotonic() + 60))
        yield url
    finally:
        subprocess.run(["docker", "rm", "-f", container], check=False, capture_output=True)


@pytest.fixture
def db_url(postgres_server_url: str) -> Iterator[str]:
    """URL of a brand-new empty database, dropped after the test."""
    name = f"test_{uuid.uuid4().hex}"
    run_async(_admin_execute(postgres_server_url, f'CREATE DATABASE "{name}"'))
    yield make_url(postgres_server_url).set(database=name).render_as_string(hide_password=False)
    run_async(_admin_execute(postgres_server_url, f'DROP DATABASE "{name}" WITH (FORCE)'))


@pytest.fixture(scope="session")
def template_db_name(postgres_server_url: str) -> Iterator[str]:
    """A database migrated to head once; per-test databases are cheap copies of it."""
    name = f"template_{uuid.uuid4().hex}"
    run_async(_admin_execute(postgres_server_url, f'CREATE DATABASE "{name}"'))
    url = make_url(postgres_server_url).set(database=name).render_as_string(hide_password=False)
    upgrade_to_head(url)
    yield name
    run_async(_admin_execute(postgres_server_url, f'DROP DATABASE "{name}" WITH (FORCE)'))


@pytest.fixture
def migrated_db_url(postgres_server_url: str, template_db_name: str) -> Iterator[str]:
    name = f"test_{uuid.uuid4().hex}"
    run_async(
        _admin_execute(
            postgres_server_url, f'CREATE DATABASE "{name}" TEMPLATE "{template_db_name}"'
        )
    )
    yield make_url(postgres_server_url).set(database=name).render_as_string(hide_password=False)
    run_async(_admin_execute(postgres_server_url, f'DROP DATABASE "{name}" WITH (FORCE)'))


@pytest.fixture
async def env(migrated_db_url: str) -> AsyncIterator[Env]:
    async with make_env(migrated_db_url) as environment:
        yield environment


@pytest.fixture
async def tree_env(migrated_db_url: str) -> AsyncIterator[Env]:
    """Environment whose registry also has the test-only parent/child tables."""
    async with make_env(
        migrated_db_url, registry=build_test_registry(), extra_setup=create_test_tables
    ) as environment:
        yield environment


@pytest.fixture
def _tables(migrated_db_url: str) -> None:
    """The test-only synchronised tables, created in the migrated database."""
    run_async(create_test_tables(migrated_db_url))
