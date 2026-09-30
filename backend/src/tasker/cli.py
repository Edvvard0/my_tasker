"""Owner administration on the server: ``python -m tasker.cli user create|reset``."""

import argparse
import asyncio
import getpass
import sys
from collections.abc import Sequence

from tasker.auth.passwords import MIN_PASSWORD_LENGTH
from tasker.auth.service import upsert_owner
from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.runtime import build_runtime
from tasker.sync.modules import build_registry


def _read_password(from_stdin: bool) -> str:
    if from_stdin:
        return sys.stdin.readline().rstrip("\r\n")
    first = getpass.getpass("New password: ")
    if getpass.getpass("Repeat password: ") != first:
        raise SystemExit("Passwords do not match")
    return first


async def _run(settings: Settings, password: str, *, replace: bool) -> str:
    engine = create_engine(settings)
    try:
        sessionmaker = create_sessionmaker(engine)
        rt = build_runtime(settings, sessionmaker, build_registry(), SystemClock())
        async with sessionmaker() as session:
            enrollment = await upsert_owner(rt, session, password=password, replace=replace)
        return enrollment.otpauth_uri
    finally:
        await engine.dispose()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tasker.cli")
    commands = parser.add_subparsers(dest="group", required=True)
    user = commands.add_parser("user", help="manage the single owner account")
    actions = user.add_subparsers(dest="action", required=True)
    for name, text in (
        ("create", "create the owner"),
        ("reset", "new password and TOTP secret; revokes every device"),
    ):
        action = actions.add_parser(name, help=text)
        action.add_argument(
            "--password-stdin", action="store_true", help="read the password from stdin"
        )
    args = parser.parse_args(argv)

    settings = Settings()
    if settings.app_secret_key is None:
        print("APP_SECRET_KEY must be set: the TOTP secret is encrypted with it", file=sys.stderr)
        return 2
    password = _read_password(args.password_stdin)
    if len(password) < MIN_PASSWORD_LENGTH:
        print(f"Password must be at least {MIN_PASSWORD_LENGTH} characters", file=sys.stderr)
        return 2
    try:
        uri = asyncio.run(_run(settings, password, replace=args.action == "reset"))
    except (FileExistsError, LookupError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("Add this to your authenticator app. It is shown only once:")
    print(uri)
    return 0


if __name__ == "__main__":
    sys.exit(main())
