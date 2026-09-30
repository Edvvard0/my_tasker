import pytest
from pydantic import ValidationError

from tasker.config import Settings


def test_plain_postgres_url_gets_asyncpg_driver() -> None:
    assert Settings(database_url="postgresql://u:p@h/d").database_url == (
        "postgresql+asyncpg://u:p@h/d"
    )
    assert (
        Settings(database_url="postgres://u:p@h/d").database_url == "postgresql+asyncpg://u:p@h/d"
    )


def test_asyncpg_url_kept_as_is() -> None:
    url = "postgresql+asyncpg://u:p@h/d"
    assert Settings(database_url=url).database_url == url


def test_env_is_read(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@h/d")
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    settings = Settings()
    assert (settings.app_env, settings.log_level) == ("prod", "DEBUG")


def test_database_url_is_required(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(ValidationError):
        Settings(_env_file=None)
