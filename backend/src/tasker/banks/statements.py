"""Bank statement import (spec: ``docs/specs/stage6_banks.md``, section 5).

A statement (CSV, XLSX or PDF with a ruled table) is turned into a plain table of text cells, the
header row is found with the column profiles of ``shared-data/banks/statement_profiles.json`` and
every data row becomes a *candidate* operation. Nothing is stored: the bytes live only in memory
for the duration of the call.
"""

import csv
import io
import re
import time
import warnings
import zipfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from tasker.banks import reference as ref
from tasker.datafiles import load_json
from tasker.finance.reference import end_of_day
from tasker.money import AmountError, parse_amount
from tasker.work.reference import MOSCOW_OFFSET, moscow_date

PROFILES_FILE = "banks/statement_profiles.json"
FORMATS = ("csv", "xlsx", "pdf")
MAX_ROWS = 20_000
MAX_PDF_PAGES = 100
PDF_TITLE_LINES = 5
MAX_UNPACKED_BYTES = 64 * 1024 * 1024
MAX_XLSX_SHEETS = 20
MAX_XLSX_COLUMNS = 60  # a statement is a narrow table; wider cells are cut off
MAX_CELLS = 200_000  # all cells of all XLSX sheets together (trailing empty cells do not count)
PARSE_SECONDS = 20.0  # cooperative deadline of one parse: the worker thread stops itself
PARSE_HARD_SECONDS = 30.0  # what the api waits for the thread before it answers without it
MAX_CELL = 500
HEADER_SEARCH_ROWS = 60
MAX_MERCHANT = 200

_DATE_RU = re.compile(
    r"([0-9]{2})\.([0-9]{2})\.([0-9]{2}|[0-9]{4})(?:[ T]+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?"
)
_DATE_ISO = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?"
)
_PERIOD = re.compile(
    r"с\s+([0-9]{2}\.[0-9]{2}\.[0-9]{4})\s+по\s+([0-9]{2}\.[0-9]{2}\.[0-9]{4})", re.IGNORECASE
)
_CLOSING = re.compile(
    r"остаток\s+на\s+конец(?:\s+периода)?\D{0,20}?([-−+]?\s*[0-9][0-9 .,]*[0-9])", re.IGNORECASE
)
_CARD_TAIL = re.compile(r"([0-9]{4})\D*$")
_MCC = re.compile(r"[0-9]{4}")
_CURRENCIES = {
    "RUB": "RUB",
    "RUR": "RUB",
    "РУБ": "RUB",
    "₽": "RUB",
    "643": "RUB",
    "USD": "USD",
    "$": "USD",
    "840": "USD",
    "EUR": "EUR",
    "€": "EUR",
    "978": "EUR",
}


class StatementError(Exception):
    """The file cannot be turned into candidates; ``code`` is the API error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


# ------------------------------------------------------------------ table extraction


def detect_format(data: bytes, declared: str | None = None) -> str:
    """``pdf`` / ``xlsx`` / ``csv`` by the leading bytes; a declared format must agree."""
    if data[:1024].find(b"%PDF-") != -1:
        found = "pdf"
    elif data[:4] == b"PK\x03\x04":
        found = "xlsx"
    else:
        found = "csv"
    if declared is not None and declared != found:
        raise StatementError("statement_format_mismatch", f"the file is not a {declared} file")
    return found


def _clean_cell(value: object) -> str:
    if value is None or isinstance(value, bool):
        return ""
    if isinstance(value, datetime):
        stamp = "%d.%m.%Y" if value.time() == datetime.min.time() else "%d.%m.%Y %H:%M:%S"
        return value.strftime(stamp)
    if isinstance(value, float):
        return format(Decimal(repr(value)), "f")
    return " ".join(str(value).split())[:MAX_CELL]


def _csv_rows(data: bytes) -> list[list[str]]:
    if b"\x00" in data[:4096]:
        raise StatementError("statement_unreadable", "the file is not a text table")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = data.decode("cp1251")
        except UnicodeDecodeError as exc:
            raise StatementError("statement_unreadable", "unknown text encoding") from exc
    sample = [line for line in text.splitlines()[:40] if line.strip()]
    counts = {d: sum(line.count(d) for line in sample) for d in (";", "\t", ",")}
    delimiter = max(counts, key=lambda d: counts[d]) if any(counts.values()) else ";"
    rows: list[list[str]] = []
    try:
        for row in csv.reader(io.StringIO(text), delimiter=delimiter):
            rows.append([_clean_cell(cell) for cell in row])
            if len(rows) > MAX_ROWS:
                raise StatementError("statement_too_large", f"more than {MAX_ROWS} rows")
    except csv.Error as exc:
        raise StatementError("statement_unreadable", "the table cannot be read") from exc
    return rows


def _expired(deadline: float | None) -> None:
    """Stops a parse that has run past its deadline (a thread cannot be cancelled from outside)."""
    if deadline is not None and time.monotonic() > deadline:
        raise StatementError("statement_too_large", "the file takes too long to read")


def _xlsx_row(raw: tuple[object, ...]) -> list[str]:
    """Cleaned cells of a row without the empty tail (``None`` padding of a forged width)."""
    end = len(raw)
    if raw.count(None) == end:
        return []
    while raw[end - 1] is None:
        end -= 1
    row = [_clean_cell(cell) for cell in raw[:end]]
    while row and not row[-1]:
        row.pop()
    return row


def _xlsx_sheets(data: bytes, deadline: float | None = None) -> list[list[list[str]]]:
    import openpyxl  # noqa: PLC0415 - heavy import only when a workbook arrives

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if sum(info.file_size for info in archive.infolist()) > MAX_UNPACKED_BYTES:
                raise StatementError("statement_too_large", "the workbook is too large unpacked")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            book = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        sheets: list[list[list[str]]] = []
        try:
            if len(book.worksheets) > MAX_XLSX_SHEETS:
                raise StatementError("statement_too_large", f"more than {MAX_XLSX_SHEETS} sheets")
            cells = 0
            for sheet in book.worksheets:
                # The <dimension> of a sheet is only a claim of the file; openpyxl pads every row
                # to it, so a forged ``A1:XFD1048576`` would cost seconds and memory per row.
                sheet.reset_dimensions()
                rows = []
                for raw in sheet.iter_rows(max_col=MAX_XLSX_COLUMNS, values_only=True):
                    _expired(deadline)
                    row = _xlsx_row(raw)
                    rows.append(row)
                    cells += len(row)
                    if len(rows) > MAX_ROWS:
                        raise StatementError("statement_too_large", f"more than {MAX_ROWS} rows")
                    if cells > MAX_CELLS:
                        raise StatementError("statement_too_large", f"more than {MAX_CELLS} cells")
                sheets.append(rows)
        finally:
            book.close()
    except StatementError:
        raise
    except Exception as exc:
        raise StatementError("statement_unreadable", "the workbook cannot be read") from exc
    return sheets


def _pdf_rows(data: bytes, deadline: float | None = None) -> list[list[str]]:
    """The ruled tables of every page, preceded by the lines around them that matter: the first
    lines of the document (the bank's name), the period and the closing balance."""
    import pdfplumber  # noqa: PLC0415 - heavy import only when a PDF arrives

    notes: list[list[str]] = []
    rows: list[list[str]] = []
    try:
        with pdfplumber.open(io.BytesIO(data)) as pdf:
            if len(pdf.pages) > MAX_PDF_PAGES:
                raise StatementError("statement_too_large", f"more than {MAX_PDF_PAGES} pages")
            for number, page in enumerate(pdf.pages):
                _expired(deadline)
                for table in page.extract_tables():
                    rows.extend([_clean_cell(cell) for cell in row] for row in table)
                lines = [_clean_cell(line) for line in (page.extract_text() or "").splitlines()]
                notes.extend(
                    [line]
                    for index, line in enumerate(lines)
                    if (number == 0 and index < PDF_TITLE_LINES)
                    or _PERIOD.search(line)
                    or _CLOSING.search(line)
                )
                if len(rows) > MAX_ROWS:
                    raise StatementError("statement_too_large", f"more than {MAX_ROWS} rows")
    except StatementError:
        raise
    except Exception as exc:
        raise StatementError("statement_unreadable", "the PDF cannot be read") from exc
    return [*notes, *rows]


def extract_tables(fmt: str, data: bytes, deadline: float | None = None) -> list[list[list[str]]]:
    """The tables of a file as rows of text cells (an XLSX gives one table per sheet).
    ``deadline`` is a ``time.monotonic()`` moment after which a workbook or a PDF stops."""
    if fmt == "csv":
        return [_csv_rows(data)]
    if fmt == "xlsx":
        return _xlsx_sheets(data, deadline)
    if fmt == "pdf":
        return [_pdf_rows(data, deadline)]
    raise StatementError("statement_unsupported", f"unknown format {fmt!r}")


# ------------------------------------------------------------------ header and profiles


def header_key(text: str) -> str:
    """A header compared by its lower-cased letters and digits only (``ё`` = ``е``)."""
    return " ".join(ref.fold_words(text))


@dataclass(frozen=True, slots=True)
class Header:
    profile: str
    row: int  # index of the header row
    columns: Mapping[str, int]  # field -> column index
    score: int


def _profile_columns(profile: Mapping[str, Any]) -> dict[str, set[str]]:
    return {
        field: {header_key(name) for name in names} for field, names in profile["columns"].items()
    }


def _has_amount(columns: Mapping[str, int]) -> bool:
    return (
        "amount" in columns or "amount_account" in columns or {"debit", "credit"} <= columns.keys()
    )


def find_header(rows: Sequence[Sequence[str]], bank: str = "auto") -> Header | None:
    """The best (profile, row) pair among the first rows. A profile needs a date and an amount;
    more recognised columns win, a bank's own mention in the lines above breaks ties."""
    data = load_json(PROFILES_FILE)
    profiles = [p for p in data["profiles"] if bank in ("auto", p["id"]) or p["id"] == "generic"]
    best: tuple[int, Header] | None = None
    seen = ""
    for index, row in enumerate(rows[:HEADER_SEARCH_ROWS]):
        keys = [header_key(cell) for cell in row]
        for profile in profiles:
            columns: dict[str, int] = {}
            for field, names in _profile_columns(profile).items():
                column = next(
                    (i for i, key in enumerate(keys) if key in names and i not in columns.values()),
                    None,
                )
                if column is not None:
                    columns[field] = column
            if "date" not in columns or not _has_amount(columns):
                continue
            mention = any(
                header_key(w) in header_key(seen) for w in data["detect"].get(profile["id"], [])
            )
            rank = len(columns) * 2 + (1 if mention else 0)
            if best is None or rank > best[0]:
                best = (rank, Header(profile["id"], index, columns, len(columns)))
        seen += " " + " ".join(row)
    return best[1] if best else None


# ------------------------------------------------------------------ cells


def parse_statement_datetime(text: str) -> tuple[str, str | None] | None:
    """``(date, "HH:MM:SS" | None)`` from ``DD.MM.YYYY[ HH:MM[:SS]]`` (also a two-digit year) or
    ``YYYY-MM-DD[ HH:MM[:SS]]``; ``None`` when it is not a real date."""
    value = text.strip()
    match = _DATE_RU.fullmatch(value)
    if match:
        day, month, year = match[1], match[2], match[3]
        if len(year) == 2:
            year = f"20{year}"
    else:
        match = _DATE_ISO.fullmatch(value)
        if not match:
            return None
        year, month, day = match[1], match[2], match[3]
    hour, minute, second = match[4], match[5], match[6]
    try:
        stamp = datetime(
            int(year), int(month), int(day), int(hour or 0), int(minute or 0), int(second or 0)
        )
    except ValueError:
        return None
    if stamp.year < 2015:
        return None
    return stamp.date().isoformat(), (stamp.strftime("%H:%M:%S") if hour is not None else None)


def parse_money_cell(text: str) -> int | None:
    """Kopecks (signed) from a cell such as ``-1 234,56``, ``+500.00 RUB``, ``(75,00)``; ``None``
    for an empty or unreadable cell."""
    value = text.strip()
    if not value:
        return None
    negative = value.startswith("(") and value.endswith(")")
    value = value.strip("()")
    try:
        kopecks = parse_amount(value)
    except AmountError:
        return None
    return -abs(kopecks) if negative else kopecks


def normalize_currency(text: str) -> str | None:
    raw = text.strip().upper().rstrip(".")
    if not raw:
        return None
    return _CURRENCIES.get(raw, raw[:8])


# ------------------------------------------------------------------ rows -> candidates


def _cell(row: Sequence[str], columns: Mapping[str, int], field: str) -> str:
    index = columns.get(field)
    return row[index].strip() if index is not None and index < len(row) else ""


def _amounts(
    row: Sequence[str], columns: Mapping[str, int]
) -> tuple[str, int, str, int | None, str | None] | None:
    """``(kind, amount, currency, original_amount, original_currency)`` of a row, or ``None``."""
    debit = parse_money_cell(_cell(row, columns, "debit"))
    credit = parse_money_cell(_cell(row, columns, "credit"))
    in_account = parse_money_cell(_cell(row, columns, "amount_account"))
    in_operation = parse_money_cell(_cell(row, columns, "amount"))
    operation_currency = normalize_currency(_cell(row, columns, "currency"))
    account_currency = normalize_currency(_cell(row, columns, "currency_account"))
    if debit or credit:
        signed = -abs(debit) if debit else abs(credit or 0)
        currency = account_currency or operation_currency or ref.HOME_CURRENCY
        return ("expense" if signed < 0 else "income", abs(signed), currency, None, None)
    primary = in_account if in_account is not None else in_operation
    if not primary:
        return None
    currency = (
        (account_currency or ref.HOME_CURRENCY)
        if in_account is not None
        else (operation_currency or ref.HOME_CURRENCY)
    )
    original = None
    if in_account is not None and in_operation and operation_currency not in (None, currency):
        original = abs(in_operation)
    return (
        "expense" if primary < 0 else "income",
        abs(primary),
        currency,
        original,
        operation_currency if original is not None else None,
    )


def _moment(day: str, clock: str | None) -> str:
    if clock is None:
        return ref.date_only_instant(day)
    local = datetime.fromisoformat(f"{day}T{clock}")
    return (local - MOSCOW_OFFSET).replace(tzinfo=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _candidate(
    row: Sequence[str],
    columns: Mapping[str, int],
    ok_statuses: set[str],
) -> dict[str, Any] | str:
    """A candidate for one data row, or the reason the row is skipped."""
    if "status" in columns and ok_statuses:
        status = header_key(_cell(row, columns, "status"))
        if status and status not in ok_statuses:
            return f"status {status}"
    parsed = parse_statement_datetime(_cell(row, columns, "date"))
    if parsed is None:
        return "bad_date"
    amounts = _amounts(row, columns)
    if amounts is None:
        return "no_amount"
    kind, amount, currency, original, original_currency = amounts
    merchant = _cell(row, columns, "description")[:MAX_MERCHANT] or None
    mcc = _cell(row, columns, "mcc")
    card = _CARD_TAIL.search(_cell(row, columns, "card"))
    balance = parse_money_cell(_cell(row, columns, "balance"))
    foreign = currency != ref.HOME_CURRENCY or (original is not None)
    return {
        "occurred_at": _moment(*parsed),
        "date_only": parsed[1] is None,
        "kind": kind,
        "amount": amount,
        "currency": currency,
        "original_amount": original,
        "original_currency": original_currency,
        "merchant": merchant,
        "merchant_norm": ref.normalize_merchant(merchant or ""),
        "card_last4": card[1] if card else None,
        "external_id": _cell(row, columns, "external_id")[:200] or None,
        "mcc": mcc if _MCC.fullmatch(mcc) else None,
        "bank_category": _cell(row, columns, "category") or None,
        "balance_after": balance,
        "needs_review": foreign,
        "review_reason": "foreign_currency" if foreign else None,
    }


def _is_repeated_header(row: Sequence[str], keys: Sequence[str]) -> bool:
    return [header_key(c) for c in row[: len(keys)]] == list(keys)


def _closing_balance(
    rows: Sequence[Sequence[str]], last_day: str | None, period: Any, now: datetime | None
) -> Any:
    """The closing balance and the moment it is true. That moment is the end of the last day of
    the period, but never later than ``now``: a statement "up to today" would otherwise hang a
    checkpoint in the future that swallows every operation entered after the statement."""
    for row in rows:
        found = _CLOSING.search(" ".join(row))
        if found is None:
            continue
        amount = parse_money_cell(re.sub(r"\s+", "", found[1]).replace("−", "-"))
        if amount is None:
            continue
        day = (period or {}).get("to") or last_day
        if day is None:
            return None
        at = end_of_day(day)
        if now is not None:
            at = min(at, now.astimezone(UTC).replace(microsecond=0))
        return {"amount": amount, "at": at.strftime("%Y-%m-%dT%H:%M:%SZ")}
    return None


def parse_table(
    rows: Sequence[Sequence[str]],
    bank: str = "auto",
    user_rules: Sequence[Mapping[str, Any]] = (),
    now: datetime | None = None,
) -> dict[str, Any] | None:
    """Candidates of one table, or ``None`` when it has no recognisable header."""
    header = find_header(rows, bank)
    if header is None:
        return None
    profile = next(p for p in load_json(PROFILES_FILE)["profiles"] if p["id"] == header.profile)
    ok_statuses = {header_key(s) for s in profile["ok_statuses"]}
    header_keys = [header_key(c) for c in rows[header.row]]
    items: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    for number, row in enumerate(rows[header.row + 1 :], start=header.row + 2):
        if not any(cell.strip() for cell in row) or _is_repeated_header(row, header_keys):
            continue
        result = _candidate(row, header.columns, ok_statuses)
        if isinstance(result, str):
            if result != "bad_date" or any(
                _cell(row, header.columns, f) for f in ("amount", "amount_account")
            ):
                skipped.append({"row": number, "reason": result})
            continue
        result["row"] = number
        items.append(result)
    tails = ref.with_tails(items)
    for item, tail in zip(items, tails, strict=True):
        item["dedup_tail"] = tail
        item["suggested_category"] = ref.suggest_category(
            item["merchant"], item["mcc"], item["kind"], user_rules
        )
    for index, item in enumerate(items):
        item["index"] = index
    days = sorted(moscow_date(item["occurred_at"]) for item in items)
    text_rows = [row for row in rows if row is not rows[header.row]]
    heading = " ".join(" ".join(row) for row in rows[: header.row])
    period_match = _PERIOD.search(heading) or next(
        (m for m in (_PERIOD.search(" ".join(r)) for r in text_rows) if m), None
    )
    period = (
        {"from": _iso(period_match[1]), "to": _iso(period_match[2])}
        if period_match
        else ({"from": days[0], "to": days[-1]} if days else None)
    )
    return {
        "bank": header.profile,
        "period": period,
        "closing_balance": _closing_balance(text_rows, days[-1] if days else None, period, now),
        "cards": sorted({item["card_last4"] for item in items if item["card_last4"]}),
        "candidates": items,
        "skipped": skipped,
    }


def _iso(text: str) -> str:
    day, month, year = text.split(".")
    return f"{year}-{month}-{day}"


def parse_statement(
    data: bytes,
    declared_format: str | None = None,
    bank: str = "auto",
    user_rules: Sequence[Mapping[str, Any]] = (),
    now: datetime | None = None,
) -> dict[str, Any]:
    """Parse the bytes of a statement. Raises :class:`StatementError`. ``now``: the moment a
    closing balance may not pass (the API gives the server clock; ``None`` means no limit)."""
    fmt = detect_format(data, declared_format)
    deadline = time.monotonic() + PARSE_SECONDS
    for table in extract_tables(fmt, data, deadline):
        _expired(deadline)
        result = parse_table(table, bank, user_rules, now)
        if result is not None:
            return {"format": fmt, **result}
    raise StatementError("statement_unrecognized", "no table with a date and an amount was found")
