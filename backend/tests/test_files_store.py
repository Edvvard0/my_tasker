"""The disk file store: atomic writes, verification, interrupted uploads, listing, cleanup."""

import hashlib
import os
import time
import uuid
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from tasker.files.store import TEMP_SUFFIX, DiskFileStore, StoreError

DATA = b"hello store " * 1000
SHA = hashlib.sha256(DATA).hexdigest()


async def chunked(data: bytes, size: int = 700) -> AsyncIterator[bytes]:
    for start in range(0, len(data), size):
        yield data[start : start + size]


def files_under(root: Path) -> list[str]:
    return sorted(
        os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs
    )


async def test_put_read_size_delete(tmp_path: Path) -> None:
    store = DiskFileStore(tmp_path / "files")
    key = uuid.uuid4()
    assert await store.size(key) is None
    await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    assert await store.size(key) == len(DATA)
    assert b"".join([chunk async for chunk in store.read(key)]) == DATA
    assert files_under(tmp_path / "files") == [f"{str(key)[:2]}/{key}"]  # no temporary left
    await store.delete(key)
    assert await store.size(key) is None
    await store.delete(key)  # already gone: no error
    assert files_under(tmp_path / "files") == []


async def test_a_short_long_or_corrupt_upload_keeps_nothing(tmp_path: Path) -> None:
    store = DiskFileStore(tmp_path)
    key = uuid.uuid4()
    for body, code in (
        (DATA[:-1], "size_mismatch"),
        (DATA + b"x", "size_mismatch"),
        (b"X" + DATA[1:], "hash_mismatch"),
        (b"", "size_mismatch"),
    ):
        with pytest.raises(StoreError) as raised:
            await store.put(key, chunked(body), size=len(DATA), sha256=SHA)
        assert raised.value.code == code
        assert files_under(tmp_path) == []
        assert await store.size(key) is None


async def test_an_interrupted_upload_keeps_nothing_and_the_retry_works(tmp_path: Path) -> None:
    store = DiskFileStore(tmp_path)
    key = uuid.uuid4()

    async def broken() -> AsyncIterator[bytes]:
        yield DATA[:3000]
        raise ConnectionResetError("the client went away")

    with pytest.raises(ConnectionResetError):
        await store.put(key, broken(), size=len(DATA), sha256=SHA)
    assert files_under(tmp_path) == []
    await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    assert await store.size(key) == len(DATA)


async def test_a_second_put_replaces_atomically(tmp_path: Path) -> None:
    store = DiskFileStore(tmp_path)
    key = uuid.uuid4()
    await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    assert len(files_under(tmp_path)) == 1


async def test_keys_and_stale_temporaries(tmp_path: Path) -> None:
    store = DiskFileStore(tmp_path / "none")
    assert await store.keys() == []  # a store that was never written to
    assert await store.remove_stale_temporaries(0) == 0
    store = DiskFileStore(tmp_path)
    keys = [uuid.uuid4() for _ in range(3)]
    for key in keys:
        await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    assert sorted(await store.keys()) == sorted(keys)
    folder = tmp_path / str(keys[0])[:2]
    fresh = folder / f"{keys[0]}.1{TEMP_SUFFIX}"
    old = folder / f"{keys[0]}.2{TEMP_SUFFIX}"
    stranger = folder / "not-a-uuid.txt"
    for path in (fresh, old, stranger):
        path.write_bytes(b"x")
    os.utime(old, (time.time() - 7200, time.time() - 7200))
    assert await store.remove_stale_temporaries(3600) == 1
    assert not old.exists()
    assert fresh.exists()
    assert sorted(await store.keys()) == sorted(keys)  # temporaries and strangers are not keys


async def test_a_temporary_that_vanishes_during_the_sweep_is_not_an_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``os.replace`` of a finished upload can take a ``*.part`` away between the walk and the
    ``stat`` (or between the ``stat`` and the ``unlink``): the sweep carries on and counts only
    what it really removed."""
    store = DiskFileStore(tmp_path)
    key = uuid.uuid4()
    await store.put(key, chunked(DATA), size=len(DATA), sha256=SHA)
    folder = tmp_path / str(key)[:2]
    ghost = folder / f"{key}.ghost{TEMP_SUFFIX}"  # listed by the walk, gone at the stat
    racing = folder / f"{key}.racing{TEMP_SUFFIX}"  # gone between the stat and the unlink
    old = folder / f"{key}.old{TEMP_SUFFIX}"
    for path in (racing, old):
        path.write_bytes(b"x")
        os.utime(path, (time.time() - 7200, time.time() - 7200))
    monkeypatch.setattr(DiskFileStore, "_walk", lambda self: iter([ghost, racing, old]))
    real_unlink = Path.unlink

    def unlink(self: Path, missing_ok: bool = False) -> None:
        if self == racing:
            real_unlink(self)
            raise FileNotFoundError(str(self))
        real_unlink(self, missing_ok=missing_ok)

    monkeypatch.setattr(Path, "unlink", unlink)
    assert await store.remove_stale_temporaries(3600) == 1  # only ``old`` counts
    assert not old.exists()
    assert not racing.exists()
    assert await store.size(key) == len(DATA)
