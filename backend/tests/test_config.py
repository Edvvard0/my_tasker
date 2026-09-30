import pytest
from pydantic import ValidationError

from tasker.config import Settings


def test_plain_postgres_url_gets_asyncpg_driver() -> None:
    assert Settings(database_url="postgresql://u:p@h/d").db_url == "postgresql+asyncpg://u:p@h/d"
    assert Settings(database_url="postgres://u:p@h/d").db_url == "postgresql+asyncpg://u:p@h/d"


def test_asyncpg_url_kept_as_is() -> None:
    url = "postgresql+asyncpg://u:p@h/d"
    assert Settings(database_url=url).db_url == url


def test_env_is_read(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@h/d")
    monkeypatch.setenv("APP_ENV", "dev")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    settings = Settings()
    assert (settings.app_env, settings.log_level) == ("dev", "DEBUG")


def test_app_env_defaults_to_prod(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("APP_ENV", raising=False)
    assert Settings(database_url="postgresql://u:p@h/d", _env_file=None).app_env == "prod"


def test_database_url_is_required(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(ValidationError):
        Settings(_env_file=None)


def test_secrets_do_not_leak_through_repr_or_str() -> None:
    settings = Settings(
        database_url="postgresql://user:hunter2pw@h/d",
        app_secret_key="k" * 40,
    )
    for text in (repr(settings), str(settings), repr(settings.database_url)):
        assert "hunter2pw" not in text
        assert "k" * 40 not in text


def test_secret_key_must_be_long_enough() -> None:
    with pytest.raises(ValidationError, match="at least"):
        Settings(database_url="postgresql://u:p@h/d", app_secret_key="short")
