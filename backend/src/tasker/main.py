from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI

from tasker.api import health, version
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.logging import configure_logging
from tasker.middleware import RequestIdMiddleware
from tasker.version import APP_VERSION


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    configure_logging(settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = create_engine(settings)
        app.state.settings = settings
        app.state.sessionmaker = create_sessionmaker(engine)
        structlog.get_logger().info("api_started", app_env=settings.app_env)
        try:
            yield
        finally:
            await engine.dispose()

    prod = settings.app_env == "prod"
    app = FastAPI(
        title="My Tasker",
        version=APP_VERSION,
        lifespan=lifespan,
        docs_url=None if prod else "/docs",
        redoc_url=None,
        openapi_url=None if prod else "/openapi.json",
    )
    app.add_middleware(RequestIdMiddleware)
    app.include_router(health.router)
    app.include_router(version.router)
    return app
