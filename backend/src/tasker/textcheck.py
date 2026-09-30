"""What PostgreSQL ``text``/``jsonb`` can store, checked before the value reaches the driver.

A NUL character and a string that is not encodable as UTF-8 (lone surrogates, which JSON allows
as ``"\\ud800"``) make the database raise, so they are refused up front instead of failing a
whole request.
"""

from typing import Any

MAX_JSON_DEPTH = 64


def is_storable_text(value: str) -> bool:
    if "\x00" in value:
        return False
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def require_storable_text(value: str) -> str:
    """Pydantic-validator friendly: return the value or raise ``ValueError``."""
    if not is_storable_text(value):
        raise ValueError("must not contain NUL or unpaired surrogates")
    return value


def require_storable_json(value: Any, *, _depth: int = 0) -> None:
    """Check every string (keys included) and allow at most ``MAX_JSON_DEPTH`` nested containers."""
    if isinstance(value, str):
        require_storable_text(value)
    elif isinstance(value, dict | list) and _depth >= MAX_JSON_DEPTH:
        raise ValueError(f"nested deeper than {MAX_JSON_DEPTH} levels")
    elif isinstance(value, dict):
        for key, item in value.items():
            require_storable_text(key)
            require_storable_json(item, _depth=_depth + 1)
    elif isinstance(value, list):
        for item in value:
            require_storable_json(item, _depth=_depth + 1)
