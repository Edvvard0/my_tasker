import logging
import re
import sys
from collections.abc import Iterable, Mapping, MutableMapping
from typing import Any

import structlog

REDACTED = "[redacted]"
# Keys whose value is never logged, whatever it is.
_SENSITIVE_KEY = re.compile(
    r"authorization|api[_-]?key|apikey|(access|refresh|auth|bearer|id)[_-]?token|^token$"
    r"|password|passwd|secret|cookie",
    re.IGNORECASE,
)
_BEARER = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+")
_KEY_LIKE = re.compile(r"\bsk-[A-Za-z0-9_-]{8,}")
# Shortest secret we scrub by value; shorter strings would mangle ordinary text.
_MIN_SECRET_LENGTH = 6


def make_redactor(secrets: Iterable[str] = ()) -> structlog.typing.Processor:
    """A structlog processor that removes secrets from the whole event, recursively.

    It scrubs (1) every value under a key that looks sensitive (``authorization``, ``api_key``,
    ``token``, ``password``, ``secret``...), (2) ``Bearer ...`` / ``sk-...`` shapes inside any
    string, and (3) the exact values in ``secrets`` (the provider key) wherever they appear, which
    covers exception texts and tracebacks rendered by ``format_exc_info``.
    """
    exact = sorted({s for s in secrets if len(s) >= _MIN_SECRET_LENGTH}, key=len, reverse=True)

    def scrub_text(text: str) -> str:
        for secret in exact:
            text = text.replace(secret, REDACTED)
        text = _BEARER.sub(lambda m: f"{m.group(1)} {REDACTED}", text)
        return _KEY_LIKE.sub(REDACTED, text)

    def scrub(value: Any, depth: int = 0) -> Any:
        if isinstance(value, str):
            return scrub_text(value)
        if depth > 8:
            return value
        if isinstance(value, Mapping):
            return {
                key: REDACTED
                if isinstance(key, str) and _SENSITIVE_KEY.search(key)
                else scrub(item, depth + 1)
                for key, item in value.items()
            }
        if isinstance(value, list | tuple):
            return [scrub(item, depth + 1) for item in value]
        return value

    def processor(
        _logger: Any, _method: str, event_dict: MutableMapping[str, Any]
    ) -> MutableMapping[str, Any]:
        cleaned: dict[str, Any] = scrub(dict(event_dict))
        return cleaned

    return processor


def configure_logging(level: str, redact: Iterable[str] = ()) -> None:
    """Route structlog and stdlib (uvicorn, sqlalchemy, ...) logs to stdout as JSON.

    ``redact``: secret values (such as the provider API key) removed from every log line.
    """
    redactor = make_redactor(redact)
    shared: list[structlog.typing.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
    ]
    structlog.configure(
        processors=[*shared, structlog.stdlib.ProcessorFormatter.wrap_for_formatter],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
    )
    formatter = structlog.stdlib.ProcessorFormatter(
        foreign_pre_chain=shared,
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            structlog.processors.format_exc_info,
            redactor,  # after the traceback is text: a key inside an exception message is caught
            structlog.processors.JSONRenderer(),
        ],
    )
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers.clear()
        logging.getLogger(name).propagate = True
    # Requests are logged by RequestIdMiddleware; uvicorn's access log would leak query strings.
    logging.getLogger("uvicorn.access").disabled = True
    # HTTP client libraries log full URLs at INFO.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)
