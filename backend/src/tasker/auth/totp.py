"""RFC 6238 TOTP (SHA-1, 6 digits, 30 s) with replay protection via the last used step."""

import base64
import hashlib
import hmac
import secrets
import struct
from urllib.parse import quote

STEP_SECONDS = 30
DIGITS = 6
WINDOW = 1


def generate_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _decode(secret: str) -> bytes:
    return base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)


def code_for_step(secret: str, step: int) -> str:
    digest = hmac.new(_decode(secret), struct.pack(">Q", step), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    number = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFF_FFFF
    return str(number % 10**DIGITS).zfill(DIGITS)


def current_step(unix_time: float) -> int:
    return int(unix_time // STEP_SECONDS)


def verify(secret: str, code: str, unix_time: float, last_step: int) -> int | None:
    """Return the matching time step, or ``None``. Steps <= ``last_step`` are replays."""
    if len(code) != DIGITS or not code.isascii() or not code.isdigit():
        return None
    center = current_step(unix_time)
    for step in range(center - WINDOW, center + WINDOW + 1):
        if step > last_step and hmac.compare_digest(code_for_step(secret, step), code):
            return step
    return None


def otpauth_uri(secret: str, *, issuer: str = "My Tasker", account: str = "owner") -> str:
    label = quote(f"{issuer}:{account}")
    return (
        f"otpauth://totp/{label}?secret={secret}&issuer={quote(issuer)}"
        f"&algorithm=SHA1&digits={DIGITS}&period={STEP_SECONDS}"
    )
