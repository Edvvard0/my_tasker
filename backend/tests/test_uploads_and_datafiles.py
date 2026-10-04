"""Request bodies read with a cap, and the location of the shared data files."""

from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any, cast

import pytest
from fastapi import Request
from starlette.requests import ClientDisconnect

from tasker.datafiles import load_json, shared_data_dir
from tasker.errors import ApiError
from tasker.uploads import capped_body, declared_length, read_capped


class FakeRequest:
    def __init__(
        self, chunks: list[bytes], length: str | None = None, hang_up: bool = False
    ) -> None:
        self.headers = {} if length is None else {"content-length": length}
        self._chunks = chunks
        self._hang_up = hang_up

    async def stream(self) -> AsyncIterator[bytes]:
        for chunk in self._chunks:
            yield chunk
        if self._hang_up:
            raise ClientDisconnect


def request(chunks: list[bytes], **kwargs: Any) -> Request:
    return cast(Request, FakeRequest(chunks, **kwargs))


async def test_a_body_within_the_cap() -> None:
    assert await read_capped(request([b"ab", b"cd"], length="4"), 4) == b"abcd"
    assert await read_capped(request([]), 10) == b""


async def test_a_body_over_the_cap_by_header_or_by_stream() -> None:
    with pytest.raises(ApiError) as by_header:
        await read_capped(request([b"x"], length="5"), 4)
    assert (by_header.value.status_code, by_header.value.code) == (413, "payload_too_large")
    with pytest.raises(ApiError) as streamed:
        await read_capped(request([b"abc", b"de"]), 4)
    assert streamed.value.details == {"max_bytes": 4}


async def test_a_client_that_hangs_up_is_reported() -> None:
    with pytest.raises(ApiError) as raised:
        _ = [chunk async for chunk in capped_body(request([b"ab"], hang_up=True), 10)]
    assert (raised.value.status_code, raised.value.code) == (400, "upload_interrupted")


def test_declared_length() -> None:
    assert declared_length(request([], length="12")) == 12
    assert declared_length(request([], length="x")) is None
    assert declared_length(request([])) is None


def test_the_shared_data_dir_can_be_moved(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("SHARED_DATA_DIR", raising=False)
    default = shared_data_dir()
    assert (default / "banks" / "notification_rules.json").is_file()
    assert (default / "calendar" / "holidays_ru.json").is_file()
    monkeypatch.setenv("SHARED_DATA_DIR", str(tmp_path))
    assert shared_data_dir() == tmp_path
    monkeypatch.setenv("SHARED_DATA_DIR", "   ")
    assert shared_data_dir() == default
    assert load_json("banks/merchant_normalization.json")["version"] == 1
