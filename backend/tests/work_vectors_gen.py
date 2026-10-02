"""Builds ``shared-test-vectors/work/*.json``: inputs are written here, expected values come from
the reference implementation (``tasker.work.reference``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.work_vectors_gen``. A test checks that the files
on disk are exactly this output.
"""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

from tasker.work import reference as ref

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "work"
Case = tuple[str, dict[str, Any]]  # (name, input)


def proj(pid: str, base: int | None = 0, **over: Any) -> dict[str, Any]:
    return {"id": pid, "base_amount": base, "status": "active", "client_id": None, **over}


def cr(cid: str, project: str, amount: int, status: str = "in_progress", **over: Any) -> Any:
    return {"id": cid, "project_id": project, "amount": amount, "status": status, **over}


def pay(pid: str, at: str, amount: int) -> dict[str, Any]:
    return {"id": pid, "paid_at": at, "amount": amount}


def alloc(aid: str, payment: str, project: str, amount: int, link: str | None = None) -> Any:
    return {
        "id": aid,
        "payment_id": payment,
        "project_id": project,
        "change_request_id": link,
        "amount": amount,
    }


def entry(project: str, start: str, end: str | None, billable: bool = True) -> dict[str, Any]:
    return {"project_id": project, "started_at": start, "ended_at": end, "billable": billable}


def hours(project: str, day: str, hours_: int, billable: bool = True) -> dict[str, Any]:
    """An entry that starts at 07:00Z (10:00 Moscow) on ``day`` and lasts ``hours_`` hours."""
    return entry(project, f"{day}T07:00:00Z", f"{day}T{7 + hours_:02d}:00:00Z", billable)


# ------------------------------------------------------------------ scalars

SCALARS: list[Case] = [
    ("paid_bp_zero", {"op": "paid_bp", "received": 0, "total": 100000}),
    ("paid_bp_half", {"op": "paid_bp", "received": 50000, "total": 100000}),
    ("paid_bp_full", {"op": "paid_bp", "received": 100000, "total": 100000}),
    ("paid_bp_third_floors", {"op": "paid_bp", "received": 1, "total": 3}),
    ("paid_bp_two_thirds_floors", {"op": "paid_bp", "received": 2, "total": 3}),
    ("paid_bp_almost_full_not_100", {"op": "paid_bp", "received": 99999, "total": 100000}),
    ("paid_bp_overpaid", {"op": "paid_bp", "received": 150000, "total": 100000}),
    ("paid_bp_zero_total", {"op": "paid_bp", "received": 5, "total": 0}),
    (
        "paid_bp_huge",
        {"op": "paid_bp", "received": 99_999_999_999_998, "total": 99_999_999_999_999},
    ),
    ("per_hour_exact", {"op": "per_hour", "amount": 1_000_000, "seconds": 36000}),
    ("per_hour_floors", {"op": "per_hour", "amount": 100000, "seconds": 10800}),
    ("per_hour_zero_seconds", {"op": "per_hour", "amount": 100000, "seconds": 0}),
    ("per_hour_zero_amount", {"op": "per_hour", "amount": 0, "seconds": 3600}),
    ("per_hour_under_one_kopeck", {"op": "per_hour", "amount": 1, "seconds": 7200}),
    ("per_hour_one_second", {"op": "per_hour", "amount": 1, "seconds": 1}),
    ("per_hour_huge", {"op": "per_hour", "amount": 99_999_999_999_999, "seconds": 3600 * 7}),
    ("hourly_billable_exact", {"op": "hourly_billable", "rate": 150000, "seconds": 7200}),
    ("hourly_billable_floors", {"op": "hourly_billable", "rate": 100, "seconds": 1799}),
    ("hourly_billable_zero", {"op": "hourly_billable", "rate": 150000, "seconds": 0}),
    (
        "seconds_one_hour",
        {"op": "seconds", "entry": entry("p", "2026-10-05T07:00:00Z", "2026-10-05T08:00:00Z")},
    ),
    (
        "seconds_zero_length",
        {"op": "seconds", "entry": entry("p", "2026-10-05T07:00:00Z", "2026-10-05T07:00:00Z")},
    ),
    (
        "seconds_running_is_null",
        {"op": "seconds", "entry": entry("p", "2026-10-05T07:00:00Z", None)},
    ),
    (
        "seconds_across_midnight",
        {"op": "seconds", "entry": entry("p", "2026-10-05T22:30:00Z", "2026-10-06T01:15:30Z")},
    ),
    (
        "seconds_fractions_dropped_before_subtracting",
        {
            "op": "seconds",
            "entry": entry("p", "2026-10-05T07:00:00.900Z", "2026-10-05T07:00:01.100Z"),
        },
    ),
    (
        "seconds_offset_input",
        {"op": "seconds", "entry": entry("p", "2026-10-05T10:00:00+03:00", "2026-10-05T08:00:00Z")},
    ),
    ("moscow_date_morning", {"op": "moscow_date", "at": "2026-10-05T07:00:00Z"}),
    (
        "moscow_date_just_before_midnight_utc_is_next_day",
        {"op": "moscow_date", "at": "2026-10-05T21:00:00Z"},
    ),
    ("moscow_date_last_second_of_day", {"op": "moscow_date", "at": "2026-10-05T20:59:59Z"}),
    ("moscow_date_new_year", {"op": "moscow_date", "at": "2026-12-31T21:00:00Z"}),
    ("moscow_date_leap_day", {"op": "moscow_date", "at": "2028-02-28T21:30:00Z"}),
    ("moscow_date_summer_no_dst", {"op": "moscow_date", "at": "2026-07-01T20:59:59Z"}),
    ("moscow_month_boundary", {"op": "moscow_month", "at": "2026-09-30T21:00:00Z"}),
]


def run_scalar(given: dict[str, Any]) -> Any:
    op = given["op"]
    if op == "paid_bp":
        return ref.paid_basis_points(given["received"], given["total"])
    if op == "per_hour":
        return ref.per_hour(given["amount"], given["seconds"])
    if op == "hourly_billable":
        return ref.hourly_billable(given["rate"], given["seconds"])
    if op == "seconds":
        return ref.entry_seconds(given["entry"])
    if op == "moscow_date":
        return ref.moscow_date(given["at"])
    return ref.moscow_month(given["at"])


# ------------------------------------------------------------------ project_summary

P1 = proj("p1", 100000)
SUMMARY: list[Case] = [
    ("no_payments", {"project": P1, "change_requests": [], "allocations": []}),
    (
        "partial_payment_on_base",
        {"project": P1, "change_requests": [], "allocations": [alloc("a1", "x", "p1", 40000)]},
    ),
    (
        "two_payments_fully_paid",
        {
            "project": P1,
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 60000), alloc("a2", "y", "p1", 40000)],
        },
    ),
    (
        "overpayment",
        {"project": P1, "change_requests": [], "allocations": [alloc("a1", "x", "p1", 130000)]},
    ),
    (
        "no_change_requests_zero_base",
        {"project": proj("p1", 0), "change_requests": [], "allocations": []},
    ),
    (
        "legacy_project_without_base_amount",
        {"project": proj("p1", None), "change_requests": [cr("c1", "p1", 5000)], "allocations": []},
    ),
    (
        "change_requests_open_and_closed_count_cancelled_does_not",
        {
            "project": P1,
            "change_requests": [
                cr("c1", "p1", 20000),
                cr("c2", "p1", 30000, "closed", closed_date="2026-09-01"),
                cr("c3", "p1", 99999, "cancelled"),
            ],
            "allocations": [],
        },
    ),
    (
        "one_payment_split_over_two_change_requests",
        {
            "project": proj("p1", 0),
            "change_requests": [cr("c1", "p1", 30000), cr("c2", "p1", 50000)],
            "allocations": [
                alloc("a1", "x", "p1", 30000, "c1"),
                alloc("a2", "x", "p1", 20000, "c2"),
            ],
        },
    ),
    (
        "change_request_paid_in_parts",
        {
            "project": proj("p1", 0),
            "change_requests": [cr("c1", "p1", 90000)],
            "allocations": [
                alloc("a1", "x", "p1", 30000, "c1"),
                alloc("a2", "y", "p1", 30000, "c1"),
            ],
        },
    ),
    (
        "payment_to_cancelled_change_request_still_counts",
        {
            "project": P1,
            "change_requests": [cr("c1", "p1", 40000, "cancelled")],
            "allocations": [alloc("a1", "x", "p1", 15000, "c1")],
        },
    ),
    (
        "change_request_overpaid_is_negative",
        {
            "project": proj("p1", 0),
            "change_requests": [cr("c1", "p1", 10000)],
            "allocations": [alloc("a1", "x", "p1", 12000, "c1")],
        },
    ),
    (
        "dangling_change_request_link_counts_as_base",
        {
            "project": P1,
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 25000, "deleted-cr")],
        },
    ),
    (
        "other_projects_are_ignored",
        {
            "project": P1,
            "change_requests": [cr("c9", "p2", 77777)],
            "allocations": [alloc("a1", "x", "p2", 50000), alloc("a2", "x", "p1", 10000)],
        },
    ),
    (
        "paid_share_rounds_down",
        {
            "project": proj("p1", 3),
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 1)],
        },
    ),
    (
        "base_and_change_requests_paid_separately",
        {
            "project": P1,
            "change_requests": [cr("c1", "p1", 50000, "closed", closed_date="2026-09-01")],
            "allocations": [alloc("a1", "x", "p1", 100000), alloc("a2", "y", "p1", 20000, "c1")],
        },
    ),
]

# ------------------------------------------------------------------ receivables

R_ROMA, R_ELENA = "roma", "elena"
RECEIVABLES: list[Case] = [
    ("empty", {"projects": [], "change_requests": [], "allocations": []}),
    (
        "one_customer_one_project",
        {
            "projects": [proj("p1", 100000, client_id=R_ROMA)],
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 30000)],
        },
    ),
    (
        "several_customers_and_total",
        {
            "projects": [
                proj("p1", 100000, client_id=R_ROMA),
                proj("p2", 250000, client_id=R_ELENA),
                proj("p3", 40000, client_id=R_ROMA),
            ],
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 100000), alloc("a2", "y", "p2", 50000)],
        },
    ),
    (
        "projects_of_one_customer_sorted_by_remaining",
        {
            "projects": [
                proj("p1", 10000, client_id=R_ROMA),
                proj("p2", 90000, client_id=R_ROMA),
                proj("p3", 50000, client_id=R_ROMA),
            ],
            "change_requests": [],
            "allocations": [],
        },
    ),
    (
        "lead_project_is_not_a_debt",
        {
            "projects": [
                proj("p1", 100000, client_id=R_ROMA, status="lead"),
                proj("p2", 3000, client_id=R_ELENA, status="paused"),
            ],
            "change_requests": [],
            "allocations": [],
        },
    ),
    (
        "cancelled_project_is_not_a_debt",
        {
            "projects": [
                proj("p1", 100000, client_id=R_ROMA, status="cancelled"),
                proj("p2", 5000, client_id=R_ROMA),
            ],
            "change_requests": [],
            "allocations": [],
        },
    ),
    (
        "fully_paid_customer_is_left_out",
        {
            "projects": [proj("p1", 100000, client_id=R_ROMA), proj("p2", 1000, client_id=R_ELENA)],
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 100000)],
        },
    ),
    (
        "overpaid_project_does_not_offset_another_debt",
        {
            "projects": [proj("p1", 100000, client_id=R_ROMA), proj("p2", 70000, client_id=R_ROMA)],
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 150000)],
        },
    ),
    (
        "completed_project_with_unpaid_rest_still_owed",
        {
            "projects": [
                proj(
                    "p1", 100000, client_id=R_ROMA, status="completed", completed_date="2026-09-01"
                )
            ],
            "change_requests": [],
            "allocations": [alloc("a1", "x", "p1", 60000)],
        },
    ),
    (
        "cancelled_change_request_is_not_a_debt",
        {
            "projects": [proj("p1", 10000, client_id=R_ELENA)],
            "change_requests": [
                cr("c1", "p1", 20000),
                cr("c2", "p1", 50000, "cancelled"),
                cr("c3", "p1", 5000, "closed", closed_date="2026-09-02"),
            ],
            "allocations": [alloc("a1", "x", "p1", 5000, "c3")],
        },
    ),
    (
        "project_without_customer_goes_last",
        {
            "projects": [proj("p1", 1000), proj("p2", 1000, client_id=R_ROMA)],
            "change_requests": [],
            "allocations": [],
        },
    ),
    (
        "equal_debts_sorted_by_customer_id",
        {
            "projects": [proj("p1", 5000, client_id="b"), proj("p2", 5000, client_id="a")],
            "change_requests": [],
            "allocations": [],
        },
    ),
    (
        "missing_status_is_active_and_lead_is_excluded",
        {
            "projects": [
                proj("p1", 1000, client_id=R_ROMA, status=None),
                proj("p2", 2000, client_id=R_ROMA, status="lead"),
                proj("p3", 4000, client_id=R_ROMA, status="paused"),
            ],
            "change_requests": [],
            "allocations": [],
        },
    ),
]

# ------------------------------------------------------------------ income

INCOME_PROJECTS = [proj("p1", 0), proj("p2", 0)]


def inc(**over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "projects": [proj("p1", 0)],
        "change_requests": [],
        "payments": [],
        "allocations": [],
        "time_entries": [],
        "period": None,
        "project_id": None,
    }
    return base | over


PAID = [pay("x", "2026-10-05T09:00:00Z", 1_000_000)]
INCOME: list[Case] = [
    ("zero_hours_gives_no_rate", inc(payments=PAID, allocations=[alloc("a", "x", "p1", 500000)])),
    (
        "fact_exact_rate",
        inc(
            payments=PAID,
            allocations=[alloc("a", "x", "p1", 1_000_000)],
            time_entries=[hours("p1", "2026-10-05", 10)],
        ),
    ),
    (
        "fact_rate_rounds_down",
        inc(
            payments=[pay("x", "2026-10-05T09:00:00Z", 100000)],
            allocations=[alloc("a", "x", "p1", 100000)],
            time_entries=[hours("p1", "2026-10-05", 3)],
        ),
    ),
    (
        "non_billable_entries_are_not_hours",
        inc(
            payments=PAID,
            allocations=[alloc("a", "x", "p1", 400000)],
            time_entries=[
                hours("p1", "2026-10-05", 2),
                hours("p1", "2026-10-06", 8, billable=False),
            ],
        ),
    ),
    (
        "running_timer_is_not_counted",
        inc(
            payments=PAID,
            allocations=[alloc("a", "x", "p1", 400000)],
            time_entries=[hours("p1", "2026-10-05", 2), entry("p1", "2026-10-07T07:00:00Z", None)],
        ),
    ),
    (
        "accrual_closed_change_requests_and_completed_base",
        inc(
            projects=[proj("p1", 500000, status="completed", completed_date="2026-10-01")],
            change_requests=[
                cr("c1", "p1", 100000, "closed", closed_date="2026-09-20"),
                cr("c2", "p1", 70000, "in_progress"),
                cr("c3", "p1", 30000, "cancelled"),
            ],
            time_entries=[hours("p1", "2026-09-10", 5)],
        ),
    ),
    (
        "accrual_base_of_active_project_does_not_count",
        inc(
            projects=[proj("p1", 500000)],
            change_requests=[cr("c1", "p1", 100000, "closed", closed_date="2026-09-20")],
            time_entries=[hours("p1", "2026-09-10", 4)],
        ),
    ),
    (
        "fact_and_accrual_differ",
        inc(
            projects=[proj("p1", 300000, status="completed", completed_date="2026-10-03")],
            payments=[pay("x", "2026-10-05T09:00:00Z", 100000)],
            allocations=[alloc("a", "x", "p1", 100000)],
            time_entries=[hours("p1", "2026-10-02", 6)],
        ),
    ),
    (
        "totals_are_not_an_average_of_projects",
        inc(
            projects=INCOME_PROJECTS,
            payments=[pay("x", "2026-10-05T09:00:00Z", 900000)],
            allocations=[alloc("a", "x", "p1", 100000), alloc("b", "x", "p2", 800000)],
            time_entries=[hours("p1", "2026-10-02", 1), hours("p2", "2026-10-02", 8)],
        ),
    ),
    (
        "project_filter_by_id",
        inc(
            projects=INCOME_PROJECTS,
            payments=[pay("x", "2026-10-05T09:00:00Z", 900000)],
            allocations=[alloc("a", "x", "p1", 100000), alloc("b", "x", "p2", 800000)],
            time_entries=[hours("p1", "2026-10-02", 1), hours("p2", "2026-10-02", 8)],
            project_id="p2",
        ),
    ),
    (
        "period_uses_moscow_payment_date",
        inc(
            payments=[
                pay("x", "2026-09-30T20:59:59Z", 100000),
                pay("y", "2026-09-30T21:00:00Z", 200000),
            ],
            allocations=[alloc("a", "x", "p1", 100000), alloc("b", "y", "p1", 200000)],
            time_entries=[hours("p1", "2026-10-02", 1)],
            period={"from": "2026-10-01", "to": "2026-10-31"},
        ),
    ),
    (
        "period_uses_moscow_start_date_of_entries",
        inc(
            payments=PAID,
            allocations=[alloc("a", "x", "p1", 100000)],
            time_entries=[
                entry("p1", "2026-09-30T20:00:00Z", "2026-09-30T21:00:00Z"),
                entry("p1", "2026-09-30T21:00:00Z", "2026-09-30T23:00:00Z"),
                entry("p1", "2026-10-31T20:59:00Z", "2026-10-31T21:59:00Z"),
            ],
            period={"from": "2026-10-01", "to": "2026-10-31"},
        ),
    ),
    (
        "period_filters_accrual_by_closed_and_completed_dates",
        inc(
            projects=[proj("p1", 200000, status="completed", completed_date="2026-10-15")],
            change_requests=[
                cr("c1", "p1", 10000, "closed", closed_date="2026-09-30"),
                cr("c2", "p1", 20000, "closed", closed_date="2026-10-01"),
                cr("c3", "p1", 40000, "closed", closed_date="2026-10-31"),
                cr("c4", "p1", 80000, "closed", closed_date="2026-11-01"),
            ],
            time_entries=[hours("p1", "2026-10-02", 2)],
            period={"from": "2026-10-01", "to": "2026-10-31"},
        ),
    ),
    (
        "open_ended_period",
        inc(
            payments=[
                pay("x", "2026-08-05T09:00:00Z", 10000),
                pay("y", "2026-10-05T09:00:00Z", 20000),
            ],
            allocations=[alloc("a", "x", "p1", 10000), alloc("b", "y", "p1", 20000)],
            time_entries=[hours("p1", "2026-08-05", 1), hours("p1", "2026-10-05", 1)],
            period={"from": "2026-09-01", "to": None},
        ),
    ),
    (
        "allocation_of_unknown_payment_is_ignored",
        inc(
            payments=PAID,
            allocations=[alloc("a", "x", "p1", 10000), alloc("b", "ghost", "p1", 99999)],
            time_entries=[hours("p1", "2026-10-05", 1)],
        ),
    ),
    ("empty_everything", inc(projects=[])),
    (
        "time_on_a_project_without_money",
        inc(time_entries=[hours("p1", "2026-10-05", 3)]),
    ),
]

# ------------------------------------------------------------------ monthly

MONTHLY: list[Case] = [
    ("empty", {"payments": [], "allocations": [], "project_id": None}),
    (
        "two_months_ascending",
        {
            "payments": [
                pay("y", "2026-10-05T09:00:00Z", 20000),
                pay("x", "2026-09-05T09:00:00Z", 10000),
            ],
            "allocations": [alloc("a", "x", "p1", 10000), alloc("b", "y", "p1", 20000)],
            "project_id": None,
        },
    ),
    (
        "moscow_midnight_moves_payment_to_next_month",
        {
            "payments": [
                pay("x", "2026-09-30T20:59:59Z", 100),
                pay("y", "2026-09-30T21:00:00Z", 200),
            ],
            "allocations": [alloc("a", "x", "p1", 100), alloc("b", "y", "p1", 200)],
            "project_id": None,
        },
    ),
    (
        "new_year_boundary",
        {
            "payments": [pay("x", "2026-12-31T21:00:00Z", 500)],
            "allocations": [alloc("a", "x", "p1", 500)],
            "project_id": None,
        },
    ),
    (
        "several_projects_in_one_month_add_up",
        {
            "payments": [
                pay("x", "2026-10-05T09:00:00Z", 900),
                pay("y", "2026-10-20T09:00:00Z", 100),
            ],
            "allocations": [
                alloc("a", "x", "p1", 400),
                alloc("b", "x", "p2", 500),
                alloc("c", "y", "p1", 100),
            ],
            "project_id": None,
        },
    ),
    (
        "partly_allocated_payment_leaves_unallocated",
        {
            "payments": [pay("x", "2026-10-05T09:00:00Z", 1000)],
            "allocations": [alloc("a", "x", "p1", 600)],
            "project_id": None,
        },
    ),
    (
        "payment_without_allocations",
        {
            "payments": [pay("x", "2026-10-05T09:00:00Z", 1000)],
            "allocations": [],
            "project_id": None,
        },
    ),
    (
        "fully_allocated_month_has_zero_unallocated",
        {
            "payments": [pay("x", "2026-10-05T09:00:00Z", 1000)],
            "allocations": [alloc("a", "x", "p1", 1000)],
            "project_id": None,
        },
    ),
    (
        "project_filter_hides_other_projects_and_unallocated",
        {
            "payments": [
                pay("x", "2026-10-05T09:00:00Z", 1000),
                pay("y", "2026-11-05T09:00:00Z", 50),
            ],
            "allocations": [
                alloc("a", "x", "p1", 600),
                alloc("b", "x", "p2", 400),
                alloc("c", "y", "p2", 50),
            ],
            "project_id": "p1",
        },
    ),
    (
        "allocation_of_unknown_payment_is_ignored",
        {
            "payments": [pay("x", "2026-10-05T09:00:00Z", 100)],
            "allocations": [alloc("a", "x", "p1", 100), alloc("b", "ghost", "p1", 7)],
            "project_id": None,
        },
    ),
]

# ------------------------------------------------------------------ integrity

INTEGRITY: list[Case] = [
    (
        "clean",
        {
            "change_requests": [],
            "payments": [pay("x", "2026-10-05T09:00:00Z", 100)],
            "allocations": [alloc("a", "x", "p1", 100)],
        },
    ),
    (
        "over_allocated_by_two_allocations",
        {
            "change_requests": [],
            "payments": [pay("x", "2026-10-05T09:00:00Z", 100)],
            "allocations": [alloc("a", "x", "p1", 70), alloc("b", "x", "p2", 50)],
        },
    ),
    (
        "change_request_of_another_project",
        {
            "change_requests": [cr("c1", "p2", 10)],
            "payments": [pay("x", "2026-10-05T09:00:00Z", 100)],
            "allocations": [alloc("a", "x", "p1", 10, "c1")],
        },
    ),
    (
        "both_problems_sorted_by_code",
        {
            "change_requests": [cr("c1", "p2", 10)],
            "payments": [pay("x", "2026-10-05T09:00:00Z", 5)],
            "allocations": [alloc("a", "x", "p1", 10, "c1")],
        },
    ),
]

FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "scalars": (
        "Scalar rules: paid_bp, per_hour, hourly_billable, seconds, moscow_date, moscow_month "
        "(input.op selects the function)",
        SCALARS,
        run_scalar,
    ),
    "project_summary": (
        "project_summary(project, change_requests, allocations)",
        SUMMARY,
        lambda g: ref.project_summary(g["project"], g["change_requests"], g["allocations"]),
    ),
    "receivables": (
        "receivables(projects, change_requests, allocations)",
        RECEIVABLES,
        lambda g: ref.receivables(g["projects"], g["change_requests"], g["allocations"]),
    ),
    "income": (
        "income(projects, change_requests, payments, allocations, time_entries, period, project)",
        INCOME,
        lambda g: ref.income(
            g["projects"],
            g["change_requests"],
            g["payments"],
            g["allocations"],
            g["time_entries"],
            g["period"],
            g["project_id"],
        ),
    ),
    "monthly": (
        "monthly_received(payments, allocations, project_id)",
        MONTHLY,
        lambda g: ref.monthly_received(g["payments"], g["allocations"], g["project_id"]),
    ),
    "integrity": (
        "integrity_problems(change_requests, payments, allocations)",
        INTEGRITY,
        lambda g: ref.integrity_problems(g["change_requests"], g["payments"], g["allocations"]),
    ),
}


def build() -> dict[str, str]:
    """File name -> exact text of the file."""
    files = {}
    for name, (description, cases, run) in FILES.items():
        names = [case_name for case_name, _ in cases]
        assert len(names) == len(set(names)), f"duplicate case names in {name}"
        document = {
            "description": description,
            "cases": [{"name": n, "input": given, "expected": run(given)} for n, given in cases],
        }
        files[f"{name}.json"] = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    return files


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for file_name, text in build().items():
        (OUT / file_name).write_text(text, encoding="utf-8")
    print(f"wrote {len(FILES)} files to {OUT}")  # noqa: T201


if __name__ == "__main__":
    main()
