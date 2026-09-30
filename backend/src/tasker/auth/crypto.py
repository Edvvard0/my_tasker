"""Key derivation, secret-at-rest encryption and access/refresh token formats."""

import base64
import hashlib
import hmac
import json
import os
import uuid
from dataclasses import dataclass
from datetime import datetime

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


class TokenError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def derive_key(master: str, purpose: str) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(), length=32, salt=None, info=f"my-tasker:{purpose}".encode()
    ).derive(master.encode())


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def encrypt_secret(key: bytes, plaintext: str, *, context: str) -> str:
    nonce = os.urandom(12)
    sealed = AESGCM(key).encrypt(nonce, plaintext.encode(), context.encode())
    return _b64(nonce + sealed)


def decrypt_secret(key: bytes, token: str, *, context: str) -> str:
    raw = _unb64(token)
    return AESGCM(key).decrypt(raw[:12], raw[12:], context.encode()).decode()


@dataclass(frozen=True, slots=True)
class TokenClaims:
    device_id: uuid.UUID
    issued_ms: int  # 0 when the token carries no issue time


class AccessTokenCodec:
    """Stateless HMAC-signed access tokens ``at1.<payload>.<signature>``."""

    def __init__(self, key: bytes) -> None:
        self._key = key

    def _sign(self, payload: str) -> str:
        return _b64(hmac.new(self._key, payload.encode(), hashlib.sha256).digest())

    def issue(self, device_id: uuid.UUID, now: datetime, expires_at: datetime) -> str:
        body = json.dumps(
            {
                "d": str(device_id),
                "i": int(now.timestamp()),
                "t": int(now.timestamp() * 1000),
                "e": int(expires_at.timestamp()),
            },
            separators=(",", ":"),
        )
        payload = _b64(body.encode())
        return f"at1.{payload}.{self._sign(payload)}"

    def verify(self, token: str, now: datetime) -> uuid.UUID:
        return self.verify_claims(token, now).device_id

    def verify_claims(self, token: str, now: datetime) -> TokenClaims:
        parts = token.split(".")
        if len(parts) != 3 or parts[0] != "at1":
            raise TokenError("invalid_token")
        # Compare bytes: ``compare_digest`` refuses non-ASCII ``str`` (a hostile header).
        if not hmac.compare_digest(self._sign(parts[1]).encode(), parts[2].encode()):
            raise TokenError("invalid_token")
        try:
            claims = json.loads(_unb64(parts[1]))
            device_id = uuid.UUID(claims["d"])
            expires = int(claims["e"])
            issued_ms = int(claims.get("t") or int(claims.get("i") or 0) * 1000)
        except (ValueError, KeyError, TypeError, AttributeError) as exc:
            raise TokenError("invalid_token") from exc
        if now.timestamp() >= expires:
            raise TokenError("token_expired")
        return TokenClaims(device_id, issued_ms)


def new_refresh_token(device_id: uuid.UUID) -> str:
    return f"rt1.{device_id.hex}.{_b64(os.urandom(32))}"


def parse_refresh_token(token: str) -> uuid.UUID:
    parts = token.split(".")
    if not token.isascii() or len(parts) != 3 or parts[0] != "rt1" or len(parts[2]) < 32:
        raise TokenError("invalid_refresh_token")
    try:
        return uuid.UUID(hex=parts[1])
    except ValueError as exc:
        raise TokenError("invalid_refresh_token") from exc


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
