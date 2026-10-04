"""File content storage behind an interface (disk now, S3 later). Spec: stage7_study.md, section 7.

The key of a file is its attachment id. A file is written to a temporary name in the same
directory and renamed into place after its size and SHA-256 were verified, so a reader never sees
a half-written file and an interrupted upload leaves nothing behind.
"""

import asyncio
import contextlib
import hashlib
import os
import time
import uuid
from collections.abc import AsyncIterator, Iterator
from pathlib import Path
from typing import BinaryIO, Protocol

CHUNK = 64 * 1024
TEMP_SUFFIX = ".part"


class StoreError(Exception):
    """The uploaded content does not match what the metadata promised."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class FileStore(Protocol):
    async def put(
        self, key: uuid.UUID, chunks: AsyncIterator[bytes], *, size: int, sha256: str
    ) -> None:
        """Store the chunks as ``key`` if they are exactly ``size`` bytes with this SHA-256
        (``StoreError`` otherwise; nothing is kept)."""

    async def size(self, key: uuid.UUID) -> int | None:
        """The size of the stored file, ``None`` if there is none."""

    def read(self, key: uuid.UUID) -> AsyncIterator[bytes]:
        """The stored content in chunks."""

    async def delete(self, key: uuid.UUID) -> None:
        """Remove the file (no error when it is already gone)."""

    async def keys(self) -> list[uuid.UUID]:
        """Every stored key."""

    async def remove_stale_temporaries(self, older_than_seconds: float) -> int:
        """Remove leftovers of interrupted uploads; returns how many."""


class DiskFileStore:
    """Files under ``root/<first two characters of the id>/<id>``."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def _path(self, key: uuid.UUID) -> Path:
        name = str(key)
        return self.root / name[:2] / name

    async def put(
        self, key: uuid.UUID, chunks: AsyncIterator[bytes], *, size: int, sha256: str
    ) -> None:
        target = self._path(key)
        await asyncio.to_thread(target.parent.mkdir, parents=True, exist_ok=True)
        temp = target.with_name(f"{target.name}.{uuid.uuid4().hex}{TEMP_SUFFIX}")
        digest = hashlib.sha256()
        total = 0
        handle: BinaryIO = await asyncio.to_thread(temp.open, "wb")
        try:
            async for chunk in chunks:
                total += len(chunk)
                if total > size:
                    raise StoreError("size_mismatch", "The upload is larger than its metadata")
                digest.update(chunk)
                await asyncio.to_thread(handle.write, chunk)
            if total != size:
                raise StoreError("size_mismatch", "The upload is shorter than its metadata")
            if digest.hexdigest() != sha256:
                raise StoreError("hash_mismatch", "The SHA-256 of the upload does not match")
            await asyncio.to_thread(_sync_and_close, handle)
            await asyncio.to_thread(os.replace, temp, target)
        except BaseException:
            await asyncio.to_thread(handle.close)
            await asyncio.to_thread(_unlink, temp)
            raise

    async def size(self, key: uuid.UUID) -> int | None:
        return await asyncio.to_thread(_size, self._path(key))

    async def read(self, key: uuid.UUID) -> AsyncIterator[bytes]:
        handle: BinaryIO = await asyncio.to_thread(self._path(key).open, "rb")
        try:
            while chunk := await asyncio.to_thread(handle.read, CHUNK):
                yield chunk
        finally:
            await asyncio.to_thread(handle.close)

    async def delete(self, key: uuid.UUID) -> None:
        await asyncio.to_thread(_unlink, self._path(key))

    async def keys(self) -> list[uuid.UUID]:
        return await asyncio.to_thread(self._keys)

    def _keys(self) -> list[uuid.UUID]:
        found = []
        for path in self._walk():
            with contextlib.suppress(ValueError):
                found.append(uuid.UUID(path.name))
        return found

    def _walk(self) -> Iterator[Path]:
        if not self.root.is_dir():
            return
        for folder in self.root.iterdir():
            if folder.is_dir():
                yield from (p for p in folder.iterdir() if p.is_file())

    async def remove_stale_temporaries(self, older_than_seconds: float) -> int:
        return await asyncio.to_thread(self._remove_stale, older_than_seconds)

    def _remove_stale(self, older_than_seconds: float) -> int:
        removed = 0
        cutoff = time.time() - older_than_seconds
        for path in self._walk():
            if path.name.endswith(TEMP_SUFFIX) and path.stat().st_mtime < cutoff:
                _unlink(path)
                removed += 1
        return removed


def _sync_and_close(handle: BinaryIO) -> None:
    handle.flush()
    os.fsync(handle.fileno())
    handle.close()


def _unlink(path: Path) -> None:
    with contextlib.suppress(FileNotFoundError):
        path.unlink()


def _size(path: Path) -> int | None:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return None
