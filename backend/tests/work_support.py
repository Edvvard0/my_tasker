"""Builders of valid Stage 4 rows and a seeded Work graph (the worked example of the spec)."""

import uuid
from dataclasses import dataclass
from typing import Any

from tasker.ids import uuid7
from tests.api_support import DeviceClient

PAID_AT = "2026-10-05T09:00:00Z"
STARTED = "2026-10-05T07:00:00Z"
ENDED = "2026-10-05T09:00:00Z"


def project_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {"title": "Сайт Ромы", "archived": False, "created_at": dc.created(), **over}


def person_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {"name": "Рома", "archived": False, "created_at": dc.created(), **over}


def cr_fields(dc: DeviceClient, project: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "project_id": str(project),
        "title": "Корзина",
        "amount": 3_000_000,
        "status": "in_progress",
        "created_at": dc.created(),
        **over,
    }


def payment_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {"paid_at": PAID_AT, "amount": 7_000_000, "created_at": dc.created(), **over}


def allocation_fields(
    dc: DeviceClient, payment: uuid.UUID, project: uuid.UUID, **over: Any
) -> dict[str, Any]:
    return {
        "payment_id": str(payment),
        "project_id": str(project),
        "amount": 1_000_000,
        "created_at": dc.created(),
        **over,
    }


def entry_fields(dc: DeviceClient, project: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "project_id": str(project),
        "started_at": STARTED,
        "ended_at": ENDED,
        "billable": True,
        "source": "manual",
        "created_at": dc.created(),
        **over,
    }


@dataclass
class WorkSeed:
    roma: uuid.UUID
    project: uuid.UUID
    cart: uuid.UUID  # closed change request
    filters: uuid.UUID  # in progress
    chat: uuid.UUID  # cancelled
    payment: uuid.UUID
    payment2: uuid.UUID
    alloc_base: uuid.UUID
    alloc_cart: uuid.UUID
    alloc_cart2: uuid.UUID
    entry: uuid.UUID
    entry_free: uuid.UUID  # not billable


def work_seed_ops(dc: DeviceClient) -> tuple[WorkSeed, list[dict[str, Any]]]:
    s = WorkSeed(*(uuid7() for _ in range(12)))
    ops = [
        dc.op("people", s.roma, fields=person_fields(dc, role="client", contact="@roma")),
        dc.op(
            "projects",
            s.project,
            fields=project_fields(
                dc, client_id=str(s.roma), status="active", pay_type="fixed", base_amount=10_000_000
            ),
        ),
        dc.op(
            "change_requests",
            s.cart,
            fields=cr_fields(dc, s.project, status="closed", closed_date="2026-10-01"),
        ),
        dc.op(
            "change_requests",
            s.filters,
            fields=cr_fields(dc, s.project, title="Фильтры", amount=2_000_000),
        ),
        dc.op(
            "change_requests",
            s.chat,
            fields=cr_fields(dc, s.project, title="Чат", amount=1_500_000, status="cancelled"),
        ),
        dc.op("payments", s.payment, fields=payment_fields(dc, payer_id=str(s.roma))),
        dc.op(
            "payments",
            s.payment2,
            fields=payment_fields(dc, amount=2_000_000, paid_at="2026-11-02T09:00:00Z"),
        ),
        dc.op(
            "payment_allocations",
            s.alloc_base,
            fields=allocation_fields(dc, s.payment, s.project, amount=6_000_000),
        ),
        dc.op(
            "payment_allocations",
            s.alloc_cart,
            fields=allocation_fields(
                dc, s.payment, s.project, amount=1_000_000, change_request_id=str(s.cart)
            ),
        ),
        dc.op(
            "payment_allocations",
            s.alloc_cart2,
            fields=allocation_fields(
                dc, s.payment2, s.project, amount=2_000_000, change_request_id=str(s.cart)
            ),
        ),
        dc.op("time_entries", s.entry, fields=entry_fields(dc, s.project)),
        dc.op(
            "time_entries",
            s.entry_free,
            fields=entry_fields(
                dc,
                s.project,
                billable=False,
                started_at="2026-10-06T07:00:00Z",
                ended_at="2026-10-06T10:00:00Z",
            ),
        ),
    ]
    return s, ops


async def work_seed(dc: DeviceClient) -> WorkSeed:
    graph, ops = work_seed_ops(dc)
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return graph
