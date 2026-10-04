"""Request bodies read with a size cap (statement parsing and file upload)."""

from collections.abc import AsyncIterator

from fastapi import Request
from starlette.requests import ClientDisconnect

from tasker.errors import ApiError


def declared_length(request: Request) -> int | None:
    raw = request.headers.get("content-length", "")
    return int(raw) if raw.isascii() and raw.isdigit() else None


def too_large(limit: int) -> ApiError:
    return ApiError(
        413,
        "payload_too_large",
        f"The upload is larger than {limit} bytes",
        details={"max_bytes": limit},
    )


async def capped_body(request: Request, limit: int) -> AsyncIterator[bytes]:
    """The body in chunks; more than ``limit`` bytes -> 413 (checked on the declared length first
    and again while reading); a client that hangs up -> ``upload_interrupted``."""
    declared = declared_length(request)
    if declared is not None and declared > limit:
        raise too_large(limit)
    total = 0
    try:
        async for chunk in request.stream():
            total += len(chunk)
            if total > limit:
                raise too_large(limit)
            yield chunk
    except ClientDisconnect as exc:
        raise ApiError(400, "upload_interrupted", "The upload was interrupted") from exc


async def read_capped(request: Request, limit: int) -> bytes:
    return b"".join([chunk async for chunk in capped_body(request, limit)])
