from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import Field, SecretStr, ValidationInfo, field_validator
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
    # Trust the LAST X-Forwarded-For entry as the client address: the api sits behind Caddy, which
    # replaces whatever the client sent with the address it saw. Entries to its left are
    # client-controlled and never used.
    trust_forwarded_for: bool = False
    # argon2id cost; the defaults follow the OWASP minimum. Tests lower them.
    argon2_memory_kib: int = Field(default=19456, ge=8)
    argon2_time_cost: int = Field(default=2, ge=1)
    argon2_parallelism: int = Field(default=1, ge=1)

    # AI chat (stage 3). The key exists only in the server environment: never log or return it.
    polza_base_url: str = "https://polza.ai/api/v1"
    polza_api_key: SecretStr | None = None
    polza_connect_timeout: float = Field(default=5.0, gt=0)
    polza_first_byte_timeout: float = Field(default=60.0, gt=0)
    polza_idle_timeout: float = Field(default=60.0, gt=0)
    polza_total_timeout: float = Field(default=600.0, gt=0)
    polza_max_retries: int = Field(default=2, ge=0, le=5)
    polza_retry_backoff: float = Field(default=0.5, ge=0)
    polza_models_ttl_seconds: float = Field(default=3600.0, ge=0)
    ai_max_tool_iterations: int = Field(default=5, ge=1, le=20)
    ai_billing_timezone: str = "Europe/Moscow"
    ai_sse_ping_seconds: float = Field(default=15.0, gt=0)

    # Banks (stage 6): the largest statement file the api accepts and parses (nothing is stored).
    banks_statement_max_bytes: int = Field(default=10 * 1024 * 1024, ge=1024)

    # Attachments (stage 7): directory of the file store (a separate volume on the server) and the
    # largest file. Without FILES_DIR the file endpoints answer `files_not_configured`.
    files_dir: str | None = None
    files_max_bytes: int = Field(default=25 * 1024 * 1024, ge=1)

    @field_validator("polza_api_key", "polza_base_url", "files_dir", mode="before")
    @classmethod
    def _blank_means_unset(cls, value: object, info: ValidationInfo) -> object:
        """An empty variable (``POLZA_API_KEY=`` in compose) means "not configured"/default."""
        if isinstance(value, str) and not value.strip():
            if info.field_name in ("polza_api_key", "files_dir"):
                return None
            return "https://polza.ai/api/v1"
        return value

    @field_validator("ai_billing_timezone")
    @classmethod
    def _known_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("ai_billing_timezone must be an IANA time zone") from exc
        return value

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
