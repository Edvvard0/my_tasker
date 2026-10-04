"""PUT/GET /files/{attachment_id}: upload, download, repeats, interruptions, limits, access."""

import asyncio
import os
import re
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import pytest

from tasker.ids import uuid7
from tests.api_support import SCHEMA, DeviceClient, Env, make_env
from tests.study_support import (
    JPEG,
    PDF,
    PNG,
    TEXT,
    StudySeed,
    attachment_fields,
    file_meta,
    study_seed,
)

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8 " + b"w" * 40
HEIC = b"\x00\x00\x00\x18ftypheic" + b"h" * 40
OLE = bytes.fromhex("d0cf11e0a1b11ae1") + b"o" * 40
ZIP = b"PK\x03\x04" + b"z" * 60


def files_on_disk(root: Path) -> list[str]:
    return sorted(f for _, _, names in os.walk(root) for f in names)


@pytest.fixture
async def fenv(migrated_db_url: str, tmp_path: Path) -> AsyncIterator[Env]:
    async with make_env(migrated_db_url, files_dir=str(tmp_path / "files")) as environment:
        yield environment


@pytest.fixture
def root(tmp_path: Path) -> Path:
    return tmp_path / "files"


@pytest.fixture
async def phone(fenv: Env) -> DeviceClient:
    return await fenv.login()


@pytest.fixture
async def seed(phone: DeviceClient) -> StudySeed:
    return await study_seed(phone)


async def attach(dc: DeviceClient, seed: StudySeed, data: bytes = JPEG, **over: Any) -> uuid.UUID:
    """A synchronised attachment row (the precondition of an upload)."""
    owner: dict[str, Any] = (
        {"debt": seed.debt_lab} if over.pop("on_debt", False) else {"subject": seed.math}
    )
    attachment = uuid7()
    (result,) = await dc.push_ok(
        [dc.op("attachments", attachment, fields=attachment_fields(dc, data, **owner, **over))]
    )
    assert result["status"] == "applied", result
    return attachment


async def put(dc: DeviceClient, attachment: uuid.UUID, data: bytes | AsyncIterator[bytes]) -> Any:
    return await dc.env.client.put(f"/files/{attachment}", content=data, headers=dc.headers)


async def get(dc: DeviceClient, attachment: uuid.UUID, **headers: str) -> Any:
    return await dc.env.client.get(f"/files/{attachment}", headers={**dc.headers, **headers})


def code(response: Any) -> str:
    return str(response.json()["error"]["code"])


async def test_upload_and_download(phone: DeviceClient, seed: StudySeed, root: Path) -> None:
    attachment = await attach(phone, seed, file_name="Задание №3.jpg")
    stored = await put(phone, attachment, JPEG)
    assert (stored.status_code, stored.json()) == (201, {"status": "stored", "size": len(JPEG)})
    assert files_on_disk(root) == [str(attachment)]
    response = await get(phone, attachment)
    assert response.status_code == 200
    assert response.content == JPEG
    headers = response.headers
    assert headers["content-type"] == "image/jpeg"
    assert headers["content-length"] == str(len(JPEG))
    assert headers["etag"] == f'"{file_meta(JPEG)["sha256"]}"'
    assert headers["x-content-type-options"] == "nosniff"
    assert (
        "filename*=UTF-8''%D0%97%D0%B0%D0%B4%D0%B0%D0%BD%D0%B8%D0%B5%20%E2%84%963.jpg"
        in (headers["content-disposition"])
    )
    assert headers["content-disposition"].startswith('attachment; filename="')
    assert headers["cache-control"] == "private, no-cache"


ODD_NAMES = [
    "Отчёт по ЛР №3.jpg",
    'say "hi".jpg',
    "semi;colon, comma.jpg",
    "100%.jpg",
    "a%20b%2Fc.jpg",
    "emoji \U0001f600 \u202e.jpg",
    "line\u2028sep\u0085nel.jpg",
    "  spaced  .jpg",
    ".hidden.jpg",
    "quote'single.jpg",
    "$(rm -rf x) `id` {a}.jpg",
    "я" * 120 + ".jpg",
]


@pytest.mark.parametrize("name", ODD_NAMES)
async def test_content_disposition_survives_odd_file_names(
    phone: DeviceClient, seed: StudySeed, name: str
) -> None:
    attachment = await attach(phone, seed, file_name=name)
    assert (await put(phone, attachment, JPEG)).status_code == 201
    response = await get(phone, attachment)
    assert response.status_code == 200
    raw = response.headers["content-disposition"]
    assert "\r" not in raw
    assert "\n" not in raw
    parts = re.fullmatch(
        r"attachment; filename=\"([^\"]*)\"; filename\*=UTF-8''([A-Za-z0-9%_.~-]*)", raw
    )
    assert parts is not None, raw  # a quote or a semicolon of the name cannot break out of it
    fallback, encoded = parts.groups()
    assert fallback.isascii()
    assert not set(fallback) & set('";\\')
    assert all(c.isprintable() for c in fallback)
    assert unquote(encoded) == name  # the real name is carried whole by filename*
    assert response.content == JPEG


@pytest.mark.parametrize(
    "name", ["a\r\nSet-Cookie: x=1.jpg", "a\nb.jpg", "a\x00b.jpg", "a\x7fb.jpg"]
)
async def test_a_file_name_with_control_characters_never_reaches_a_header(
    phone: DeviceClient, seed: StudySeed, name: str
) -> None:
    fields = attachment_fields(phone, JPEG, subject=seed.math, file_name=name)
    (result,) = await phone.push_ok([phone.op("attachments", uuid7(), fields=fields)])
    assert result["status"] == "rejected", result
    assert result["code"] in ("validation_failed", "invalid_field"), result  # NUL: type check


async def test_a_debt_attachment_is_served_too(phone: DeviceClient, seed: StudySeed) -> None:
    attachment = await attach(
        phone, seed, PDF, on_debt=True, file_name="task.pdf", mime_type="application/pdf"
    )
    assert (await put(phone, attachment, PDF)).status_code == 201
    got = await get(phone, attachment)
    assert (got.status_code, got.content) == (200, PDF)
    assert got.headers["content-type"] == "application/pdf"


async def test_a_repeated_upload_is_idempotent(
    phone: DeviceClient, seed: StudySeed, root: Path
) -> None:
    attachment = await attach(phone, seed)
    assert (await put(phone, attachment, JPEG)).status_code == 201
    before = (root / str(attachment)[:2] / str(attachment)).stat().st_mtime_ns
    again = await put(phone, attachment, JPEG)
    assert (again.status_code, again.json()["status"]) == (200, "exists")
    assert (root / str(attachment)[:2] / str(attachment)).stat().st_mtime_ns == before
    # once the file is safely stored, a repeat is not even read
    assert (await put(phone, attachment, b"x" * len(JPEG))).status_code == 200
    assert (await put(phone, attachment, b"anything")).status_code == 422  # not this file
    assert (await get(phone, attachment)).content == JPEG


async def test_a_truncated_upload_is_rejected_then_retried(
    phone: DeviceClient, seed: StudySeed, root: Path
) -> None:
    attachment = await attach(phone, seed)
    short = await put(phone, attachment, JPEG[:-10])
    assert (short.status_code, code(short)) == (422, "size_mismatch")
    assert files_on_disk(root) == []
    missing = await get(phone, attachment)
    assert (missing.status_code, code(missing)) == (404, "file_not_uploaded")

    async def chunks(limit: int) -> AsyncIterator[bytes]:
        for start in range(0, limit, 16):
            yield JPEG[start : min(start + 16, limit)]

    cut = await put(phone, attachment, chunks(len(JPEG) - 1))  # chunked, no length: counted
    assert (cut.status_code, code(cut)) == (422, "size_mismatch")
    assert files_on_disk(root) == []
    assert (await put(phone, attachment, JPEG)).status_code == 201


async def test_a_connection_that_breaks_mid_upload_leaves_nothing(
    phone: DeviceClient, seed: StudySeed, root: Path
) -> None:
    attachment = await attach(phone, seed)

    async def broken() -> AsyncIterator[bytes]:
        yield JPEG[:50]
        raise ConnectionResetError("network lost")

    with pytest.raises(ConnectionResetError):
        await put(phone, attachment, broken())
    assert files_on_disk(root) == []
    assert (await get(phone, attachment)).status_code == 404
    assert (await put(phone, attachment, JPEG)).status_code == 201


async def test_a_longer_body_is_rejected(phone: DeviceClient, seed: StudySeed, root: Path) -> None:
    attachment = await attach(phone, seed)
    declared = await put(phone, attachment, JPEG + b"extra")
    assert (declared.status_code, code(declared)) == (422, "size_mismatch")
    assert declared.json()["error"]["details"] == {"expected": len(JPEG), "received": len(JPEG) + 5}

    async def endless() -> AsyncIterator[bytes]:
        yield JPEG
        yield b"more"

    streamed = await put(phone, attachment, endless())
    assert (streamed.status_code, code(streamed)) == (413, "payload_too_large")
    assert files_on_disk(root) == []


async def test_a_wrong_hash_is_rejected(phone: DeviceClient, seed: StudySeed, root: Path) -> None:
    attachment = await attach(phone, seed)
    corrupt = JPEG[:-1] + b"?"
    response = await put(phone, attachment, corrupt)
    assert (response.status_code, code(response)) == (422, "hash_mismatch")
    assert files_on_disk(root) == []


async def test_the_size_limit(migrated_db_url: str, tmp_path: Path) -> None:
    async with make_env(
        migrated_db_url, files_dir=str(tmp_path / "files"), files_max_bytes=64
    ) as small:
        dc = await small.login()
        seed = await study_seed(dc)
        big = await attach(dc, seed, JPEG)  # 84 bytes > 64
        refused = await put(dc, big, JPEG)
        assert (refused.status_code, code(refused)) == (413, "payload_too_large")
        assert refused.json()["error"]["details"] == {"max_bytes": 64}
        assert files_on_disk(tmp_path / "files") == []
        fits = await attach(dc, seed, b"\xff\xd8\xff\xe0tiny")
        assert (await put(dc, fits, b"\xff\xd8\xff\xe0tiny")).status_code == 201


@pytest.mark.parametrize(
    ("data", "mime", "name"),
    [
        (JPEG, "image/jpeg", "a.jpg"),
        (PNG, "image/png", "a.png"),
        (WEBP, "image/webp", "a.webp"),
        (HEIC, "image/heic", "a.heic"),
        (HEIC, "image/heif", "a.heif"),
        (PDF, "application/pdf", "a.pdf"),
        (b"junk" * 100 + PDF, "application/pdf", "late.pdf"),
        (OLE, "application/msword", "a.doc"),
        (OLE, "application/vnd.ms-excel", "a.xls"),
        (OLE, "application/vnd.ms-powerpoint", "a.ppt"),
        (ZIP, DOCX, "a.docx"),
        (ZIP, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "a.xlsx"),
        (ZIP, "application/zip", "a.zip"),
        (b"PK\x05\x06" + b"\x00" * 18, "application/zip", "empty.zip"),
        (TEXT, "text/plain", "a.txt"),
        (b"hi", "text/plain", "short.txt"),
    ],
)
async def test_every_allowed_type_is_accepted(
    phone: DeviceClient, seed: StudySeed, data: bytes, mime: str, name: str
) -> None:
    attachment = await attach(phone, seed, data, file_name=name, mime_type=mime)
    response = await put(phone, attachment, data)
    assert response.status_code == 201, response.text
    assert (await get(phone, attachment)).content == data


@pytest.mark.parametrize(
    ("data", "mime", "name"),
    [
        (PNG, "image/jpeg", "a.jpg"),
        (JPEG, "image/png", "a.png"),
        (JPEG, "image/webp", "a.webp"),
        (JPEG, "image/heic", "a.heic"),
        (b"x" * 2000 + PDF, "application/pdf", "far.pdf"),
        (JPEG, "application/msword", "a.doc"),
        (JPEG, DOCX, "a.docx"),
        (JPEG, "application/zip", "a.zip"),
        (b"text\x00binary", "text/plain", "a.txt"),
        (b"\xff\xd8", "image/jpeg", "short.jpg"),
    ],
)
async def test_a_file_that_does_not_look_like_its_type_is_refused(
    phone: DeviceClient, seed: StudySeed, root: Path, data: bytes, mime: str, name: str
) -> None:
    attachment = await attach(phone, seed, data, file_name=name, mime_type=mime)
    response = await put(phone, attachment, data)
    assert (response.status_code, code(response)) == (415, "content_type_mismatch")
    assert files_on_disk(root) == []


async def test_authentication_is_required(fenv: Env, phone: DeviceClient, seed: StudySeed) -> None:
    attachment = await attach(phone, seed)
    await put(phone, attachment, JPEG)
    client = fenv.client
    url = f"/files/{attachment}"
    for call in (client.get(url, headers=SCHEMA), client.put(url, content=JPEG, headers=SCHEMA)):
        assert (await call).status_code == 401
    bad = {"Authorization": "Bearer nonsense", **SCHEMA}
    assert (await client.get(url, headers=bad)).status_code == 401
    no_schema = {"Authorization": f"Bearer {phone.access_token}"}
    assert (await client.get(url, headers=no_schema)).status_code == 400
    await fenv.execute("UPDATE devices SET revoked_at = now()")
    revoked = await client.get(url, headers=phone.headers)
    assert (revoked.status_code, code(revoked)) == (401, "device_revoked")


async def test_someone_elses_or_unknown_files_are_not_found(
    fenv: Env, phone: DeviceClient, seed: StudySeed
) -> None:
    unknown = uuid7()
    for response in (await get(phone, unknown), await put(phone, unknown, JPEG)):
        assert (response.status_code, code(response)) == (404, "attachment_not_found")
    not_an_id = await fenv.client.get("/files/not-a-uuid", headers=phone.headers)
    assert not_an_id.status_code == 422
    traversal = await fenv.client.get("/files/..%2F..%2Fetc%2Fpasswd", headers=phone.headers)
    assert traversal.status_code in (404, 422)


async def test_hidden_attachments_are_not_served(
    phone: DeviceClient, seed: StudySeed, fenv: Env
) -> None:
    on_subject = await attach(phone, seed)
    on_debt = await attach(
        phone, seed, PDF, on_debt=True, file_name="t.pdf", mime_type="application/pdf"
    )
    for attachment, data in ((on_subject, JPEG), (on_debt, PDF)):
        assert (await put(phone, attachment, data)).status_code == 201

    async def head() -> int:
        return int((await phone.pull_ok(0))["head_version"])

    # the attachment itself deleted
    await phone.push_ok([phone.op("attachments", on_subject, "delete", base=await head())])
    assert (await get(phone, on_subject)).status_code == 404
    assert (await put(phone, on_subject, JPEG)).status_code == 404
    # the debt deleted: its attachment goes with it
    await phone.push_ok([phone.op("study_debts", seed.debt_lab, "delete", base=await head())])
    assert (await get(phone, on_debt)).status_code == 404
    await phone.push_ok(
        [phone.op("study_debts", seed.debt_lab, fields={"deleted_at": None}, base=await head())]
    )
    assert (await get(phone, on_debt)).content == PDF
    # the subject deleted: both go away (the debt's attachment through the debt's subject)
    await phone.push_ok([phone.op("study_subjects", seed.math, "delete", base=await head())])
    assert (await get(phone, on_debt)).status_code == 404


async def test_a_file_that_is_not_uploaded_yet(phone: DeviceClient, seed: StudySeed) -> None:
    attachment = await attach(phone, seed)
    response = await get(phone, attachment)
    assert (response.status_code, code(response)) == (404, "file_not_uploaded")


async def test_conditional_download(phone: DeviceClient, seed: StudySeed) -> None:
    attachment = await attach(phone, seed)
    await put(phone, attachment, JPEG)
    etag = (await get(phone, attachment)).headers["etag"]
    same = await get(phone, attachment, **{"If-None-Match": etag})
    assert (same.status_code, same.content) == (304, b"")
    assert same.headers["etag"] == etag
    other = await get(phone, attachment, **{"If-None-Match": '"nope"'})
    assert other.status_code == 200


async def test_two_uploads_at_once_end_with_one_good_file(
    phone: DeviceClient, seed: StudySeed, root: Path
) -> None:
    attachment = await attach(phone, seed)
    first, second = await asyncio.gather(put(phone, attachment, JPEG), put(phone, attachment, JPEG))
    assert {first.status_code, second.status_code} <= {200, 201}
    assert files_on_disk(root) == [str(attachment)]
    assert (await get(phone, attachment)).content == JPEG


async def test_the_endpoints_say_so_when_storage_is_not_configured(env: Env) -> None:
    dc = await env.login()
    for response in (
        await env.client.get(f"/files/{uuid7()}", headers=dc.headers),
        await env.client.put(f"/files/{uuid7()}", content=b"x", headers=dc.headers),
    ):
        assert (response.status_code, code(response)) == (503, "files_not_configured")
