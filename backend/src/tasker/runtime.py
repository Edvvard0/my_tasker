"""Process-wide collaborators shared by request handlers (kept on ``app.state.rt``)."""

import secrets
from dataclasses import dataclass
from pathlib import Path

from argon2 import PasswordHasher
from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tasker.auth.crypto import AccessTokenCodec, derive_key
from tasker.auth.passwords import make_hasher
from tasker.clock import Clock
from tasker.config import Settings
from tasker.files.store import DiskFileStore, FileStore
from tasker.sync.notify import ChangeHub
from tasker.sync.registry import SyncRegistry

ACCESS_TTL_SECONDS = 900
REFRESH_TTL_DAYS = 90
SSE_PING_SECONDS = 20.0


@dataclass(slots=True)
class Runtime:
    settings: Settings
    clock: Clock
    sessionmaker: async_sessionmaker[AsyncSession]
    registry: SyncRegistry
    hasher: PasswordHasher
    codec: AccessTokenCodec
    box_key: bytes
    hub: ChangeHub
    sse_ping_seconds: float = SSE_PING_SECONDS
    files: FileStore | None = None


def build_file_store(settings: Settings) -> FileStore | None:
    """The attachment store of the configured ``FILES_DIR`` (``None``: not configured)."""
    return DiskFileStore(Path(settings.files_dir)) if settings.files_dir else None


def build_runtime(
    settings: Settings,
    sessionmaker: async_sessionmaker[AsyncSession],
    registry: SyncRegistry,
    clock: Clock,
) -> Runtime:
    key = settings.app_secret_key
    if key is None:
        if settings.app_env != "test":
            raise RuntimeError("APP_SECRET_KEY is required (tokens and the TOTP secret use it)")
        master = secrets.token_urlsafe(48)  # tests only: an ephemeral key per process
    else:
        master = key.get_secret_value()
    return Runtime(
        settings=settings,
        clock=clock,
        sessionmaker=sessionmaker,
        registry=registry,
        hasher=make_hasher(settings),
        codec=AccessTokenCodec(derive_key(master, "access-token")),
        box_key=derive_key(master, "secret-box"),
        hub=ChangeHub(settings.db_url),
        files=build_file_store(settings),
    )


def get_runtime(request: Request) -> Runtime:
    rt: Runtime = request.app.state.rt
    return rt
