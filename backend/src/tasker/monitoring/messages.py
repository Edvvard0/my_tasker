"""Texts of the Telegram messages (Russian, plain text, no secrets). The alert engine decides
*what* to say (``alerts.compose``), this module only says it."""

import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any
from zoneinfo import ZoneInfo

MAX_REASON = 120
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


@dataclass(frozen=True, slots=True)
class ServiceInfo:
    name: str
    server: str | None = None
    checks: Mapping[str, str] = field(default_factory=dict)  # check id -> name


def duration_text(seconds: int) -> str:
    """``45 с`` / ``12 мин`` / ``2 ч 05 мин`` (floor)."""
    seconds = max(0, seconds)
    if seconds < 60:
        return f"{seconds} с"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes} мин"
    return f"{minutes // 60} ч {minutes % 60:02d} мин"


def moment_text(ts: int, tz: ZoneInfo, now: int) -> str:
    local = datetime.fromtimestamp(ts, UTC).astimezone(tz)
    today = datetime.fromtimestamp(now, UTC).astimezone(tz).date()
    return local.strftime("%H:%M") if local.date() == today else local.strftime("%d.%m %H:%M")


def times_text(count: int) -> str:
    """``1 раз`` / ``2 раза`` / ``5 раз`` (Russian plural of «раз»)."""
    last = count % 10
    word = "раза" if last in (2, 3, 4) and count % 100 not in (12, 13, 14) else "раз"
    return f"{count} {word}"


def short_reason(reason: object) -> str:
    text = _CONTROL.sub(" ", str(reason or "нет ответа")).strip()
    return text if len(text) <= MAX_REASON else text[: MAX_REASON - 1] + "…"


def _label(info: ServiceInfo | None, sid: str) -> str:
    if info is None:
        return "сервис (удалён)"
    return f"{info.name} ({info.server})" if info.server else info.name


def _problems(info: ServiceInfo | None, reasons: Mapping[str, Any]) -> str:
    lines = []
    for cid in sorted(reasons, key=lambda c: ((info.checks.get(c) if info else None) or c, c)):
        label = (info.checks.get(cid) if info else None) or "проверка"
        lines.append(f"- {label}: {short_reason(reasons[cid])}")
    return "\n".join(lines)


def render(
    message: Mapping[str, Any], services: Mapping[str, ServiceInfo], tz: ZoneInfo, now: int
) -> str:
    kind = message["kind"]
    ids = message["services"]
    labels = [_label(services.get(s), s) for s in ids]
    first = ids[0]
    if kind == "down":
        text = f"ЛЕЖИТ: {labels[0]}\nС {moment_text(message['since'], tz, now)}"
        detail = _problems(services.get(first), message.get("reasons", {}))
        return f"{text}\n{detail}" if detail else text
    if kind == "down_group":
        text = f"ЛЕЖАТ ({len(ids)}): " + ", ".join(labels)
        text += f"\nС {moment_text(message['since'], tz, now)}"
        if message.get("suspect_monitor"):
            text += "\nВозможна проблема на стороне мониторинга или сети самого сервера."
        return text
    if kind == "recovered":
        return f"РАБОТАЕТ: {labels[0]}\nПростой: {duration_text(message['downtime'])}"
    if kind == "recovered_group":
        text = f"РАБОТАЮТ ({len(ids)}): " + ", ".join(labels)
        return f"{text}\nДлиннейший простой: {duration_text(message['downtime'])}"
    if kind == "reminder":
        return f"ВСЁ ЕЩЁ ЛЕЖИТ: {labels[0]}\nУже {duration_text(message['downtime'])}"
    if kind == "flapping":
        return (
            f"НЕСТАБИЛЕН: {labels[0]}\nСтатус сменился {times_text(message['changes'])} за "
            "короткое время. Сообщения по нему приостановлены, пока он не успокоится."
        )
    if kind == "stable":
        state = "работает" if message["status"] == "up" else "лежит"
        return f"УСПОКОИЛСЯ: {labels[0]}\nСейчас {state}."
    raise ValueError(f"unknown message kind {kind!r}")


ENGINE_DOWN = "МОНИТОРИНГ НЕ ОТВЕЧАЕТ: движок проверок недоступен, статусы могут быть устаревшими."
ENGINE_UP = "МОНИТОРИНГ ВОССТАНОВЛЕН: движок проверок снова отвечает."
TEST_MESSAGE = "Проверка связи: сообщение от My Tasker дошло."
