"""Server administration: ``tasker.cli user create|reset|unlock`` and ``epoch show|rotate``."""

import argparse
import asyncio
import getpass
import json
import sys
from collections.abc import Awaitable, Callable, Sequence

from sqlalchemy.ext.asyncio import AsyncSession

from tasker.auth import lockout
from tasker.auth.passwords import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH
from tasker.auth.service import upsert_owner
from tasker.clock import SystemClock
from tasker.config import Settings
from tasker.db import create_engine, create_sessionmaker
from tasker.epoch import read_epoch, rotate_epoch
from tasker.runtime import build_runtime
from tasker.sync.modules import build_registry
from tasker.textcheck import is_storable_text


def _read_password(from_stdin: bool) -> str:
    if from_stdin:
        return sys.stdin.readline().rstrip("\r\n")
    first = getpass.getpass("New password: ")
    if getpass.getpass("Repeat password: ") != first:
        raise SystemExit("Passwords do not match")
    return first


def _password_problem(password: str) -> str | None:
    """Same rules as the login API, so a password set here can always be used to sign in."""
    if len(password) < MIN_PASSWORD_LENGTH:
        return f"Password must be at least {MIN_PASSWORD_LENGTH} characters"
    if len(password) > MAX_PASSWORD_LENGTH:
        return f"Password must be at most {MAX_PASSWORD_LENGTH} characters"
    if not is_storable_text(password):
        return "Password must not contain NUL or unpaired surrogates"
    return None


async def _with_session[T](settings: Settings, work: Callable[[AsyncSession], Awaitable[T]]) -> T:
    engine = create_engine(settings)
    try:
        async with create_sessionmaker(engine)() as session:
            return await work(session)
    finally:
        await engine.dispose()


async def _set_owner(settings: Settings, password: str, *, replace: bool) -> tuple[str, str]:
    engine = create_engine(settings)
    try:
        sessionmaker = create_sessionmaker(engine)
        rt = build_runtime(settings, sessionmaker, build_registry(), SystemClock())
        async with sessionmaker() as session:
            enrollment = await upsert_owner(rt, session, password=password, replace=replace)
        return enrollment.otpauth_uri, enrollment.totp_secret
    finally:
        await engine.dispose()


async def _unlock(session: AsyncSession) -> int:
    async with session.begin():
        return await lockout.clear_all(session)


async def _epoch(session: AsyncSession, *, rotate: bool) -> str:
    async with session.begin():
        if rotate:
            return await rotate_epoch(session, SystemClock().now())
        return await read_epoch(session)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tasker.cli")
    commands = parser.add_subparsers(dest="group", required=True)
    user = commands.add_parser("user", help="manage the single owner account")
    actions = user.add_subparsers(dest="action", required=True)
    for name, text in (
        ("create", "create the owner"),
        ("reset", "new password and TOTP secret; revokes every device, clears login locks"),
    ):
        action = actions.add_parser(name, help=text)
        action.add_argument(
            "--password-stdin", action="store_true", help="read the password from stdin"
        )
        action.add_argument(
            "--json",
            action="store_true",
            help='print {"otpauth_uri", "totp_secret"} as JSON (for scripts)',
        )
    actions.add_parser("unlock", help="lift every login lock and reset the failure counters")
    epoch = commands.add_parser("epoch", help="the server epoch clients use to detect a restore")
    epoch_actions = epoch.add_subparsers(dest="action", required=True)
    epoch_actions.add_parser("show", help="print the current epoch")
    epoch_actions.add_parser(
        "rotate", help="new epoch: run after restoring a dump, every device resyncs fully"
    )
    return parser


def _owner_command(settings: Settings, args: argparse.Namespace) -> int:
    if settings.app_secret_key is None:
        print("APP_SECRET_KEY must be set: the TOTP secret is encrypted with it", file=sys.stderr)
        return 2
    password = _read_password(args.password_stdin)
    problem = _password_problem(password)
    if problem is not None:
        print(problem, file=sys.stderr)
        return 2
    try:
        uri, secret = asyncio.run(_set_owner(settings, password, replace=args.action == "reset"))
    except (FileExistsError, LookupError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"otpauth_uri": uri, "totp_secret": secret}))
    else:
        print("Add this to your authenticator app. It is shown only once:")
        print(uri)
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    settings = Settings()
    if args.group == "epoch":
        print(
            asyncio.run(
                _with_session(settings, lambda s: _epoch(s, rotate=args.action == "rotate"))
            )
        )
        return 0
    if args.action == "unlock":
        cleared = asyncio.run(_with_session(settings, _unlock))
        print(f"Login locks lifted ({cleared} counters cleared)")
        return 0
    return _owner_command(settings, args)


if __name__ == "__main__":
    sys.exit(main())
