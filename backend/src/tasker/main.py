from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI

from tasker.ai import api as ai_api
from tasker.ai.runtime import AiRuntime
from tasker.api import health, version
from tasker.auth import api as auth_api
from tasker.banks import api as banks_api
from tasker.clock import Clock, SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.errors import install_error_handlers
from tasker.files import api as files_api
from tasker.logging import configure_logging
from tasker.middleware import RequestIdMiddleware
from tasker.runtime import build_runtime
from tasker.sync import api as sync_api
from tasker.sync.modules import build_registry
from tasker.sync.registry import SyncRegistry
from tasker.version import APP_VERSION


def create_app(
    settings: Settings | None = None,
    *,
    registry: SyncRegistry | None = None,
    clock: Clock | None = None,
) -> FastAPI:
    settings = settings or Settings()
    configure_logging(
        settings.log_level,
        redact=[settings.polza_api_key.get_secret_value()] if settings.polza_api_key else [],
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = create_engine(settings)
        sessionmaker = create_sessionmaker(engine)
        runtime = build_runtime(
            settings, sessionmaker, registry or build_registry(), clock or SystemClock()
        )
        app.state.settings = settings
        app.state.sessionmaker = sessionmaker
        app.state.rt = runtime
        app.state.ai = ai_runtime = AiRuntime(settings, runtime.clock)
        structlog.get_logger().info("api_started", app_env=settings.app_env)
        try:
            yield
        finally:
            await ai_runtime.aclose()
            await runtime.hub.close()
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
    install_error_handlers(app)
    app.include_router(health.router)
    app.include_router(version.router)
    app.include_router(auth_api.router)
    app.include_router(sync_api.router)
    app.include_router(ai_api.router)
    app.include_router(banks_api.router)
    app.include_router(files_api.router)
    return app
