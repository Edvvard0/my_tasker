import asyncio
import os
import signal
import subprocess
import sys
import threading
from typing import Any

import pytest

from tasker.worker.__main__ import amain, main
from tasker.worker.registry import JobRegistry
from tasker.worker.runner import run_worker


def test_register_and_list() -> None:
    reg = JobRegistry()

    @reg.register("a", interval=1)
    async def job_a() -> None: ...

    @reg.register("b", interval=2)
    async def job_b() -> None: ...

    assert [(j.name, j.interval) for j in reg.jobs()] == [("a", 1), ("b", 2)]
    assert reg.jobs()[0].func is job_a


def test_duplicate_name_rejected() -> None:
    reg = JobRegistry()

    @reg.register("a", interval=1)
    async def first() -> None: ...

    with pytest.raises(ValueError, match="already registered"):

        @reg.register("a", interval=1)
        async def second() -> None: ...


def test_non_positive_interval_rejected() -> None:
    with pytest.raises(ValueError, match="positive"):
        JobRegistry().register("a", interval=0)


async def test_jobs_run_repeatedly_and_stop_gracefully() -> None:
    reg = JobRegistry()
    calls = 0
    stop = asyncio.Event()

    @reg.register("tick", interval=0.01)
    async def tick() -> None:
        nonlocal calls
        calls += 1
        if calls == 3:
            stop.set()

    await asyncio.wait_for(run_worker(reg, stop), timeout=5)
    assert calls == 3


async def test_failing_job_does_not_stop_worker() -> None:
    reg = JobRegistry()
    calls = 0
    stop = asyncio.Event()

    @reg.register("boom", interval=0.01)
    async def boom() -> None:
        nonlocal calls
        calls += 1
        if calls == 2:
            stop.set()
        raise RuntimeError("expected")

    await asyncio.wait_for(run_worker(reg, stop), timeout=5)
    assert calls == 2


async def test_in_flight_job_finishes_before_shutdown() -> None:
    reg = JobRegistry()
    started = asyncio.Event()
    finished = False
    stop = asyncio.Event()

    @reg.register("slow", interval=60)
    async def slow() -> None:
        nonlocal finished
        started.set()
        await asyncio.sleep(0.1)
        finished = True

    task = asyncio.create_task(run_worker(reg, stop))
    await started.wait()
    stop.set()
    await asyncio.wait_for(task, timeout=5)
    assert finished


async def test_empty_registry_waits_for_stop() -> None:
    stop = asyncio.Event()
    task = asyncio.create_task(run_worker(JobRegistry(), stop))
    await asyncio.sleep(0.05)
    assert not task.done()
    stop.set()
    await asyncio.wait_for(task, timeout=5)


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
async def test_amain_stops_on_signal(sig: signal.Signals) -> None:
    loop = asyncio.get_running_loop()
    loop.call_later(0.1, os.kill, os.getpid(), sig)
    await asyncio.wait_for(amain(), timeout=5)


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
def test_module_exits_cleanly_on_signal(sig: signal.Signals) -> None:
    env: dict[str, Any] = {
        **os.environ,
        "DATABASE_URL": "postgresql://u:p@127.0.0.1:1/d",
        "LOG_LEVEL": "INFO",
    }
    proc = subprocess.Popen(
        [sys.executable, "-m", "tasker.worker"],
        env=env,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    assert "worker_started" in proc.stdout.readline()
    proc.send_signal(sig)
    output, _ = proc.communicate(timeout=10)
    assert proc.returncode == 0
    assert "worker_stopped" in output


def test_main_runs_until_signalled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@127.0.0.1:1/d")
    running = threading.Event()

    async def run_and_announce(registry: JobRegistry, stop: asyncio.Event) -> None:
        # amain installed the signal handlers before calling run_worker, so from here on a
        # signal is safe: it is signalled only once the worker is really running.
        running.set()
        await run_worker(registry, stop)

    monkeypatch.setattr("tasker.worker.__main__.run_worker", run_and_announce)

    def signal_when_running() -> None:
        if running.wait(timeout=10):
            os.kill(os.getpid(), signal.SIGTERM)

    sender = threading.Thread(target=signal_when_running, daemon=True)
    sender.start()
    try:
        assert main() == 0
    finally:
        running.set()  # release the sender if main() failed before starting the worker
        sender.join(timeout=5)
