"""Server-side validation of the Stage 4 columns, driven through the real push endpoint."""

import uuid
from typing import Any

import pytest

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.work_support import (
    allocation_fields,
    cr_fields,
    entry_fields,
    payment_fields,
    person_fields,
    project_fields,
    work_seed,
)

Case = tuple[str, str, uuid.UUID | None, dict[str, Any], str | None]


async def run_cases(dc: DeviceClient, cases: list[Case]) -> None:
    ops = [dc.op(table, row_id or uuid7(), fields=fields) for _, table, row_id, fields, _ in cases]
    results = await dc.push_ok(ops)
    problems = []
    for (name, _, _, _, expected), result in zip(cases, results, strict=True):
        got = result["code"] if result["status"] == "rejected" else None
        if got != expected:
            problems.append(f"{name}: expected {expected}, got {got} ({result['message']})")
    assert not problems, "\n".join(problems)


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


async def test_project_columns(phone: DeviceClient) -> None:
    def case(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "projects", None, project_fields(phone, **over), expected)

    await run_cases(
        phone,
        [
            case("legacy stage 2 project still valid", None),
            case(
                "full project",
                None,
                client_id=str(uuid7()),
                status="active",
                pay_type="hourly",
                hourly_rate=150_000,
                base_amount=0,
                start_date="2026-09-01",
                deadline_date="2026-12-31",
                description="d",
                links=[{"url": "https://git.example/x", "title": "repo"}, {"url": "http://a.b"}],
            ),
            case("zero base", None, base_amount=0),
            case("max base", None, base_amount=99_999_999_999_999),
            case("negative base", "invalid_field", base_amount=-1),
            case("too large base", "invalid_field", base_amount=100_000_000_000_000),
            case("float base", "invalid_field", base_amount=1500.5),
            case("string base", "invalid_field", base_amount="100"),
            case("bool base", "invalid_field", base_amount=True),
            case("negative rate", "invalid_field", hourly_rate=-5),
            case("unknown status", "invalid_field", status="closed"),
            case("unknown pay type", "invalid_field", pay_type="retainer"),
            case("bad client id", "invalid_field", client_id="nope"),
            case("hourly needs rate", "validation_failed", pay_type="hourly"),
            case("completed needs date", "validation_failed", status="completed"),
            case("completed with date", None, status="completed", completed_date="2026-10-01"),
            case("archive an active project", "validation_failed", archived=True, status="active"),
            case("archive a lead", "validation_failed", archived=True, status="lead"),
            case("archive a paused project", "validation_failed", archived=True, status="paused"),
            case("archive a cancelled project", None, archived=True, status="cancelled"),
            case(
                "archive a completed project",
                None,
                archived=True,
                status="completed",
                completed_date="2026-10-01",
            ),
            case("archived legacy project (no status)", None, archived=True),
            case("not a date at all", "invalid_field", start_date="1.10.2026"),
            case("month 13", "validation_failed", start_date="2026-13-40"),
            case("february 30", "validation_failed", start_date="2026-02-30"),
            case(
                "deadline before start",
                "validation_failed",
                start_date="2026-10-02",
                deadline_date="2026-10-01",
            ),
            case(
                "completed before start",
                "validation_failed",
                start_date="2026-10-02",
                status="completed",
                completed_date="2026-10-01",
            ),
            case("links not a list", "validation_failed", links={"url": "https://a.b"}),
            case("too many links", "validation_failed", links=[{"url": "https://a.b"}] * 21),
            case("link without url", "validation_failed", links=[{"title": "x"}]),
            case("link with other scheme", "validation_failed", links=[{"url": "javascript:1"}]),
            case("link with extra key", "validation_failed", links=[{"url": "https://a", "x": 1}]),
            case(
                "link title too long",
                "validation_failed",
                links=[{"url": "https://a", "title": "x" * 101}],
            ),
            case("link url not a string", "validation_failed", links=[{"url": 5}]),
            case("link url too long", "validation_failed", links=[{"url": "https://" + "a" * 500}]),
            case("blank title", "validation_failed", title="  "),
            case("long description", "invalid_field", description="x" * 10_001),
        ],
    )


async def test_person_columns(phone: DeviceClient) -> None:
    def case(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "people", None, person_fields(phone, **over), expected)

    await run_cases(
        phone,
        [
            case("legacy person", None),
            case("client with contact", None, role="client", contact="+7 900 000-00-00"),
            case("other", None, role="other"),
            case("partner is gone", "invalid_field", role="partner"),
            case("long contact", "invalid_field", contact="x" * 501),
        ],
    )


async def test_change_request_payment_allocation_and_entry_columns(phone: DeviceClient) -> None:
    project, payment = uuid7(), uuid7()
    await run_cases(
        phone,
        [
            ("project", "projects", project, project_fields(phone), None),
            ("payment", "payments", payment, payment_fields(phone), None),
        ],
    )

    def cr(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "change_requests", None, cr_fields(phone, project, **over), expected)

    def alloc(name: str, expected: str | None, **over: Any) -> Case:
        return (
            name,
            "payment_allocations",
            None,
            allocation_fields(phone, payment, project, **over),
            expected,
        )

    def pay(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "payments", None, payment_fields(phone, **over), expected)

    def entry(name: str, expected: str | None, **over: Any) -> Case:
        return (name, "time_entries", None, entry_fields(phone, project, **over), expected)

    await run_cases(
        phone,
        [
            cr("change request", None),
            cr("free change request", None, amount=0),
            cr("negative amount", "invalid_field", amount=-100),
            cr("float amount", "invalid_field", amount=10.5),
            cr("unknown status", "invalid_field", status="done"),
            cr("closed needs a date", "validation_failed", status="closed"),
            cr("closed with a date", None, status="closed", closed_date="2026-10-01"),
            cr("bad closed date", "invalid_field", closed_date="1.10.2026"),
            cr("impossible closed date", "validation_failed", closed_date="2026-02-30"),
            cr("blank title", "validation_failed", title=" "),
            cr("estimate", None, estimate_minutes=90),
            cr("negative estimate", "invalid_field", estimate_minutes=-1),
            (
                "orphan change request",
                "change_requests",
                None,
                cr_fields(phone, uuid7()),
                "parent_not_found",
            ),
            pay("payment without payer", None),
            pay("zero payment", "invalid_field", amount=0),
            pay("negative payment", "invalid_field", amount=-1),
            pay("payment before 2015", "validation_failed", paid_at="2014-12-31T23:59:59Z"),
            pay("payment on the first second of 2015", None, paid_at="2015-01-01T00:00:00Z"),
            pay("payment with an offset", None, paid_at="2026-10-05T12:00:00+03:00"),
            alloc("allocation to the base", None),
            alloc("allocation to a change request", None, change_request_id=str(uuid7())),
            alloc("zero allocation", "invalid_field", amount=0),
            alloc("negative allocation", "invalid_field", amount=-5),
            (
                "allocation of a missing payment",
                "payment_allocations",
                None,
                allocation_fields(phone, uuid7(), project),
                "parent_not_found",
            ),
            (
                "allocation to a missing project",
                "payment_allocations",
                None,
                allocation_fields(phone, payment, uuid7()),
                "parent_not_found",
            ),
            entry("manual entry", None),
            entry("running timer", None, source="timer", ended_at=None),
            entry("manual entry cannot run", "validation_failed", ended_at=None),
            entry("ends before it starts", "validation_failed", ended_at="2026-10-05T06:59:59Z"),
            entry("zero length", None, ended_at="2026-10-05T07:00:00Z"),
            entry("13 days", None, ended_at="2026-10-18T06:59:59Z"),
            entry("14 days", "validation_failed", ended_at="2026-10-19T07:00:00Z"),
            entry("started before 2015", "validation_failed", started_at="2014-01-01T00:00:00Z"),
            entry("unknown source", "invalid_field", source="import"),
            entry("not billable with a note", None, billable=False, note="созвон"),
            entry("soft links", None, change_request_id=str(uuid7()), task_id=str(uuid7())),
            (
                "entry of a missing project",
                "time_entries",
                None,
                entry_fields(phone, uuid7()),
                "parent_not_found",
            ),
        ],
    )


async def test_immutable_columns(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    other = uuid7()
    await phone.push_ok([phone.op("projects", other, fields=project_fields(phone))])
    head = (await phone.pull_ok(0))["head_version"]
    results = await phone.push_ok(
        [
            phone.op("change_requests", seed.cart, fields={"project_id": str(other)}, base=head),
            phone.op(
                "payment_allocations", seed.alloc_base, fields={"project_id": str(other)}, base=head
            ),
            phone.op(
                "payment_allocations",
                seed.alloc_base,
                fields={"payment_id": str(seed.payment2)},
                base=head,
            ),
            phone.op(
                "payment_allocations",
                seed.alloc_base,
                fields={"change_request_id": str(seed.cart)},
                base=head,
            ),
            phone.op(
                "payment_allocations", seed.alloc_base, fields={"amount": 5_500_000}, base=head
            ),
            phone.op("time_entries", seed.entry, fields={"project_id": str(other)}, base=head),
        ]
    )
    assert [r["code"] for r in results] == ["immutable_field"] * 4 + [None, None]
    assert [r["status"] for r in results] == ["rejected"] * 4 + ["applied"] * 2


async def test_a_merge_that_breaks_a_project_invariant_is_rejected(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    head = (await phone.pull_ok(0))["head_version"]
    (bad,) = await phone.push_ok(
        [phone.op("projects", seed.project, fields={"archived": True}, base=head)]
    )
    assert (bad["status"], bad["code"]) == ("rejected", "validation_failed")  # still active
    (ok,) = await phone.push_ok(
        [
            phone.op(
                "projects",
                seed.project,
                fields={"status": "cancelled", "archived": True},
                base=head,
            )
        ]
    )
    assert ok["status"] == "applied"
