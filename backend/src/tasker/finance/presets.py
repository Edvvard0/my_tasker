"""Preset Russian categories (spec: ``docs/specs/stage5_finance.md``, section 3.2).

The client creates them on first start with the deterministic id ``category_id(system_key)``; the
server only checks that a row with a known ``system_key`` carries exactly that id (so two offline
devices that both seed produce one row). ``backend/tests/finance_vectors_gen.py`` writes the table
into ``shared-test-vectors/finance/category_ids.json``.
"""

import uuid
from dataclasses import dataclass

from tasker.calendar.ids import namespace


@dataclass(frozen=True, slots=True)
class Preset:
    key: str
    name: str
    kind: str  # "expense" | "income"
    icon: str
    parent: str | None = None


def category_id(system_key: str) -> uuid.UUID:
    return uuid.uuid5(namespace("categories"), system_key)


PRESETS: tuple[Preset, ...] = (
    Preset("expense.groceries", "Продукты", "expense", "shopping_basket"),
    Preset("expense.eating_out", "Кафе и рестораны", "expense", "restaurant"),
    Preset("expense.transport", "Транспорт", "expense", "directions_bus"),
    Preset("expense.housing", "Жильё и коммунальные", "expense", "home"),
    Preset("expense.communication", "Связь и интернет", "expense", "wifi"),
    Preset("expense.health", "Здоровье", "expense", "medical_services"),
    Preset("expense.clothes", "Одежда и обувь", "expense", "checkroom"),
    Preset("expense.entertainment", "Развлечения", "expense", "movie"),
    Preset("expense.education", "Образование", "expense", "school"),
    Preset("expense.gifts", "Подарки", "expense", "card_giftcard"),
    Preset("expense.home_goods", "Дом и быт", "expense", "chair"),
    Preset("expense.subscriptions", "Подписки", "expense", "subscriptions"),
    Preset("expense.car", "Авто", "expense", "directions_car"),
    Preset("expense.travel", "Путешествия", "expense", "flight"),
    Preset("expense.other", "Прочее", "expense", "more_horiz"),
    Preset("expense.transport.taxi", "Такси", "expense", "local_taxi", "expense.transport"),
    Preset(
        "expense.transport.public",
        "Общественный транспорт",
        "expense",
        "train",
        "expense.transport",
    ),
    Preset("expense.car.fuel", "Топливо", "expense", "local_gas_station", "expense.car"),
    Preset("expense.car.service", "Обслуживание авто", "expense", "build", "expense.car"),
    Preset("expense.housing.rent", "Аренда и ипотека", "expense", "key", "expense.housing"),
    Preset(
        "expense.housing.utilities", "Коммунальные услуги", "expense", "bolt", "expense.housing"
    ),
    Preset("expense.health.pharmacy", "Аптека", "expense", "medication", "expense.health"),
    Preset("expense.health.doctors", "Врачи и анализы", "expense", "stethoscope", "expense.health"),
    Preset("income.salary", "Зарплата", "income", "payments"),
    Preset("income.projects", "Доход с проектов", "income", "work"),
    Preset("income.gifts", "Подарки", "income", "redeem"),
    Preset("income.interest", "Проценты и кэшбэк", "income", "savings"),
    Preset("income.other", "Прочее", "income", "more_horiz"),
)
PRESET_KEYS = frozenset(p.key for p in PRESETS)
