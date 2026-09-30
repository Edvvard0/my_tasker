from typing import Literal

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

MIN_SECRET_KEY_LENGTH = 32


class Settings(BaseSettings):
    """Runtime configuration, read from environment variables only.

    Every secret is a ``SecretStr`` so it never shows up in ``repr``/``str``/logs; unwrap it
    with ``get_secret_value()`` only at the point of use.
    """

    model_config = SettingsConfigDict(extra="ignore")

    database_url: SecretStr
    # Defaults to prod: a forgotten variable must never expose /docs and /openapi.json.
    app_env: Literal["dev", "test", "prod"] = "prod"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    db_connect_timeout: float = Field(default=5.0, gt=0)
    ready_timeout: float = Field(default=5.0, gt=0)

    # Signs access tokens and (via HKDF) encrypts the TOTP secret. Required in prod for the api.
    app_secret_key: SecretStr | None = None
    # Trust the first X-Forwarded-For entry as the client address (api sits behind Caddy).
    trust_forwarded_for: bool = False
    # argon2id cost; the defaults follow the OWASP minimum. Tests lower them.
    argon2_memory_kib: int = Field(default=19456, ge=8)
    argon2_time_cost: int = Field(default=2, ge=1)
    argon2_parallelism: int = Field(default=1, ge=1)

    @field_validator("database_url", mode="before")
    @classmethod
    def _use_asyncpg_driver(cls, value: object) -> object:
        """Accept plain ``postgresql://`` URLs and force the asyncpg driver."""
        raw = value.get_secret_value() if isinstance(value, SecretStr) else value
        if isinstance(raw, str):
            for prefix in ("postgresql://", "postgres://"):
                if raw.startswith(prefix):
                    return "postgresql+asyncpg://" + raw[len(prefix) :]
        return raw

    @field_validator("app_secret_key")
    @classmethod
    def _secret_key_long_enough(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None and len(value.get_secret_value()) < MIN_SECRET_KEY_LENGTH:
            raise ValueError(f"app_secret_key must be at least {MIN_SECRET_KEY_LENGTH} characters")
        return value

    @property
    def db_url(self) -> str:
        """The database URL including the password: for engines and alembic only."""
        return self.database_url.get_secret_value()
