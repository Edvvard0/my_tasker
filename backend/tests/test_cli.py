import asyncio
import getpass
import io
import re
import sys

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import create_async_engine

from tasker import cli
from tasker.auth.crypto import decrypt_secret, derive_key
from tasker.db_migrations import upgrade_to_head

SECRET_KEY = "k" * 48
PASSWORD = "a very long password"


@pytest.fixture
def cli_db(db_url: str, monkeypatch: pytest.MonkeyPatch) -> str:
    upgrade_to_head(db_url)
    monkeypatch.setenv("DATABASE_URL", db_url)
    monkeypatch.setenv("APP_SECRET_KEY", SECRET_KEY)
    monkeypatch.setenv("LOG_LEVEL", "WARNING")
    return db_url


def query(url: str, statement: str) -> list[sa.Row[tuple[object, ...]]]:
    async def run() -> list[sa.Row[tuple[object, ...]]]:
        engine = create_async_engine(url)
        try:
            async with engine.begin() as connection:
                result = await connection.execute(sa.text(statement))
                return list(result) if result.returns_rows else []
        finally:
            await engine.dispose()

    return asyncio.run(run())


def use_stdin(monkeypatch: pytest.MonkeyPatch, text: str) -> None:
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))


def test_create_prints_the_enrollment_uri_once(
    cli_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    use_stdin(monkeypatch, PASSWORD + "\n")
    assert cli.main(["user", "create", "--password-stdin"]) == 0
    out = capsys.readouterr().out
    uri = re.search(r"otpauth://totp/\S+", out)
    assert uri
    secret = re.search(r"secret=([A-Z2-7]+)", uri.group(0))
    assert secret
    (user,) = query(cli_db, "SELECT password_hash, totp_secret_enc FROM users")
    assert user.password_hash.startswith("$argon2id$")
    assert PASSWORD not in user.password_hash
    assert secret.group(1) not in user.totp_secret_enc  # encrypted at rest
    key = derive_key(SECRET_KEY, "secret-box")
    assert decrypt_secret(key, user.totp_secret_enc, context="totp-secret") == secret.group(1)


def test_create_twice_fails(
    cli_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    use_stdin(monkeypatch, PASSWORD + "\n")
    assert cli.main(["user", "create", "--password-stdin"]) == 0
    use_stdin(monkeypatch, "another long password\n")
    assert cli.main(["user", "create", "--password-stdin"]) == 1
    assert "already exists" in capsys.readouterr().err
    assert len(query(cli_db, "SELECT 1 FROM users")) == 1


def test_reset_needs_an_existing_owner(
    cli_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    use_stdin(monkeypatch, PASSWORD + "\n")
    assert cli.main(["user", "reset", "--password-stdin"]) == 1
    assert "no owner" in capsys.readouterr().err


def test_reset_replaces_credentials_and_revokes_devices(
    cli_db: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    use_stdin(monkeypatch, PASSWORD + "\n")
    cli.main(["user", "create", "--password-stdin"])
    old = query(cli_db, "SELECT password_hash, totp_secret_enc FROM users")[0]
    query(
        cli_db,
        "INSERT INTO devices (id, name, platform, created_at, last_seen_at, refresh_token_hash,"
        " refresh_expires_at) VALUES (gen_random_uuid(), 'd', 'other', now(), now(), 'x', now())",
    )
    use_stdin(monkeypatch, "brand new long password\n")
    assert cli.main(["user", "reset", "--password-stdin"]) == 0
    new = query(cli_db, "SELECT password_hash, totp_secret_enc FROM users")[0]
    assert (new.password_hash, new.totp_secret_enc) != (old.password_hash, old.totp_secret_enc)
    (device,) = query(cli_db, "SELECT revoked_at, revoked_reason FROM devices")
    assert (device.revoked_at is not None, device.revoked_reason) == (True, "password_reset")


def test_short_password_is_refused(
    cli_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    use_stdin(monkeypatch, "short\n")
    assert cli.main(["user", "create", "--password-stdin"]) == 2
    assert "at least 12" in capsys.readouterr().err
    assert query(cli_db, "SELECT 1 FROM users") == []


def test_secret_key_is_required(
    cli_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("APP_SECRET_KEY")
    use_stdin(monkeypatch, PASSWORD + "\n")
    assert cli.main(["user", "create", "--password-stdin"]) == 2
    assert "APP_SECRET_KEY" in capsys.readouterr().err


def test_interactive_prompt_and_mismatch(cli_db: str, monkeypatch: pytest.MonkeyPatch) -> None:
    answers = iter([PASSWORD, "different long password"])
    monkeypatch.setattr(getpass, "getpass", lambda _prompt: next(answers))
    with pytest.raises(SystemExit, match="do not match"):
        cli.main(["user", "create"])
    answers = iter([PASSWORD, PASSWORD])
    assert cli.main(["user", "create"]) == 0
    assert len(query(cli_db, "SELECT 1 FROM users")) == 1


def test_only_one_owner_row_can_exist(cli_db: str) -> None:
    insert = (
        "INSERT INTO users (id, password_hash, totp_secret_enc, created_at, updated_at)"
        " VALUES (gen_random_uuid(), 'h', 's', now(), now())"
    )
    query(cli_db, insert)
    with pytest.raises(sa.exc.IntegrityError):
        query(cli_db, insert)
