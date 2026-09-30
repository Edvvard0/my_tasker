"""RF holidays: the rules for reading ``shared-data/calendar/holidays_ru.json``.

The file is bundled with the client (offline) and is not synced. Spec: section 7 of
``docs/specs/stage2_calendar_tasks.md``; vectors: ``shared-test-vectors/calendar/holidays.json``.
"""

import json
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

DATA_PATH = Path(__file__).resolve().parents[4] / "shared-data" / "calendar" / "holidays_ru.json"
TYPES = ("holiday", "transfer_off", "working_weekend")


@dataclass(frozen=True, slots=True)
class DayInfo:
    is_day_off: bool
    name: str | None


def load(path: Path = DATA_PATH) -> dict[str, Any]:
    data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return data


def day_info(data: dict[str, Any], day: date) -> DayInfo:
    """Is ``day`` a non-working day, and what is its listed name (``None`` if unlisted)?

    A listed ``holiday``/``transfer_off`` is always a day off, a listed ``working_weekend`` is
    always a working day; any other date is a day off exactly on Saturday and Sunday.
    """
    year = data["years"].get(str(day.year))
    if year is not None:
        for entry in year["days"]:
            if entry["date"] == day.isoformat():
                return DayInfo(entry["type"] != "working_weekend", entry["name"])
    return DayInfo(day.weekday() >= 5, None)
