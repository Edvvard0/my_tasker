"""RUB amounts as integer kopecks. Rules are shared with Dart: see shared-test-vectors/README.md."""

import re

# SPACE, NO-BREAK SPACE, NARROW NO-BREAK SPACE, THIN SPACE.
_SPACES = "    "
NBSP = " "
RUB_SIGN = "₽"
# Longest first so that "руб." wins over "р".
_CURRENCY_SUFFIXES = (RUB_SIGN, "руб.", "руб", "р.", "р")
_MAX_INTEGER_DIGITS = 12
MAX_KOPECKS = 99_999_999_999_999
_AMOUNT = re.compile(r"([+\-−]?)([0-9]+)(?:[.,]([0-9]{1,2}))?")


class AmountError(ValueError):
    """Raised by :func:`parse_amount` for text that is not a valid RUB amount."""


def parse_amount(text: str) -> int:
    """Parse user-entered text such as ``"1 234,56 ₽"`` into kopecks."""
    body = text.strip(_SPACES)
    lowered = body.lower()
    for suffix in _CURRENCY_SUFFIXES:
        if lowered.endswith(suffix):
            body = body[: len(body) - len(suffix)]
            break
    body = "".join(ch for ch in body if ch not in _SPACES)
    match = _AMOUNT.fullmatch(body)
    if match is None:
        raise AmountError(f"invalid amount: {text!r}")
    sign, integer, fraction = match.groups()
    if len(integer) > _MAX_INTEGER_DIGITS:
        raise AmountError(f"amount too large: {text!r}")
    kopecks = int(integer) * 100 + int((fraction or "").ljust(2, "0"))
    return -kopecks if sign in ("-", "−") else kopecks


def format_amount(kopecks: int) -> str:
    """Format kopecks as ``"1 234,56 ₽"`` (NBSP thousands separator and before the sign).

    Raises :class:`TypeError` for anything but a real ``int`` (``bool`` included) and
    :class:`AmountError` when ``abs(kopecks) > MAX_KOPECKS``.
    """
    if type(kopecks) is not int:
        raise TypeError(f"kopecks must be int, got {type(kopecks).__name__}")
    if abs(kopecks) > MAX_KOPECKS:
        raise AmountError(f"amount out of range: {kopecks}")
    rubles, rest = divmod(abs(kopecks), 100)
    grouped = f"{rubles:,}".replace(",", NBSP)
    fraction = f",{rest:02d}" if rest else ""
    sign = "-" if kopecks < 0 else ""
    return f"{sign}{grouped}{fraction}{NBSP}{RUB_SIGN}"
