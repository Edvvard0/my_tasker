"""Model prices and the cost of a call in integer kopecks (spec stage3, 4 and 5.5).

Provider field names are not fixed (the docs and the live answers differ), so prices, the tool
capability and the usage cost are looked up tolerantly. Money never passes through ``float``:
numbers are read as ``Decimal`` from their JSON text form.
"""

import re
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

MILLION = Decimal(1_000_000)
KOPECKS = Decimal(100)
MAX_KOPECKS = 10**12
_NOISE = re.compile(r"[^a-z0-9]")
_INPUT_WORDS = ("input", "prompt")
_OUTPUT_WORDS = ("output", "completion")
_PRICE_CONTAINERS = ("pricing", "prices", "price", "cost")
_USAGE_COST_KEYS = ("cost", "cost_rub", "total_cost")


@dataclass(frozen=True, slots=True)
class Prices:
    """Rubles per one million tokens (exact decimals)."""

    input: Decimal | None = None
    output: Decimal | None = None


def to_decimal(value: object) -> Decimal | None:
    """A finite, non-negative ``Decimal`` from a JSON number or numeric string, else ``None``."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int | str):
        text = str(value).strip()
    elif isinstance(value, float):
        text = repr(value)
    else:
        return None
    try:
        number = Decimal(text)
    except InvalidOperation:
        return None
    if not number.is_finite() or number < 0:
        return None
    return number


def _price_in(
    mapping: Mapping[str, Any], words: tuple[str, ...], *, nested: bool
) -> Decimal | None:
    for key, value in mapping.items():
        name = _NOISE.sub("", key.lower())
        if "cache" in name or "image" in name or "audio" in name or "reason" in name:
            continue
        if not nested and "price" not in name and "cost" not in name:
            continue  # a top-level ``max_completion_tokens`` is not a price
        if any(word in name for word in words):
            if isinstance(value, Mapping):
                for inner_key in ("rub", "rur", "value", "amount", "per_1m", "per_million"):
                    if (found := to_decimal(value.get(inner_key))) is not None:
                        return found
                continue
            if (found := to_decimal(value)) is not None:
                return found
    return None


def parse_prices(model: Mapping[str, Any]) -> Prices:
    """Prices from the top level of a model entry or from a nested ``pricing`` object."""
    places: list[tuple[Mapping[str, Any], bool]] = []
    for name in _PRICE_CONTAINERS:
        container = model.get(name)
        if isinstance(container, Mapping):
            places.append((container, True))
    places.append((model, False))
    price_in: Decimal | None = None
    price_out: Decimal | None = None
    for place, nested in places:
        if price_in is None:
            price_in = _price_in(place, _INPUT_WORDS, nested=nested)
        if price_out is None:
            price_out = _price_in(place, _OUTPUT_WORDS, nested=nested)
    return Prices(price_in, price_out)


def _round(amount_rub: Decimal, rounding: str) -> int:
    kopecks = int((amount_rub * KOPECKS).to_integral_value(rounding=rounding))
    return min(max(kopecks, 0), MAX_KOPECKS)


def reported_cost_kopecks(usage: Mapping[str, Any]) -> int | None:
    """The cost the provider itself put into ``usage`` (rubles), in kopecks (half up)."""
    for key in _USAGE_COST_KEYS:
        value = to_decimal(usage.get(key))
        if value is not None:
            return _round(value, ROUND_HALF_UP)
    return None


def computed_cost_kopecks(prompt_tokens: int, completion_tokens: int, prices: Prices) -> int:
    """Cost by catalog prices, rounded up: a priced call never costs 0 kopecks."""
    total = Decimal(0)
    if prices.input is not None:
        total += Decimal(prompt_tokens) * prices.input / MILLION
    if prices.output is not None:
        total += Decimal(completion_tokens) * prices.output / MILLION
    return _round(total, ROUND_CEILING)


def display_price_kopecks_per_mtok(price: Decimal | None) -> int | None:
    """Catalog price for the client: whole kopecks per million tokens (display only)."""
    return None if price is None else _round(price, ROUND_HALF_UP)


def estimate_tokens(characters: int) -> int:
    """Rough token count for a provider that sent no ``usage``: three characters per token."""
    return -(-characters // 3)
