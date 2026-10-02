"""Stage 4 tables through the real sync engine: round trip, cascades, trash, offline merges."""

from tasker.ids import uuid7
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tasker.work import reference as ref
from tests.api_support import DeviceClient, Env
from tests.test_calendar_sync import deleted, pull_rows
from tests.work_support import allocation_fields, work_seed


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def test_registry_has_the_work_tables_parents_first() -> None:
    names = [spec.name for spec in build_registry().tables()]
    for name in ("change_requests", "payments", "payment_allocations", "time_entries"):
        assert names.index(name) > names.index("projects")
    assert names.index("payment_allocations") > names.index("payments")


async def test_whole_graph_round_trips_to_a_second_device(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    pc = await env.login("PC")
    tables = await pull_rows(pc)

    project = tables["projects"][str(seed.project)]
    assert (project["client_id"], project["status"], project["base_amount"]) == (
        str(seed.roma),
        "active",
        10_000_000,
    )
    assert project["hourly_rate"] is None
    assert project["links"] is None
    assert tables["people"][str(seed.roma)]["role"] == "client"
    assert tables["change_requests"][str(seed.cart)]["closed_date"] == "2026-10-01"
    assert tables["payments"][str(seed.payment)]["payer_id"] == str(seed.roma)
    assert tables["payment_allocations"][str(seed.alloc_cart)]["change_request_id"] == str(
        seed.cart
    )
    assert tables["time_entries"][str(seed.entry)]["source"] == "manual"
    assert len(tables["change_requests"]) == 3
    assert len(tables["payment_allocations"]) == 3


async def test_stage_2_projects_and_people_are_untouched_by_the_extension(env: Env) -> None:
    phone = await env.login()
    project, person = uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op(
                "projects",
                project,
                fields={"title": "Старый", "archived": True, "created_at": phone.created()},
            ),
            phone.op(
                "people",
                person,
                fields={"name": "Он", "archived": False, "created_at": phone.created()},
            ),
        ]
    )
    rows = await pull_rows(await env.login("PC"))
    old = rows["projects"][str(project)]
    assert (old["title"], old["archived"], old["status"], old["base_amount"]) == (
        "Старый",
        True,
        None,
        None,
    )
    assert rows["people"][str(person)]["role"] is None
    # an edit of the title does not trip over the archived-without-status rule
    (result,) = await phone.push_ok(
        [phone.op("projects", project, fields={"title": "Старый 2"}, base=1)]
    )
    assert result["status"] == "applied"


async def test_deleting_a_project_trashes_its_children_but_not_payments(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    (result,) = await phone.push_ok(
        [phone.op("projects", seed.project, "delete", base=await head(phone))]
    )
    assert result["status"] == "applied"
    assert await deleted(env, "change_requests") == 3
    assert await deleted(env, "payment_allocations") == 3
    assert await deleted(env, "time_entries") == 2
    assert await deleted(env, "payments") == 0
    assert await deleted(env, "people") == 0

    pc = await env.login("PC")
    rows = await pull_rows(pc)
    assert rows["payments"][str(seed.payment)]["deleted_at"] is None
    assert rows["change_requests"][str(seed.cart)]["deleted_at"] is not None

    (restored,) = await pc.push_ok(
        [pc.op("projects", seed.project, fields={"deleted_at": None}, base=await head(pc))]
    )
    assert restored["status"] == "applied"
    for table in ("change_requests", "payment_allocations", "time_entries", "projects"):
        assert await deleted(env, table) == 0, table


async def test_deleting_a_payment_trashes_its_allocations_only(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    await phone.push_ok([phone.op("payments", seed.payment, "delete", base=await head(phone))])
    assert await deleted(env, "payment_allocations") == 2  # both allocations of that payment
    assert await deleted(env, "payments") == 1
    assert await deleted(env, "projects") == 0
    rows = await pull_rows(phone)
    assert rows["payment_allocations"][str(seed.alloc_cart2)]["deleted_at"] is None
    await phone.push_ok(
        [phone.op("payments", seed.payment, fields={"deleted_at": None}, base=await head(phone))]
    )
    assert await deleted(env, "payment_allocations") == 0


async def test_deleting_a_change_request_or_a_person_keeps_the_money(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    base = await head(phone)
    await phone.push_ok(
        [
            phone.op("change_requests", seed.cart, "delete", base=base),
            phone.op("people", seed.roma, "delete", base=base),
        ]
    )
    assert await deleted(env, "payment_allocations") == 0
    assert await deleted(env, "projects") == 0
    rows = await pull_rows(phone)
    assert rows["projects"][str(seed.project)]["client_id"] == str(seed.roma)  # dangling on purpose
    live = {
        table: [r for r in rows[table].values() if r["deleted_at"] is None]
        for table in ("projects", "change_requests", "payment_allocations")
    }
    summary = ref.project_summary(
        dict(live["projects"][0]),
        [dict(r) for r in live["change_requests"]],
        [dict(r) for r in live["payment_allocations"]],
    )
    assert summary["received"] == 9_000_000  # nothing vanished
    assert (
        summary["base_received"] == 9_000_000
    )  # the deleted change request's money counts as base


async def test_a_child_created_under_a_deleted_project_lands_in_the_trash(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    await phone.push_ok([phone.op("projects", seed.project, "delete", base=await head(phone))])
    late = uuid7()
    (result,) = await phone.push_ok(
        [
            phone.op(
                "payment_allocations",
                late,
                fields=allocation_fields(phone, seed.payment, seed.project),
            )
        ]
    )
    assert result["status"] == "applied"
    assert result["conflicts"] == 1
    rows = await pull_rows(phone)
    assert rows["payment_allocations"][str(late)]["deleted_at"] is not None


async def test_two_offline_devices_may_over_allocate_a_payment_and_it_is_reported(
    env: Env,
) -> None:
    """Spec 3.3: the server cannot reject a sum over several rows; calculations stay honest."""
    phone = await env.login()
    seed = await work_seed(phone)
    pc = await env.login("PC")
    extra_a, extra_b = uuid7(), uuid7()
    (a,) = await phone.push_ok(
        [
            phone.op(
                "payment_allocations",
                extra_a,
                fields=allocation_fields(phone, seed.payment2, seed.project, amount=500_000),
            )
        ]
    )
    (b,) = await pc.push_ok(
        [
            pc.op(
                "payment_allocations",
                extra_b,
                fields=allocation_fields(pc, seed.payment2, seed.project, amount=700_000),
            )
        ]
    )
    assert a["status"] == b["status"] == "applied"
    rows = await pull_rows(phone)
    payments = [dict(r) for r in rows["payments"].values()]
    allocations = [dict(r) for r in rows["payment_allocations"].values()]
    problems = ref.integrity_problems([], payments, allocations)
    assert problems == [{"code": "over_allocated", "id": str(seed.payment2), "excess": 1_200_000}]


async def test_concurrent_edits_of_different_work_fields_merge(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    pc = await env.login("PC")
    seen = await head(phone)
    await phone.push_ok(
        [phone.op("change_requests", seed.filters, fields={"amount": 2_500_000}, base=seen)]
    )
    await pc.push_ok(
        [pc.op("change_requests", seed.filters, fields={"note": "уточнить"}, base=seen)]
    )
    row = (await pull_rows(phone))["change_requests"][str(seed.filters)]
    assert (row["amount"], row["note"]) == (2_500_000, "уточнить")


async def test_old_work_tombstones_are_purged_children_first(env: Env) -> None:
    phone = await env.login()
    seed = await work_seed(phone)
    await phone.push_ok([phone.op("projects", seed.project, "delete", base=await head(phone))])
    await phone.push_ok([phone.op("payments", seed.payment, "delete", base=await head(phone))])
    page = await phone.pull_ok(0)
    await phone.pull_ok(page["head_version"])
    env.clock.advance(days=31)
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged >= 10
    for table in ("change_requests", "payment_allocations", "time_entries", "projects"):
        assert await env.scalar(f"SELECT count(*) FROM {table}") == 0, table  # noqa: S608
    assert await env.scalar("SELECT count(*) FROM payments") == 1  # payment2 survives
