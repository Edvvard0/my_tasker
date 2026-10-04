"""Reference engine for the bank notification rules (spec: ``docs/specs/stage6_banks.md``, 2).

The rules are data (``shared-data/banks/notification_rules.json``); the Dart client ships its own
engine that must give the same result on ``shared-test-vectors/banks/notification_parse.json``.
That is why a rule may use only a small regular-expression subset (:func:`pattern_problem`) and why
the text is cleaned by :func:`normalize_text` before matching.
"""

import re
from collections.abc import Mapping
from typing import Any

from tasker.banks.reference import HOME_CURRENCY
from tasker.datafiles import load_json
from tasker.money import AmountError, parse_amount

RULES_FILE = "banks/notification_rules.json"
KINDS = ("expense", "income", "ignore")
GROUP_NAMES = ("amount", "currency", "merchant", "card_last4", "balance", "time")
_SPACES = " \u00a0\u202f\u2009\u2007\t\r\n\u2028\u2029\u000b\u000c"
_ESCAPABLE = set(".*+?()[]{}|^$\\-/")
_CARD = re.compile(r"[0-9]{4}")
_TIME = re.compile(r"([0-9]{2}):([0-9]{2})")


def load_rules() -> dict[str, Any]:
    rules: dict[str, Any] = load_json(RULES_FILE)
    return rules


def normalize_text(text: str) -> str:
    """Line breaks, tabs and the exotic spaces become one plain space; runs collapse; ends trim.
    Only the characters of ``_SPACES`` count (``str.split()`` would differ from Dart's ``trim``)."""
    flat = "".join(" " if char in _SPACES else char for char in text)
    return " ".join(part for part in flat.split(" ") if part)


def pattern_problem(pattern: str) -> str | None:
    """Why ``pattern`` is outside the portable subset (works the same in Python and Dart), or None.

    Allowed: literals, ``.``, character classes, ``( )`` and ``(?: )`` groups, ``| ? * + {m,n}``
    (also lazy), anchors ``^ $`` and escapes of punctuation. Not allowed: ``\\d \\w \\s \\b`` and
    other letter escapes (their meaning differs between runtimes), look-around, named groups,
    back references, inline flags.
    """
    i = 0
    while i < len(pattern):
        char = pattern[i]
        if char == "\\":
            if i + 1 >= len(pattern) or pattern[i + 1] not in _ESCAPABLE:
                return f"escape at {i} is not allowed"
            i += 2
            continue
        if char == "(" and pattern[i + 1 : i + 2] == "?" and pattern[i + 2 : i + 3] != ":":
            return f"group construct at {i} is not allowed"
        i += 1
    return None


def rules_problems(doc: Mapping[str, Any]) -> list[str]:
    """Structural check of a rules document (used by the tests and by CI of the data file)."""
    problems: list[str] = []
    seen_ids: set[str] = set()
    seen_packages: set[str] = set()
    for bank in doc["banks"]:
        for package in bank["packages"]:
            if package in seen_packages:
                problems.append(f"package {package} listed twice")
            seen_packages.add(package)
        for rule in bank["rules"]:
            rid = rule["id"]
            if rid in seen_ids:
                problems.append(f"{rid}: duplicate id")
            seen_ids.add(rid)
            problems.extend(f"{rid}: {p}" for p in _rule_problems(doc, rule))
    return problems


def _rule_problems(doc: Mapping[str, Any], rule: Mapping[str, Any]) -> list[str]:
    problems = []
    if rule["kind"] not in KINDS:
        problems.append(f"unknown kind {rule['kind']!r}")
    if (bad := pattern_problem(rule["pattern"])) is not None:
        problems.append(bad)
    try:
        compiled = re.compile(rule["pattern"])
    except re.error as exc:
        return [*problems, f"pattern does not compile: {exc}"]
    groups: Mapping[str, int] = rule.get("groups", {})
    for name, index in groups.items():
        if name not in GROUP_NAMES:
            problems.append(f"unknown group name {name!r}")
        if not 1 <= index <= compiled.groups:
            problems.append(f"group {name} points to {index}, the pattern has {compiled.groups}")
    if rule["kind"] != "ignore":
        if "amount" not in groups:
            problems.append("a financial rule needs an amount group")
        fixed = rule.get("currency_fixed")
        if fixed is not None and "currency" in groups:
            problems.append("currency_fixed and a currency group are exclusive")
    if not rule.get("samples"):
        problems.append("a rule needs at least one sample")
    if problems:
        return problems
    for sample in rule["samples"]:
        outcome = parse_with(doc, sample.get("package"), sample["title"], sample["text"], rule)
        if outcome.get("rule_id") != rule["id"]:
            problems.append(f"sample {sample['text']!r} is not matched by its own rule")
    return problems


def parse_with(
    doc: Mapping[str, Any],
    package: str | None,
    title: str,
    text: str,
    only_rule: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Run the rules of the bank that owns ``package`` (``only_rule``: just that one rule, for
    checking a sample; the package is then not needed)."""
    bank = next((b for b in doc["banks"] if package in b["packages"]), None)
    if only_rule is not None:
        rules = [only_rule]
        bank_id = None
    elif bank is None:
        return {"status": "ignored", "bank": None, "rule_id": None, "reason": "unknown_package"}
    else:
        rules, bank_id = bank["rules"], bank["id"]
    clean_title, clean_text = normalize_text(title), normalize_text(text)
    for rule in rules:
        if rule.get("title") is not None and clean_title not in rule["title"]:
            continue
        flags = re.IGNORECASE if rule.get("ignore_case") else 0
        match = re.search(rule["pattern"], clean_text, flags)
        if match is None:
            continue
        return _result(doc, bank_id, rule, match)
    return {"status": "unrecognized", "bank": bank_id, "rule_id": None, "reason": "no_rule"}


def parse_notification(package: str, title: str, text: str) -> dict[str, Any]:
    """``{"status": "parsed" | "ignored" | "unrecognized", ...}`` for one notification. ``parsed``
    carries ``bank, rule_id, kind, refund, amount, currency, card_last4, merchant, balance, time,
    needs_review, review_reason``; amounts are integer kopecks."""
    return parse_with(load_rules(), package, title, text)


def _result(
    doc: Mapping[str, Any], bank_id: str | None, rule: Mapping[str, Any], match: re.Match[str]
) -> dict[str, Any]:
    base = {"bank": bank_id, "rule_id": rule["id"]}
    if rule["kind"] == "ignore":
        return {"status": "ignored", **base}
    groups: Mapping[str, int] = rule["groups"]

    def group(name: str) -> str | None:
        index = groups.get(name)
        found = match.group(index) if index is not None else None
        return found.strip() if found is not None else None

    try:
        amount = parse_amount(group("amount") or "")
        raw_balance = group("balance")
        balance = parse_amount(raw_balance) if raw_balance is not None else None
    except AmountError:
        return {"status": "unrecognized", **base, "reason": "bad_amount"}
    symbol = group("currency")
    currency = rule.get("currency_fixed") or (
        doc["currencies"].get(symbol) if symbol is not None else HOME_CURRENCY
    )
    if currency is None:
        return {"status": "unrecognized", **base, "reason": "unknown_currency"}
    card = group("card_last4")
    moment = _TIME.fullmatch(group("time") or "")
    foreign = currency != HOME_CURRENCY
    return {
        "status": "parsed",
        **base,
        "kind": rule["kind"],
        "refund": bool(rule.get("refund", False)),
        "amount": amount,
        "currency": currency,
        "card_last4": card if card is not None and _CARD.fullmatch(card) else None,
        "merchant": rule.get("merchant_fixed") or group("merchant") or None,
        "balance": balance,
        "time": f"{moment[1]}:{moment[2]}"
        if moment and int(moment[1]) < 24 and int(moment[2]) < 60
        else None,
        "needs_review": foreign,
        "review_reason": "foreign_currency" if foreign else None,
    }
