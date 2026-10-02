# ruff: noqa: RUF001, PLR0911 - Russian keywords are the point of this module; matchers branch
"""REFERENCE implementation of the quick-input parser (Russian phrases).

The clients parse offline on their own (Dart); this module produces and checks the shared vectors
``shared-test-vectors/calendar/quick_input.json``. The grammar is normative and specified in
``docs/specs/stage2_calendar_tasks.md`` section 8.
"""

import re
from calendar import monthrange
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from tasker.calendar.ids import fold_tag_name

_SPLIT = re.compile("[ \t\n\r   ]+")
_PRIORITY = re.compile(r"![1-5]")
_INT = re.compile(r"[0-9]+")
_CLOCK = re.compile(r"([01]?[0-9]|2[0-3]):([0-5][0-9])")
_RANGE = re.compile(r"([01]?[0-9]|2[0-3]):([0-5][0-9])[-–—]([01]?[0-9]|2[0-3]):([0-5][0-9])")
_NUMERIC_DATE = re.compile(r"([0-9]{1,2})\.([0-9]{1,2})(?:\.([0-9]{4}|[0-9]{2}))?")
_ISO_DATE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})")
_YEAR = re.compile(r"20[0-9]{2}")
_HALF_HOURS = re.compile(r"([0-9]{1,2})[.,]5(ч|час|часа|часов)?")

WEEKDAYS = {
    "понедельник": 0, "пн": 0,
    "вторник": 1, "вт": 1,
    "среда": 2, "среду": 2, "ср": 2,
    "четверг": 3, "чт": 3,
    "пятница": 4, "пятницу": 4, "пт": 4,
    "суббота": 5, "субботу": 5, "сб": 5,
    "воскресенье": 6, "вс": 6,
}  # fmt: skip
MONTHS = {
    "января": 1, "янв": 1, "февраля": 2, "фев": 2, "марта": 3, "мар": 3,
    "апреля": 4, "апр": 4, "мая": 5, "июня": 6, "июн": 6, "июля": 7, "июл": 7,
    "августа": 8, "авг": 8, "сентября": 9, "сен": 9, "сент": 9,
    "октября": 10, "окт": 10, "ноября": 11, "ноя": 11, "нояб": 11,
    "декабря": 12, "дек": 12,
}  # fmt: skip
NEXT_WORDS = ("следующий", "следующую", "следующее")
CONNECTORS = ("в", "во", "на", "к", "до", "с")
DAYS_WORDS = ("день", "дня", "дней")
WEEK_WORDS = ("неделю", "недели", "недель")
MONTH_WORDS = ("месяц", "месяца", "месяцев")
MINUTE_WORDS = ("минуту", "минуты", "минут", "мин")
HOUR_WORDS = ("час", "часа", "часов", "ч")
PERIODS = ("утра", "дня", "вечера", "ночи")
DAYPART_TIMES = {"утром": (9, 0), "днем": (13, 0), "вечером": (19, 0)}
DAY_OFFSETS = {"сегодня": 0, "завтра": 1, "послезавтра": 2}


@dataclass(frozen=True, slots=True)
class QuickInput:
    title: str
    priority: int | None
    project: str | None
    people: list[str]
    tags: list[str]
    date: str | None
    time: str | None
    duration_minutes: int | None

    def as_json(self) -> dict[str, object]:
        return {
            "title": self.title,
            "priority": self.priority,
            "project": self.project,
            "people": self.people,
            "tags": self.tags,
            "date": self.date,
            "time": self.time,
            "duration_minutes": self.duration_minutes,
        }


@dataclass(frozen=True, slots=True)
class _Match:
    """What a phrase sets. day only: a date; clock only: a time; both: a moment; etc."""

    used: int
    day: date | None = None
    clock: tuple[int, int] | None = None
    duration: int | None = None


@dataclass(slots=True)
class _State:
    now: datetime
    keys: list[str]
    consumed: list[bool]
    day: date | None = None
    clock: tuple[int, int] | None = None
    duration: int | None = None


@dataclass(slots=True)
class _Meta:
    priority: int | None = None
    project: str | None = None
    people: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)


def _key(token: str) -> str:
    return token.lower().replace("ё", "е").rstrip(",;:")


def _evening(hour: int) -> int:
    """A bare hour 1..7 means the evening (13:00-19:00); everything else is taken literally."""
    return hour + 12 if 1 <= hour <= 7 else hour


def _add_months(day: date, months: int) -> date:
    index = day.year * 12 + day.month - 1 + months
    year, month = divmod(index, 12)
    month += 1
    return date(year, month, min(day.day, monthrange(year, month)[1]))


def _safe_date(year: int, month: int, day: int) -> date | None:
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _upcoming(today: date, month: int, day: int) -> date | None:
    """This year's date when it is not in the past, else next year's (None if neither exists)."""
    for year in (today.year, today.year + 1):
        found = _safe_date(year, month, day)
        if found is not None and found >= today:
            return found
    return None


def _number(keys: list[str], index: int) -> int | None:
    if index < len(keys) and _INT.fullmatch(keys[index]):
        return int(keys[index])
    return None


def _split_names(tokens: list[str]) -> tuple[list[str], _Meta]:
    rest: list[str] = []
    meta = _Meta()
    for token in tokens:
        if _PRIORITY.fullmatch(token):
            meta.priority = int(token[1])
            continue
        if len(token) > 1 and token[0] in "#@+":
            name = token[1:].rstrip(",.;:")
            first_ok = name[:1].isalpha() or (token[0] == "#" and name[:1].isdecimal())
            if name and first_ok:
                _record(meta, token[0], name)
                continue
        rest.append(token)
    return rest, meta


def _record(meta: _Meta, sigil: str, name: str) -> None:
    if sigil == "#":
        meta.project = name  # the last project wins
        return
    bucket = meta.people if sigil == "@" else meta.tags
    if fold_tag_name(name) not in [fold_tag_name(item) for item in bucket]:
        bucket.append(name)


def _relative(state: _State, i: int) -> _Match | None:
    keys = state.keys
    if keys[i] != "через":
        return None
    following = keys[i + 1] if i + 1 < len(keys) else ""
    today = state.now.date()
    if following == "неделю":
        return _Match(2, day=today + timedelta(days=7))
    if following == "месяц":
        return _Match(2, day=_add_months(today, 1))
    if following == "час":
        return _moment(2, state.now + timedelta(hours=1))
    if following == "полчаса":
        return _moment(2, state.now + timedelta(minutes=30))
    amount = _number(keys, i + 1)
    unit = keys[i + 2] if i + 2 < len(keys) else ""
    if amount is None:
        return None
    if unit in DAYS_WORDS and 1 <= amount <= 365:
        return _Match(3, day=today + timedelta(days=amount))
    if unit in WEEK_WORDS and 1 <= amount <= 52:
        return _Match(3, day=today + timedelta(days=7 * amount))
    if unit in MONTH_WORDS and 1 <= amount <= 24:
        return _Match(3, day=_add_months(today, amount))
    if unit in MINUTE_WORDS and 1 <= amount <= 1440:
        return _moment(3, state.now + timedelta(minutes=amount))
    if unit in HOUR_WORDS and 1 <= amount <= 72:
        return _moment(3, state.now + timedelta(hours=amount))
    return None


def _moment(used: int, moment: datetime) -> _Match:
    return _Match(used, day=moment.date(), clock=(moment.hour, moment.minute))


def _weekday_phrase(state: _State, i: int) -> _Match | None:
    keys = state.keys
    j = i
    if keys[j] in ("в", "во"):
        j += 1
    following = j < len(keys) and keys[j] in NEXT_WORDS
    if following:
        j += 1
    if j >= len(keys) or keys[j] not in WEEKDAYS:
        return None
    target = WEEKDAYS[keys[j]]
    today = state.now.date()
    if following:
        found = today - timedelta(days=today.weekday()) + timedelta(days=7 + target)
    else:
        delta = (target - today.weekday()) % 7 or 7
        found = today + timedelta(days=delta)
    return _Match(j + 1 - i, day=found)


def _date_phrase(state: _State, i: int) -> _Match | None:
    keys = state.keys
    key = keys[i]
    today = state.now.date()
    if key in DAY_OFFSETS:
        return _Match(1, day=today + timedelta(days=DAY_OFFSETS[key]))
    if key in ("в", "на") and i + 1 < len(keys) and keys[i + 1] in ("выходные", "выходных"):
        wd = today.weekday()
        return _Match(2, day=today if wd >= 5 else today + timedelta(days=5 - wd))
    iso = _ISO_DATE.fullmatch(key)
    if iso:
        found = _safe_date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)))
        return _Match(1, day=found) if found else None
    numeric = _NUMERIC_DATE.fullmatch(key)
    if numeric:
        day, month, year = int(numeric.group(1)), int(numeric.group(2)), numeric.group(3)
        if year is None:
            found = _upcoming(today, month, day)
        else:
            found = _safe_date(int(year) + (2000 if len(year) == 2 else 0), month, day)
        return _Match(1, day=found) if found else None
    amount = _number(keys, i)
    if amount is not None and i + 1 < len(keys) and keys[i + 1] in MONTHS:
        month = MONTHS[keys[i + 1]]
        if i + 2 < len(keys) and _YEAR.fullmatch(keys[i + 2]):
            found = _safe_date(int(keys[i + 2]), month, amount)
            return _Match(3, day=found) if found else None
        found = _upcoming(today, month, amount)
        return _Match(2, day=found) if found else None
    return None


def _clock_range(used: int, start: tuple[int, int], end: tuple[int, int]) -> _Match | None:
    minutes = (end[0] * 60 + end[1]) - (start[0] * 60 + start[1])
    if minutes <= 0:
        return None
    return _Match(used, clock=start, duration=minutes)


def _time_phrase(state: _State, i: int) -> _Match | None:
    keys = state.keys
    key = keys[i]
    if key == "с" and i + 3 < len(keys) and keys[i + 2] == "до":
        first, second = _CLOCK.fullmatch(keys[i + 1]), _CLOCK.fullmatch(keys[i + 3])
        if first and second:
            return _clock_range(
                4,
                (int(first.group(1)), int(first.group(2))),
                (int(second.group(1)), int(second.group(2))),
            )
    ranged = _RANGE.fullmatch(key)
    if ranged:
        h1, m1, h2, m2 = (int(g) for g in ranged.groups())
        return _clock_range(1, (h1, m1), (h2, m2))
    hour = _hour_phrase(keys, i)
    if hour is not None:
        return hour
    clock = _CLOCK.fullmatch(key)
    if clock:
        return _Match(1, clock=(int(clock.group(1)), int(clock.group(2))))
    if key in DAYPART_TIMES:
        return _Match(1, clock=DAYPART_TIMES[key])
    return None


def _hour_phrase(keys: list[str], i: int) -> _Match | None:
    """``[в|к] N [час|часа|часов] [утра|дня|вечера]`` (bare ``в N`` is handled separately)."""
    j = i
    has_prep = keys[j] in ("в", "к")
    if has_prep:
        j += 1
    amount = _number(keys, j)
    if amount is None:
        return None
    j += 1
    has_word = j < len(keys) and keys[j] in ("час", "часа", "часов")
    if has_word:
        j += 1
    period = keys[j] if j < len(keys) and keys[j] in PERIODS else None
    if period is not None:
        j += 1
        if not 1 <= amount <= 12:
            return None
        hour = _period_hour(amount, period)
        return None if hour is None else _Match(j - i, clock=(hour, 0))
    if has_word and has_prep and 0 <= amount <= 23:
        return _Match(j - i, clock=(_evening(amount), 0))
    return None


def _period_hour(amount: int, period: str) -> int | None:
    if period == "утра":
        return amount % 12
    if period == "ночи":  # 12 ночи = 00:00, 1..5 ночи = 01:00..05:00, 9..11 ночи = 21:00..23:00
        if amount == 12:
            return 0
        if 1 <= amount <= 5:
            return amount
        return amount + 12 if 9 <= amount <= 11 else None
    return amount % 12 + 12


def _duration_phrase(state: _State, i: int) -> _Match | None:
    keys = state.keys
    if keys[i] != "на" or i + 1 >= len(keys):
        return None
    following = keys[i + 1]
    if following == "час":
        return _Match(2, duration=60)
    if following == "полчаса":
        return _Match(2, duration=30)
    if following == "полтора" and i + 2 < len(keys) and keys[i + 2] == "часа":
        return _Match(3, duration=90)
    half = _HALF_HOURS.fullmatch(following)
    if half:  # "на 1.5ч", "на 2,5 часа": N and a half hours
        used = 2 if half.group(2) else 3
        word = keys[i + 2] if used == 3 and i + 2 < len(keys) else ""
        if half.group(2) or word in HOUR_WORDS:
            return _Match(used, duration=int(half.group(1)) * 60 + 30)
        return None
    amount = _number(keys, i + 1)
    unit = keys[i + 2] if i + 2 < len(keys) else ""
    if amount is None:
        return None
    if unit in MINUTE_WORDS and 1 <= amount <= 1440:
        return _Match(3, duration=amount)
    if unit in HOUR_WORDS and 1 <= amount <= 24:
        return _Match(3, duration=amount * 60)
    return None


def _weekday_at(state: _State, i: int) -> _Match | None:
    key = state.keys[i]
    if key in ("в", "во") or key in NEXT_WORDS or key in WEEKDAYS:
        return _weekday_phrase(state, i)
    return None


def _accept(state: _State, i: int, match: _Match) -> int:
    """Record ``match`` if every component it sets is still free. Returns tokens used (0: no)."""
    if (
        (match.day is not None and state.day is not None)
        or (match.clock is not None and state.clock is not None)
        or (match.duration is not None and state.duration is not None)
    ):
        return 0
    state.day = match.day or state.day
    state.clock = match.clock or state.clock
    state.duration = match.duration if match.duration is not None else state.duration
    for k in range(i, i + match.used):
        state.consumed[k] = True
    sets_moment = match.day is not None or match.clock is not None
    if sets_moment and i > 0 and not state.consumed[i - 1] and state.keys[i - 1] in CONNECTORS:
        state.consumed[i - 1] = True  # a dangling "в", "на", "до" ... before the phrase
    return match.used


def _scan(state: _State) -> None:
    i = 0
    while i < len(state.keys):
        match = (
            _relative(state, i)
            or _weekday_at(state, i)
            or _date_phrase(state, i)
            or _time_phrase(state, i)
            or _duration_phrase(state, i)
        )
        used = _accept(state, i, match) if match else 0
        i += used or 1


def _bare_hour(state: _State) -> None:
    """``в N`` (N = 0..23): a time when a date was found, or when it ends the text."""
    if state.clock is not None:
        return
    keys = state.keys
    for i in range(len(keys) - 1):
        if state.consumed[i] or state.consumed[i + 1] or keys[i] != "в":
            continue
        amount = _number(keys, i + 1)
        if amount is None or amount > 23:
            continue
        if state.day is None and i + 2 != len(keys):
            continue
        state.clock = (_evening(amount), 0)
        state.consumed[i] = state.consumed[i + 1] = True
        return


def parse_quick_input(text: str, now: datetime) -> QuickInput:
    """Parse one line. ``now`` is the local wall-clock time (naive, minute precision)."""
    tokens = [t for t in _SPLIT.split(text) if t]
    rest, meta = _split_names(tokens)
    state = _State(now, [_key(t) for t in rest], [False] * len(rest))
    _scan(state)
    _bare_hour(state)
    day, clock = state.day, state.clock
    if clock is not None and day is None:
        today = now.date()
        day = today if clock > (now.hour, now.minute) else today + timedelta(days=1)
    title = " ".join(t for t, gone in zip(rest, state.consumed, strict=True) if not gone)
    return QuickInput(
        title=title,
        priority=meta.priority,
        project=meta.project,
        people=meta.people,
        tags=meta.tags,
        date=None if day is None else day.isoformat(),
        time=None if clock is None else f"{clock[0]:02d}:{clock[1]:02d}",
        duration_minutes=state.duration,
    )
