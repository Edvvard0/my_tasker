"""Reference calculations of the Work module (spec: ``docs/specs/stage4_work.md``, section 4).

Pure functions over JSON-shaped rows (dicts with the table column names, instants as
``YYYY-MM-DDTHH:MM:SSZ``, dates as ``YYYY-MM-DD``), so the shared vectors, the AI tools and the
Dart client all run the same rules. Money is integer kopecks and is **never rounded**: it is only
added and subtracted. The two divisions (income per hour, paid share) round down.
"""

from collections import defaultdict
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

Row = Mapping[str, Any]
Rows = Sequence[Row]

MOSCOW_OFFSET = timedelta(hours=3)  # Europe/Moscow has no DST since 2014-10-26
DEFAULT_STATUS = "active"
DEBT_STATUSES = ("active", "paused", "completed")  # leads and cancelled projects owe nothing


def parse_instant(text: str) -> datetime:
    """Parse an ISO instant; fractions of a second are dropped (all rules work in whole seconds)."""
    return (
        datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(UTC).replace(microsecond=0)
    )


def moscow_date(instant: str) -> str:
    """The Moscow calendar date (``YYYY-MM-DD``) of an instant."""
    return (parse_instant(instant) + MOSCOW_OFFSET).date().isoformat()


def moscow_month(instant: str) -> str:
    return moscow_date(instant)[:7]


def per_hour(amount: int, seconds: int) -> int | None:
    """Kopecks per hour, rounded down; ``None`` when there are no hours."""
    return None if seconds <= 0 else amount * 3600 // seconds


def paid_basis_points(received: int, total: int) -> int:
    """Paid share in 1/100 of a percent, rounded down (never 100 % before it is fully paid)."""
    return 0 if total <= 0 else received * 10_000 // total


def hourly_billable(rate: int, seconds: int) -> int:
    """What the time on an hourly project is worth, rounded down to a kopeck."""
    return rate * seconds // 3600


def entry_seconds(entry: Row) -> int | None:
    """Whole seconds of a finished entry (fractions dropped); ``None`` while it is running."""
    if entry.get("ended_at") is None:
        return None
    delta = parse_instant(entry["ended_at"]) - parse_instant(entry["started_at"])
    return int(delta.total_seconds())


def in_period(day: str | None, period: Row | None) -> bool:
    """``period`` = ``{"from": date|None, "to": date|None}``, inclusive; ``None`` = all time."""
    if period is None:
        return True
    if day is None:
        return False
    first, last = period.get("from"), period.get("to")
    return (first is None or day >= first) and (last is None or day <= last)


def _status(project: Row) -> str:
    return project.get("status") or DEFAULT_STATUS


def project_total(project: Row, change_requests: Rows) -> int:
    """Base amount plus change requests that are not cancelled."""
    extra = sum(
        cr["amount"]
        for cr in change_requests
        if cr["project_id"] == project["id"] and cr["status"] != "cancelled"
    )
    return int(project.get("base_amount") or 0) + int(extra)


def project_received(project: Row, allocations: Rows) -> int:
    return sum(a["amount"] for a in allocations if a["project_id"] == project["id"])


def project_summary(project: Row, change_requests: Rows, allocations: Rows) -> dict[str, Any]:
    """Totals of one project; ``remaining`` is signed (negative = overpaid)."""
    mine = [cr for cr in change_requests if cr["project_id"] == project["id"]]
    paid = [a for a in allocations if a["project_id"] == project["id"]]
    total = project_total(project, change_requests)
    received = sum(a["amount"] for a in paid)
    known = {cr["id"] for cr in mine}
    base_received = sum(
        a["amount"] for a in paid if a.get("change_request_id") not in known
    )  # null or dangling link = paid towards the base amount
    rows = []
    for cr in mine:
        got = sum(a["amount"] for a in paid if a.get("change_request_id") == cr["id"])
        cancelled = cr["status"] == "cancelled"
        rows.append(
            {
                "id": cr["id"],
                "amount": cr["amount"],
                "received": got,
                "remaining": 0 if cancelled else cr["amount"] - got,
            }
        )
    base = int(project.get("base_amount") or 0)
    return {
        "total": total,
        "received": received,
        "remaining": total - received,
        "overpaid": max(0, received - total),
        "paid_bp": paid_basis_points(received, total),
        "base_received": base_received,
        "base_remaining": base - base_received,
        "change_requests": rows,
    }


def receivables(projects: Rows, change_requests: Rows, allocations: Rows) -> dict[str, Any]:
    """Who owes how much: per customer, over projects that are active, paused or completed.

    A project owes ``max(0, total - received)``: an overpaid project does not cancel a debt of
    another one. Customers without debt are left out; ``client_id`` may be ``None``.
    """
    groups: dict[str | None, list[dict[str, Any]]] = defaultdict(list)
    for project in projects:
        if _status(project) not in DEBT_STATUSES:
            continue
        total = project_total(project, change_requests)
        debt = max(0, total - project_received(project, allocations))
        if debt > 0:
            groups[project.get("client_id")].append({"id": project["id"], "remaining": debt})
    clients = []
    for client_id, rows in groups.items():
        rows.sort(key=lambda r: (-r["remaining"], r["id"]))
        clients.append(
            {
                "client_id": client_id,
                "remaining": sum(r["remaining"] for r in rows),
                "projects": rows,
            }
        )
    clients.sort(key=lambda c: (-c["remaining"], c["client_id"] is None, c["client_id"] or ""))
    return {"total": sum(c["remaining"] for c in clients), "clients": clients}


def income(
    projects: Rows,
    change_requests: Rows,
    payments: Rows,
    allocations: Rows,
    time_entries: Rows,
    period: Row | None = None,
    project_id: str | None = None,
) -> dict[str, Any]:
    """Hours and income per hour, by fact (received) and by accrual, for a period.

    Fact: allocations whose payment date (Moscow) is in the period. Accrual: change requests
    closed in the period plus the base amount of projects completed in the period. Hours: only
    finished billable entries started (Moscow date) in the period. Per-hour values are totals
    divided by total seconds, not averages of project values.
    """
    paid_on = {p["id"]: moscow_date(p["paid_at"]) for p in payments}
    chosen = [p for p in projects if project_id in (None, p["id"])]
    rows: list[dict[str, Any]] = []
    for project in chosen:
        pid = project["id"]
        received = sum(
            a["amount"]
            for a in allocations
            if a["project_id"] == pid and in_period(paid_on.get(a["payment_id"]), period)
        )
        accrued = sum(
            cr["amount"]
            for cr in change_requests
            if cr["project_id"] == pid
            and cr["status"] == "closed"
            and in_period(cr.get("closed_date"), period)
        )
        if _status(project) == "completed" and in_period(project.get("completed_date"), period):
            accrued += int(project.get("base_amount") or 0)
        seconds = 0
        for entry in time_entries:
            if entry["project_id"] != pid or not entry["billable"]:
                continue
            length = entry_seconds(entry)
            if length is not None and in_period(moscow_date(entry["started_at"]), period):
                seconds += length
        rows.append(
            {
                "id": pid,
                "seconds": seconds,
                "received": received,
                "accrued": accrued,
                "per_hour_fact": per_hour(received, seconds),
                "per_hour_accrued": per_hour(accrued, seconds),
            }
        )
    seconds = sum(r["seconds"] for r in rows)
    received = sum(r["received"] for r in rows)
    accrued = sum(r["accrued"] for r in rows)
    return {
        "seconds": seconds,
        "received": received,
        "accrued": accrued,
        "per_hour_fact": per_hour(received, seconds),
        "per_hour_accrued": per_hour(accrued, seconds),
        "projects": rows,
    }


def monthly_received(
    payments: Rows, allocations: Rows, project_id: str | None = None
) -> list[dict[str, Any]]:
    """Received money per Moscow month of the payment date (the Excel month columns).

    ``unallocated`` = payments of the month minus all their allocations (``None`` when a project
    filter is given, since it is not a property of one project). Months ascending; months
    without allocations and without unallocated money are omitted.
    """
    month_of = {p["id"]: moscow_month(p["paid_at"]) for p in payments}
    received: dict[str, int] = defaultdict(int)
    allocated: dict[str, int] = defaultdict(int)
    for a in allocations:
        month = month_of.get(a["payment_id"])
        if month is None:
            continue
        allocated[month] += a["amount"]
        if project_id in (None, a["project_id"]):
            received[month] += a["amount"]
    gross: dict[str, int] = defaultdict(int)
    for p in payments:
        gross[month_of[p["id"]]] += p["amount"]
    out = []
    for month in sorted(set(received) | set(gross)):
        free = gross[month] - allocated[month]
        if project_id is not None and received[month] == 0:
            continue
        if project_id is None and received[month] == 0 and free == 0:
            continue
        out.append(
            {
                "month": month,
                "received": received[month],
                "unallocated": None if project_id is not None else free,
            }
        )
    return out


def integrity_problems(
    change_requests: Rows, payments: Rows, allocations: Rows
) -> list[dict[str, Any]]:
    """Facts the server cannot reject row by row (spec 3.3): over-allocated payments, an
    allocation pointing to a change request of another project. Sorted by ``code``, ``id``."""
    found: list[dict[str, Any]] = []
    spent: dict[str, int] = defaultdict(int)
    for a in allocations:
        spent[a["payment_id"]] += a["amount"]
    for p in payments:
        if spent[p["id"]] > p["amount"]:
            found.append(
                {"code": "over_allocated", "id": p["id"], "excess": spent[p["id"]] - p["amount"]}
            )
    owner = {cr["id"]: cr["project_id"] for cr in change_requests}
    for a in allocations:
        link = a.get("change_request_id")
        if link in owner and owner[link] != a["project_id"]:
            found.append({"code": "change_request_mismatch", "id": a["id"], "excess": None})
    found.sort(key=lambda f: (f["code"], f["id"]))
    return found
