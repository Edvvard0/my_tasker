import asyncio

import structlog

from tasker.worker.registry import Job, JobRegistry

log = structlog.get_logger("worker")


async def _run_job(job: Job, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            await job.func()
        except Exception:
            log.exception("job_failed", job=job.name)
        try:
            await asyncio.wait_for(stop.wait(), timeout=job.interval)
        except TimeoutError:
            continue


async def run_worker(job_registry: JobRegistry, stop: asyncio.Event) -> None:
    """Run all jobs until ``stop`` is set; a job in flight is allowed to finish."""
    jobs = job_registry.jobs()
    log.info("worker_started", jobs=[job.name for job in jobs])
    async with asyncio.TaskGroup() as group:
        for job in jobs:
            group.create_task(_run_job(job, stop))
        await stop.wait()
    log.info("worker_stopped")
