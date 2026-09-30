from collections.abc import Awaitable, Callable
from dataclasses import dataclass

JobFunc = Callable[[], Awaitable[None]]


@dataclass(frozen=True, slots=True)
class Job:
    name: str
    interval: float
    func: JobFunc


class JobRegistry:
    """Named periodic jobs. Feature modules register theirs on the shared ``registry``."""

    def __init__(self) -> None:
        self._jobs: dict[str, Job] = {}

    def register(self, name: str, *, interval: float) -> Callable[[JobFunc], JobFunc]:
        """Decorator: run the coroutine function every ``interval`` seconds."""
        if interval <= 0:
            raise ValueError("interval must be positive")

        def decorator(func: JobFunc) -> JobFunc:
            if name in self._jobs:
                raise ValueError(f"job {name!r} is already registered")
            self._jobs[name] = Job(name=name, interval=interval, func=func)
            return func

        return decorator

    def jobs(self) -> list[Job]:
        return list(self._jobs.values())


registry = JobRegistry()
