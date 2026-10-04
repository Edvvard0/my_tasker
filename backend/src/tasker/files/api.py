"""File endpoints of Stage 7: ``PUT`` and ``GET /files/{attachment_id}`` (spec stage7, section 7).

The content of an attachment lives outside the synchronised tables; the row of ``attachments``
(size, SHA-256, type) is created and synchronised first and says what the upload must be.
"""

import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass
from urllib.parse import quote

import sqlalchemy as sa
from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from tasker.auth.deps import DeviceDep, RuntimeDep, require_schema_version
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.files.magic import HEAD_BYTES, NEEDED, looks_like
from tasker.files.store import FileStore, StoreError
from tasker.runtime import Runtime
from tasker.study.tables import attachments, study_debts, study_subjects
from tasker.uploads import capped_body, declared_length, too_large

router = APIRouter(tags=["files"], dependencies=[Depends(require_schema_version)])


@dataclass(frozen=True, slots=True)
class Meta:
    id: uuid.UUID
    file_name: str
    mime_type: str
    size_bytes: int
    sha256: str


def _store(rt: Runtime) -> FileStore:
    if rt.files is None:
        raise ApiError(503, "files_not_configured", "File storage is not configured")
    return rt.files


async def _visible_meta(session: SessionDep, attachment_id: uuid.UUID) -> Meta:
    """The metadata of a live attachment whose owner chain is live; else 404 (a hidden or unknown
    file looks the same: nothing says it ever existed)."""
    a, s, d = attachments.table, study_subjects.table, study_debts.table
    debt_subject = sa.select(d.c.id).join(s, s.c.id == d.c.subject_id)
    query = sa.select(a).where(
        a.c.id == attachment_id,
        a.c.deleted_at.is_(None),
        sa.or_(
            a.c.subject_id.in_(sa.select(s.c.id).where(s.c.deleted_at.is_(None))),
            a.c.debt_id.in_(debt_subject.where(s.c.deleted_at.is_(None), d.c.deleted_at.is_(None))),
        ),
    )
    async with session.begin():
        row = (await session.execute(query)).mappings().first()
    if row is None:
        raise ApiError(404, "attachment_not_found", "No such attachment")
    return Meta(row["id"], row["file_name"], row["mime_type"], row["size_bytes"], row["sha256"])


async def _checked(chunks: AsyncIterator[bytes], mime: str) -> AsyncIterator[bytes]:
    """Pass the chunks through once the first bytes proved to fit the declared type."""
    need = HEAD_BYTES if mime == "application/pdf" else NEEDED  # a PDF marker may sit anywhere
    held: list[bytes] = []  # not yet released: the head is incomplete
    size = 0
    verified = False
    async for chunk in chunks:
        if verified:
            yield chunk
            continue
        held.append(chunk)
        size += len(chunk)
        if size >= need:
            _require_type(mime, b"".join(held))
            verified = True
            for part in held:
                yield part
    if not verified:  # a short file: judge what there is
        _require_type(mime, b"".join(held))
        for part in held:
            yield part


def _require_type(mime: str, head: bytes) -> None:
    if not looks_like(mime, head):
        raise ApiError(415, "content_type_mismatch", "The file does not look like its type")


@router.put("/files/{attachment_id}")
async def upload(
    attachment_id: uuid.UUID, request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> Response:
    store = _store(rt)
    meta = await _visible_meta(session, attachment_id)
    limit = rt.settings.files_max_bytes
    if meta.size_bytes > limit:
        raise too_large(limit)
    declared = declared_length(request)
    if declared is not None and declared != meta.size_bytes:
        raise ApiError(
            422,
            "size_mismatch",
            "The upload size differs from the attachment size",
            details={"expected": meta.size_bytes, "received": declared},
        )
    if await store.size(attachment_id) == meta.size_bytes:
        return JSONResponse({"status": "exists", "size": meta.size_bytes})
    body = _checked(capped_body(request, meta.size_bytes), meta.mime_type)
    try:
        await store.put(attachment_id, body, size=meta.size_bytes, sha256=meta.sha256)
    except StoreError as exc:
        raise ApiError(422, exc.code, exc.message) from exc
    return JSONResponse({"status": "stored", "size": meta.size_bytes}, status_code=201)


def _disposition(name: str) -> str:
    ascii_name = "".join(
        c if c.isascii() and c.isprintable() and c not in r'"\;' else "_" for c in name
    )
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name, safe='')}"


@router.get("/files/{attachment_id}")
async def download(
    attachment_id: uuid.UUID, request: Request, _: DeviceDep, session: SessionDep, rt: RuntimeDep
) -> Response:
    store = _store(rt)
    meta = await _visible_meta(session, attachment_id)
    if await store.size(attachment_id) != meta.size_bytes:
        raise ApiError(404, "file_not_uploaded", "The file content is not on the server yet")
    etag = f'"{meta.sha256}"'
    headers = {
        "ETag": etag,
        "Cache-Control": "private, no-cache",
        "X-Content-Type-Options": "nosniff",
        "Content-Disposition": _disposition(meta.file_name),
        "Content-Length": str(meta.size_bytes),
    }
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers={k: headers[k] for k in ("ETag", "Cache-Control")})
    return StreamingResponse(store.read(attachment_id), media_type=meta.mime_type, headers=headers)
