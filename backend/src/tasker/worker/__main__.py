import asyncio
import signal
import sys

from tasker.config import Settings
from tasker.logging import configure_logging
from tasker.worker.registry import registry
from tasker.worker.runner import run_worker


async def amain() -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await run_worker(registry, stop)


def main() -> int:
    settings = Settings()
    configure_logging(settings.log_level)
    asyncio.run(amain())
    return 0


if __name__ == "__main__":
    sys.exit(main())
