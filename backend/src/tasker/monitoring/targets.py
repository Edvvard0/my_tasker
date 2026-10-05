"""Where a check may point (spec: ``docs/specs/stage9_monitoring.md``, section 5).

The checks are run by the engine on *our* VPS, so a target the owner (or a stolen token) types in
must not reach the server's own network: loopback, private, link-local and cloud-metadata
addresses, single-label and internal names, URLs with credentials. Pure functions; the same rules
run in the client form (shared vectors ``shared-test-vectors/monitoring/targets.json``). The names
are checked syntactically here; ``check_addresses`` judges what a name resolves to (the worker
does it before every configuration is written).
"""

import ipaddress
import re
from collections.abc import Iterable
from dataclasses import dataclass
from urllib.parse import urlsplit

MAX_HOST_LENGTH = 253
MAX_URL_LENGTH = 2000
# Names that only make sense inside a network (RFC 6761/6762/8375 and the usual private zones).
RESERVED_SUFFIXES = (
    "localhost",
    "local",
    "localdomain",
    "internal",
    "intranet",
    "lan",
    "home",
    "corp",
    "home.arpa",
    "invalid",
    "test",
    "example",
    "onion",
)
_LABEL = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
_TLD = re.compile(r"[a-z]{2,63}|xn--[a-z0-9-]{1,59}")
_BAD_CHARS = re.compile(r"[\s\x00-\x1f\x7f/\\@?#%]")


@dataclass(frozen=True, slots=True)
class Verdict:
    valid: bool
    reason: str | None = None
    host: str | None = None  # the normalised host (lower case, no brackets, no trailing dot)

    def as_json(self) -> dict[str, object]:
        if self.valid:
            return {"valid": True, "host": self.host}
        return {"valid": False, "reason": self.reason}


def _bad(reason: str) -> Verdict:
    return Verdict(False, reason)


def non_global(address: str) -> bool:
    """True for every address that is not a public unicast one (also an IPv4 inside IPv6)."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return True
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return not ip.is_global or ip.is_multicast or ip.is_reserved or ip.is_unspecified


def check_host(host: str) -> Verdict:
    """A bare host: a public IP address (v6 with or without brackets) or a public-looking name."""
    if not host:
        return _bad("empty")
    if len(host) > MAX_HOST_LENGTH + 2:
        return _bad("too_long")
    if _BAD_CHARS.search(host.replace(":", "").replace("[", "").replace("]", "")):
        return _bad("bad_chars")
    inner = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    try:
        ip = ipaddress.ip_address(inner)
    except ValueError:
        pass
    else:
        if host.startswith("[") and ip.version != 6:
            return _bad("bad_chars")
        return _bad("non_global_ip") if non_global(inner) else Verdict(True, host=inner.lower())
    name = host.lower()
    if name.endswith("."):
        name = name[:-1]
    if not name.isascii() or ":" in name or "[" in name or "]" in name:
        return _bad("bad_chars")
    if len(name) > MAX_HOST_LENGTH:
        return _bad("too_long")
    labels = name.split(".")
    if len(labels) < 2:
        return _bad("single_label")
    if not all(_LABEL.fullmatch(label) for label in labels):
        return _bad("bad_label")
    if not _TLD.fullmatch(labels[-1]):
        return _bad("bad_tld")  # 127.1, 0x7f.1 and the like: not a name a resolver may take
    if any(name == s or name.endswith("." + s) for s in RESERVED_SUFFIXES):
        return _bad("reserved_name")
    return Verdict(True, host=name)


def check_url(url: str) -> Verdict:
    """An ``http(s)`` URL with a public host, no credentials and no fragment."""
    if not url:
        return _bad("empty")
    if len(url) > MAX_URL_LENGTH:
        return _bad("too_long")
    if re.search(r"[\s\x00-\x1f\x7f\\]", url):
        return _bad("bad_chars")
    try:
        parts = urlsplit(url)
    except ValueError:
        return _bad("bad_url")
    try:
        port = parts.port
    except ValueError:
        return _bad("bad_port")
    if parts.scheme.lower() not in ("http", "https"):
        return _bad("scheme")
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        return _bad("userinfo")
    if parts.fragment or url.endswith("#"):
        return _bad("fragment")
    if port is not None and not 1 <= port <= 65535:
        return _bad("bad_port")
    if not parts.hostname:
        return _bad("no_host")
    verdict = check_host(parts.hostname)
    return verdict if verdict.valid else _bad(verdict.reason or "bad_host")


def check_addresses(addresses: Iterable[str]) -> str | None:
    """What a name resolved to: ``None`` when there is at least one address and all are public,
    else a reason (``no_address`` / ``resolves_to_non_global``)."""
    found = list(addresses)
    if not found:
        return "no_address"
    return "resolves_to_non_global" if any(non_global(a) for a in found) else None
