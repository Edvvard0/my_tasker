"""Files leave with the trash: the purge removes the content of purged attachments, the sweep
removes orphans and stale temporaries, and the worker job does both."""

import hashlib
import os
import time
import uuid
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from tasker.files import housekeeping
from tasker.files.housekeeping import purge_hook, sweep_orphans
from tasker.files.store import TEMP_SUFFIX, DiskFileStore
from tasker.ids import uuid7
from tasker.sync.jobs import sync_housekeeping
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env, make_env
from tests.study_support import JPEG, PDF, StudySeed, attachment_fields, study_seed


@pytest.fixture
async def fenv(migrated_db_url: str, tmp_path: Path) -> AsyncIterator[Env]:
    async with make_env(migrated_db_url, files_dir=str(tmp_path / "files")) as environment:
        yield environment


async def upload(
    dc: DeviceClient, seed: StudySeed, data: bytes, *, debt: bool = False, **over: str
) -> str:
    attachment = uuid7()
    fields = attachment_fields(
        dc,
        data,
        subject=None if debt else seed.phys,
        debt=seed.debt_lab if debt else None,
        **over,
    )
    await dc.push_ok([dc.op("attachments", attachment, fields=fields)])
    response = await dc.env.client.put(f"/files/{attachment}", content=data, headers=dc.headers)
    assert response.status_code == 201, response.text
    return str(attachment)


AGE = "UPDATE {table} SET deleted_at = now() - interval '31 days' WHERE deleted_at IS NOT NULL"


def names(root: Path) -> list[str]:
    return sorted(f for _, _, files in os.walk(root) for f in files)


async def age_the_trash(env: Env, dc: DeviceClient) -> None:
    top = int((await dc.pull_ok(0))["head_version"])
    env.clock.advance(days=31)
    await dc.refresh()
    await dc.pull_ok(top)


async def test_emptying_the_trash_deletes_the_files_of_deleted_entities(
    fenv: Env, tmp_path: Path
) -> None:
    root = tmp_path / "files"
    phone = await fenv.login()
    seed = await study_seed(phone)
    on_subject = await upload(phone, seed, JPEG)
    on_debt = await upload(
        phone, seed, PDF, debt=True, file_name="t.pdf", mime_type="application/pdf"
    )
    kept = await upload(phone, seed, b"\xff\xd8\xff\xe0kept")
    assert names(root) == sorted([on_subject, on_debt, kept])
    # the debt (and with it its file) and one attachment of the subject go to the trash
    top = int((await phone.pull_ok(0))["head_version"])
    await phone.push_ok(
        [
            phone.op("study_debts", seed.debt_lab, "delete", base=top),
            phone.op("attachments", uuid.UUID(on_subject), "delete", base=top),
        ]
    )
    await age_the_trash(fenv, phone)
    store = DiskFileStore(root)
    purged = await purge_tombstones(
        fenv.sessionmaker, fenv.rt.registry, fenv.clock.now(), purge_hook(store)
    )
    assert purged >= 3  # the debt, its attachment, the other attachment
    assert names(root) == [kept]
    assert await fenv.scalar("SELECT count(*) FROM attachments") == 1


async def test_a_purge_without_the_hook_leaves_orphans_that_the_sweep_removes(
    fenv: Env, tmp_path: Path
) -> None:
    root = tmp_path / "files"
    phone = await fenv.login()
    seed = await study_seed(phone)
    gone = await upload(phone, seed, JPEG)
    top = int((await phone.pull_ok(0))["head_version"])
    await phone.push_ok([phone.op("attachments", uuid.UUID(gone), "delete", base=top)])
    await age_the_trash(fenv, phone)
    await purge_tombstones(fenv.sessionmaker, fenv.rt.registry, fenv.clock.now())
    assert await fenv.scalar("SELECT count(*) FROM attachments") == 0
    assert names(root) == [gone]  # the content is still there
    assert await sweep_orphans(fenv.sessionmaker, DiskFileStore(root)) == 1
    assert names(root) == []


async def test_the_sweep_keeps_live_files_and_removes_only_stale_temporaries(
    fenv: Env, tmp_path: Path
) -> None:
    root = tmp_path / "files"
    phone = await fenv.login()
    seed = await study_seed(phone)
    live = await upload(phone, seed, JPEG)
    folder = root / live[:2]
    fresh = folder / f"{live}.fresh{TEMP_SUFFIX}"
    stale = folder / f"{live}.stale{TEMP_SUFFIX}"
    for path in (fresh, stale):
        path.write_bytes(b"partial")
    os.utime(stale, (time.time() - 7200, time.time() - 7200))
    store = DiskFileStore(root)
    assert await sweep_orphans(fenv.sessionmaker, store) == 1  # only the stale temporary
    assert sorted(p.name for p in folder.iterdir()) == sorted([live, fresh.name])
    assert await sweep_orphans(fenv.sessionmaker, store) == 0


async def test_the_sweep_handles_many_files(
    fenv: Env, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    store = DiskFileStore(tmp_path / "files")
    monkeypatch.setattr(housekeeping, "BATCH", 2)

    async def one(data: bytes) -> AsyncIterator[bytes]:
        yield data

    for n in range(5):
        data = f"orphan {n}".encode()
        digest = hashlib.sha256(data).hexdigest()
        await store.put(uuid7(), one(data), size=len(data), sha256=digest)
    assert await sweep_orphans(fenv.sessionmaker, store) == 5
    assert names(tmp_path / "files") == []


async def test_the_worker_job_purges_rows_and_files(
    migrated_db_url: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "files"
    async with make_env(migrated_db_url, files_dir=str(root)) as env:
        phone = await env.login()
        seed = await study_seed(phone)
        doomed = await upload(phone, seed, JPEG)
        top = int((await phone.pull_ok(0))["head_version"])
        await phone.push_ok([phone.op("study_subjects", seed.phys, "delete", base=top)])
        orphan = root / "00"
        orphan.mkdir(parents=True, exist_ok=True)
        (orphan / "00000000-0000-4000-8000-000000000001").write_bytes(b"orphan")
        # the trash is old, and no active device is left to wait for
        await env.execute("UPDATE devices SET revoked_at = now()")
        for table in ("study_subjects", "attachments", "class_slots", "study_debts"):
            await env.execute(AGE.format(table=table))
        monkeypatch.setenv("DATABASE_URL", migrated_db_url)
        monkeypatch.setenv("FILES_DIR", str(root))
        await sync_housekeeping()
        assert await env.scalar("SELECT count(*) FROM attachments") == 0
        assert doomed not in names(root)
        assert names(root) == []


async def test_the_job_without_a_files_dir_only_purges_rows(
    migrated_db_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABASE_URL", migrated_db_url)
    monkeypatch.delenv("FILES_DIR", raising=False)
    await sync_housekeeping()
