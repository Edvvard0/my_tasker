from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import httpx

from tasker.config import Settings
from tasker.main import create_app


@asynccontextmanager
async def app_client(settings: Settings) -> AsyncIterator[httpx.AsyncClient]:
    """HTTP client bound to a fresh app with its lifespan running."""
    app = create_app(settings)
    async with (
        app.router.lifespan_context(app),
        httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client,
    ):
        yield client


def make_settings(url: str) -> Settings:
    return Settings(database_url=url, app_env="test", log_level="WARNING")
