"""Reference rules of the Banks module (spec: ``docs/specs/stage6_banks.md``).

Pure functions over JSON-shaped rows. Everything here is language-neutral by construction (integer
arithmetic, code-point tests, no locale-dependent case folding), so the Dart client reproduces it
byte for byte against ``shared-test-vectors/banks/``.
"""

import hashlib
from collections import Counter
from collections.abc import Mapping, Sequence
from datetime import timedelta
from typing import Any

from tasker.datafiles import load_json
from tasker.finance.presets import category_id
from tasker.work.reference import moscow_date, parse_instant

Row = Mapping[str, Any]
Rows = Sequence[Row]

NORMALIZATION_FILE = "banks/merchant_normalization.json"
DICTIONARY_FILE = "banks/category_dictionary.json"

MATCH_THRESHOLD = 60  # similarity (0..100) from which two merchants are "the same"
UNKNOWN_SIMILARITY = 60  # when one side has no merchant at all: exactly at the threshold
PREFIX_SIMILARITY = 90  # the shorter name is the leading words of the longer one
MATCH_WINDOW = timedelta(hours=48)
TRANSFER_WINDOW_SECONDS = 600
DATE_ONLY_HOUR_UTC = 9  # a statement line with a date but no time is placed at 12:00 Moscow
HASH_LENGTH = 32
HOME_CURRENCY = "RUB"


# ------------------------------------------------------------------ merchant normalization


def _fold_char(char: str) -> str:
    """The kept alphabet is a-z, 0-9 and а-я; capitals are lowered and ё becomes е; every other
    code point is a separator (reported as a space)."""
    if "a" <= char <= "z" or "0" <= char <= "9" or "а" <= char <= "я":
        return char
    if "A" <= char <= "Z":
        return chr(ord(char) + 32)
    if "А" <= char <= "Я":
        return chr(ord(char) + 32)
    if char in ("ё", "Ё"):
        return "е"
    return " "


def fold_words(text: str) -> list[str]:
    """The words of ``text`` in the kept alphabet (see ``_fold_char``)."""
    return "".join(_fold_char(c) for c in text).split()


def _strip_tail(
    tokens: list[str], cities: Sequence[Sequence[str]], countries: set[str]
) -> list[str]:
    """Drop trailing country codes, cities (word sequences) and terminal numbers, repeatedly."""
    out = list(tokens)
    while out:
        last = out[-1]
        if last in countries or last.isdigit():
            out.pop()
            continue
        for city in cities:
            size = len(city)
            if size <= len(out) and out[len(out) - size :] == list(city):
                del out[len(out) - size :]
                break
        else:
            return out
    return out


def normalize_merchant(text: str) -> str:
    """Merchant key: lower case, only letters and digits, one space between words, without legal
    forms (ООО, ИП ...), trailing country codes, cities and terminal numbers. Idempotent. If the
    cleaning would leave nothing, the previous step is kept."""
    data = load_json(NORMALIZATION_FILE)
    legal = set(data["legal_forms"])
    tokens = fold_words(text)
    without_legal = [t for t in tokens if t not in legal] or tokens
    stripped = _strip_tail(without_legal, data["cities"], set(data["country_codes"]))
    return " ".join(stripped or without_legal)


# ------------------------------------------------------------------ similarity


def _bigrams(text: str) -> Counter[str]:
    return Counter(text[i : i + 2] for i in range(len(text) - 1))


def similarity(a: str, b: str) -> int:
    """How alike two *normalized* merchant names are, 0..100 (integer): 100 for equal names, 90
    when the shorter is the leading words of the longer, else the Dice coefficient of the
    character bigrams of the names without spaces (rounded down)."""
    if not a or not b:
        return 0
    if a == b:
        return 100
    words_a, words_b = a.split(" "), b.split(" ")
    short, long = (words_a, words_b) if len(words_a) <= len(words_b) else (words_b, words_a)
    if long[: len(short)] == short:
        return PREFIX_SIMILARITY
    grams_a, grams_b = _bigrams(a.replace(" ", "")), _bigrams(b.replace(" ", ""))
    total = grams_a.total() + grams_b.total()
    if total == 0:
        return 0
    return 2 * (grams_a & grams_b).total() * 100 // total


def merchant_similarity(a: str | None, b: str | None) -> int:
    """Similarity of two raw merchants; a missing one on either side is "cannot tell"."""
    norm_a, norm_b = normalize_merchant(a or ""), normalize_merchant(b or "")
    if not norm_a or not norm_b:
        return UNKNOWN_SIMILARITY
    return similarity(norm_a, norm_b)


# ------------------------------------------------------------------ deduplication hash


def minute_of(instant: str) -> str:
    """``YYYY-MM-DDTHH:MM`` (UTC, seconds dropped) of an instant."""
    return parse_instant(instant).strftime("%Y-%m-%dT%H:%M")


def dedup_tail(
    kind: str, amount: int, occurred_at: str, merchant: str | None, ordinal: int = 0
) -> str:
    """``kind|amount|minute|merchant_norm`` (+ ``|ordinal`` for the 2nd, 3rd ... identical one)."""
    tail = f"{kind}|{amount}|{minute_of(occurred_at)}|{normalize_merchant(merchant or '')}"
    return f"{tail}|{ordinal}" if ordinal else tail


def hash_of(account_id: str, tail: str) -> str:
    """The ``dedup_hash``: first 32 hex digits of SHA-256 of ``account_id|tail``."""
    digest = hashlib.sha256(f"{account_id}|{tail}".encode()).hexdigest()
    return digest[:HASH_LENGTH]


def dedup_hash(
    account_id: str,
    kind: str,
    amount: int,
    occurred_at: str,
    merchant: str | None,
    ordinal: int = 0,
) -> str:
    return hash_of(account_id, dedup_tail(kind, amount, occurred_at, merchant, ordinal))


def with_tails(candidates: Rows) -> list[str]:
    """``dedup_tail`` of every candidate; identical ones of one batch get ordinals 0, 1, ..."""
    seen: Counter[str] = Counter()
    tails = []
    for item in candidates:
        base = dedup_tail(
            item["kind"], int(item["amount"]), item["occurred_at"], item.get("merchant")
        )
        tails.append(f"{base}|{seen[base]}" if seen[base] else base)
        seen[base] += 1
    return tails


# ------------------------------------------------------------------ matching


def _is_foreign(item: Row) -> bool:
    return (item.get("currency") or HOME_CURRENCY) != HOME_CURRENCY


def _clash(candidate: Row, existing: Row) -> bool:
    """Two different bank identifiers: certainly two different operations."""
    ours, theirs = candidate.get("external_id"), existing.get("external_id")
    return ours is not None and theirs is not None and ours != theirs


def classify_candidates(account_id: str, candidates: Rows, existing: Rows) -> list[dict[str, Any]]:
    """What to do with each statement candidate for ``account_id`` (spec 4): ``new``,
    ``duplicate`` (skip) or ``merge`` (the statement refines an existing draft or manual row).

    1. Same bank identifier, or same ``dedup_hash``: ``duplicate``.
    2. Otherwise a fuzzy match among the rows not yet taken: same kind and amount, at most 48 hours
       apart, merchants alike (>= 60; an absent merchant counts as 60). Pairs are taken best first
       (similarity, then time distance, then ids) and each existing row serves one candidate.
       A matched row of source ``statement`` is a ``duplicate``, any other one is ``merge``.
    3. Foreign-currency candidates are never matched fuzzily and are flagged ``needs_review``.
    """
    rows = [e for e in existing if e["account_id"] == account_id]
    tails = with_tails(candidates)
    hashes = [hash_of(account_id, tail) for tail in tails]
    results: list[dict[str, Any]] = [
        {
            "index": i,
            "action": "new",
            "existing_id": None,
            "reason": None,
            "similarity": None,
            "dedup_hash": hashes[i],
            "needs_review": _is_foreign(candidate),
            "review_reason": "foreign_currency" if _is_foreign(candidate) else None,
        }
        for i, candidate in enumerate(candidates)
    ]
    taken: set[str] = set()
    for i, candidate in enumerate(candidates):
        free = [row for row in rows if row["id"] not in taken and not _clash(candidate, row)]
        ext = candidate.get("external_id")
        by_id = next((r for r in free if ext is not None and r.get("external_id") == ext), None)
        by_hash = next((r for r in free if r.get("dedup_hash") == hashes[i]), None)
        found, reason = (by_id, "external_id") if by_id is not None else (by_hash, "hash")
        if found is not None:
            taken.add(found["id"])
            results[i].update(action="duplicate", existing_id=found["id"], reason=reason)

    pairs: list[tuple[int, int, str, int]] = []
    for i, candidate in enumerate(candidates):
        if results[i]["action"] != "new" or _is_foreign(candidate):
            continue
        when = parse_instant(candidate["occurred_at"])
        for row in rows:
            if (
                row["id"] in taken
                or row["kind"] != candidate["kind"]
                or int(row["amount"]) != int(candidate["amount"])
                or _clash(candidate, row)
            ):
                continue
            gap = abs(parse_instant(row["occurred_at"]) - when)
            if gap > MATCH_WINDOW:
                continue
            score = merchant_similarity(candidate.get("merchant"), row.get("merchant"))
            if score >= MATCH_THRESHOLD:
                pairs.append((-score, int(gap.total_seconds()), row["id"], i))
    rows_by_id = {row["id"]: row for row in rows}
    for negative, _gap, row_id, i in sorted(pairs):
        if row_id in taken or results[i]["action"] != "new":
            continue
        taken.add(row_id)
        row = rows_by_id[row_id]
        results[i].update(
            action="duplicate" if row.get("source") == "statement" else "merge",
            existing_id=row_id,
            reason="fuzzy",
            similarity=-negative,
        )
        if results[i]["action"] == "merge":
            results[i]["refine"] = _refinement(candidates[i], row)
    return results


def _refinement(candidate: Row, row: Row) -> dict[str, str]:
    """What a statement line clarifies on a draft: the exact moment (only when the line has a
    time) and the merchant (only when the line names one)."""
    refine: dict[str, str] = {}
    if not candidate.get("date_only") and parse_instant(candidate["occurred_at"]) != parse_instant(
        row["occurred_at"]
    ):
        refine["occurred_at"] = candidate["occurred_at"]
    merchant = (candidate.get("merchant") or "").strip()
    if merchant and merchant != (row.get("merchant") or ""):
        refine["merchant"] = merchant
    return refine


def date_only_instant(day: str) -> str:
    """The moment a line with only a date gets: 12:00 Moscow time of that date."""
    return f"{day}T{DATE_ONLY_HOUR_UTC:02d}:00:00Z"


def match_transfers(
    transactions: Rows, window_seconds: int = TRANSFER_WINDOW_SECONDS
) -> list[dict[str, Any]]:
    """Own-account transfer suggestions: an expense on one account and an income on another with
    the same amount, at most ``window_seconds`` apart (rows with only a date: the same Moscow
    date). Foreign-currency rows and debt movements are skipped; each row joins one pair, the
    closest pairs first."""
    usable = [
        t
        for t in transactions
        if t["kind"] in ("expense", "income") and not _is_foreign(t) and t.get("debt_id") is None
    ]
    pairs = []
    for out in (t for t in usable if t["kind"] == "expense"):
        for inc in (t for t in usable if t["kind"] == "income"):
            if out["account_id"] == inc["account_id"] or int(out["amount"]) != int(inc["amount"]):
                continue
            gap = abs(parse_instant(out["occurred_at"]) - parse_instant(inc["occurred_at"]))
            if out.get("date_only") or inc.get("date_only"):
                if moscow_date(out["occurred_at"]) != moscow_date(inc["occurred_at"]):
                    continue
            elif gap > timedelta(seconds=window_seconds):
                continue
            pairs.append((int(gap.total_seconds()), out["id"], inc["id"]))
    used: set[str] = set()
    found = []
    for gap_seconds, out_id, in_id in sorted(pairs):
        if out_id in used or in_id in used:
            continue
        used.update((out_id, in_id))
        found.append({"expense_id": out_id, "income_id": in_id, "delta_seconds": gap_seconds})
    return found


# ------------------------------------------------------------------ automatic categories


def _contains(tokens: Sequence[str], needle: Sequence[str]) -> bool:
    size = len(needle)
    return size > 0 and any(
        list(tokens[i : i + size]) == list(needle) for i in range(len(tokens) - size + 1)
    )


def _kind_of_key(system_key: str) -> str:
    return system_key.split(".", 1)[0]


def suggest_category(
    merchant: str | None, mcc: str | None, kind: str, user_rules: Rows = ()
) -> dict[str, Any]:
    """The category for an operation: the user's own rules first (``exact`` before ``contains``,
    longer keys first), then the starter keywords (file order), then the MCC table.
    ``{"source": "user"|"keyword"|"mcc"|None, "category_id", "system_key"}``."""
    norm = normalize_merchant(merchant or "")
    tokens = norm.split(" ") if norm else []
    mine = [r for r in user_rules if r["kind"] == kind]
    exact = sorted(
        (r for r in mine if r["match_type"] == "exact" and r["merchant_key"] == norm),
        key=lambda r: r["id"],
    )
    contained = sorted(
        (
            r
            for r in mine
            if r["match_type"] == "contains" and _contains(tokens, r["merchant_key"].split(" "))
        ),
        key=lambda r: (-len(r["merchant_key"].split(" ")), -len(r["merchant_key"]), r["id"]),
    )
    for rule in [*exact, *contained][:1]:
        return {"source": "user", "category_id": rule["category_id"], "system_key": None}
    data = load_json(DICTIONARY_FILE)
    for entry in data["keywords"]:
        if _kind_of_key(entry["key"]) == kind and any(
            _contains(tokens, word.split(" ")) for word in entry["words"]
        ):
            return _preset("keyword", entry["key"])
    key = data["mcc"].get(mcc) if mcc else None
    if key is not None and _kind_of_key(key) == kind:
        return _preset("mcc", key)
    return {"source": None, "category_id": None, "system_key": None}


def _preset(source: str, key: str) -> dict[str, Any]:
    return {"source": source, "category_id": str(category_id(key)), "system_key": key}


__all__ = [
    "MATCH_THRESHOLD",
    "classify_candidates",
    "date_only_instant",
    "dedup_hash",
    "dedup_tail",
    "fold_words",
    "hash_of",
    "match_transfers",
    "merchant_similarity",
    "normalize_merchant",
    "similarity",
    "suggest_category",
    "with_tails",
]
