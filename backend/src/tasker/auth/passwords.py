import asyncio

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from tasker.config import Settings

MIN_PASSWORD_LENGTH = 12


def make_hasher(settings: Settings) -> PasswordHasher:
    return PasswordHasher(
        time_cost=settings.argon2_time_cost,
        memory_cost=settings.argon2_memory_kib,
        parallelism=settings.argon2_parallelism,
    )


async def hash_password(hasher: PasswordHasher, password: str) -> str:
    return await asyncio.to_thread(hasher.hash, password)


async def verify_password(hasher: PasswordHasher, stored_hash: str | None, password: str) -> bool:
    """Constant-work check: a dummy hash is verified when there is no user."""
    target = stored_hash or _dummy_hash(hasher)
    try:
        ok = await asyncio.to_thread(hasher.verify, target, password)
    except (VerificationError, InvalidHashError):
        return False
    return ok and stored_hash is not None


_DUMMY: dict[int, str] = {}


def _dummy_hash(hasher: PasswordHasher) -> str:
    key = id(hasher)
    if key not in _DUMMY:
        _DUMMY[key] = hasher.hash("dummy-password-for-timing")
    return _DUMMY[key]
