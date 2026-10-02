"""Server-side context providers: text the server adds to the system message.

Stage 3 has one, "now" (date, time, weekday, time zone, parity of the week). Later stages may
register more with ``register_context_provider``; client-built context (sections of the data
the user chose) arrives in the request instead and never passes through here.
"""

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

from tasker.calendar.timefmt import parse_date
from tasker.calendar.week_cycle import cycle_week

WEEKDAYS = ("понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье")
MAX_CYCLE_LENGTH = 8


@dataclass(frozen=True, slots=True)
class ContextRequest:
    now: datetime  # aware
    timezone: ZoneInfo
    week_cycle: Mapping[str, Any] | None  # the ``calendar.week_cycle`` user setting, if any


ContextProvider = Callable[[ContextRequest], str | None]
CONTEXT_PROVIDERS: list[ContextProvider] = []


def register_context_provider(provider: ContextProvider) -> ContextProvider:
    CONTEXT_PROVIDERS.append(provider)
    return provider


def week_label(today: date, setting: Mapping[str, Any] | None) -> str | None:
    """Name of the cycle week containing ``today``, or ``None`` (no cycle, or a broken setting)."""
    if not isinstance(setting, Mapping):
        return None
    length = setting.get("length")
    start = (
        parse_date(setting["week1_start"]) if isinstance(setting.get("week1_start"), str) else None
    )
    if not isinstance(length, int) or isinstance(length, bool) or start is None:
        return None
    if not 2 <= length <= MAX_CYCLE_LENGTH:
        return None
    shifts: list[tuple[date, int]] = []
    raw_shifts = setting.get("shifts")
    for item in raw_shifts if isinstance(raw_shifts, list) else []:
        if not isinstance(item, dict):
            continue
        origin = parse_date(item["from"]) if isinstance(item.get("from"), str) else None
        weeks = item.get("weeks")
        if origin is not None and isinstance(weeks, int) and not isinstance(weeks, bool):
            shifts.append((origin, weeks))
    number = cycle_week(today, start, length, shifts)
    labels = setting.get("labels")
    if (
        isinstance(labels, list)
        and len(labels) == length
        and all(isinstance(label, str) and label for label in labels)
    ):
        return str(labels[number - 1])
    if length == 2:
        return ("Нечётная", "Чётная")[number - 1]
    return f"Неделя {number}"


@register_context_provider
def now_block(request: ContextRequest) -> str | None:
    local = request.now.astimezone(request.timezone)
    lines = [
        f"Текущие дата и время: {local:%Y-%m-%d %H:%M} ({WEEKDAYS[local.weekday()]}), "
        f"часовой пояс {request.timezone.key}.",
    ]
    label = week_label(local.date(), request.week_cycle)
    if label is not None:
        lines.append(f"Текущая неделя: {label}.")
    return "\n".join(lines)


def render(request: ContextRequest) -> str:
    return "\n\n".join(text for provider in CONTEXT_PROVIDERS if (text := provider(request)))
