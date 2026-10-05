"""Stage 9 tables through the real sync engine: round trip, cascades, trash, purge."""

from tasker.monitoring.tables import MONITORING_TABLES
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env
from tests.monitoring_support import make_graph
from tests.test_calendar_sync import deleted, pull_rows

NAMES = ("monitor_servers", "monitor_services", "monitor_checks")


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def test_registry_has_the_monitoring_tables_parents_first() -> None:
    assert [spec.name for spec in MONITORING_TABLES] == list(NAMES)
    names = [spec.name for spec in build_registry().tables()]
    for parent, child in (
        ("monitor_servers", "monitor_services"),
        ("monitor_services", "monitor_checks"),
    ):
        assert names.index(parent) < names.index(child)
    assert {"monitor_results", "monitor_state"}.isdisjoint(names)  # the engine's data is not synced


async def test_the_graph_round_trips_to_a_second_device(env: Env) -> None:
    phone = await env.login()
    graph, _ = await make_graph(phone, critical=True)
    pc = await env.login("PC")
    rows = await pull_rows(pc)
    assert rows["monitor_servers"][str(graph.server)]["host"] == "vps.example.com"
    service = rows["monitor_services"][str(graph.service)]
    assert (service["critical"], service["server_id"]) == (True, str(graph.server))
    check = rows["monitor_checks"][str(graph.check)]
    assert (check["kind"], check["interval_seconds"], check["url"]) == (
        "http",
        20,
        "https://example.com/",
    )


async def test_deleting_a_server_trashes_services_and_checks_and_restoring_brings_them_back(
    env: Env,
) -> None:
    phone = await env.login()
    graph, _ = await make_graph(phone, checks=3)
    await phone.push_ok(
        [phone.op("monitor_servers", graph.server, "delete", base=await head(phone))]
    )
    assert [await deleted(env, t) for t in NAMES] == [1, 1, 3]
    await phone.push_ok(
        [
            phone.op(
                "monitor_servers", graph.server, fields={"deleted_at": None}, base=await head(phone)
            )
        ]
    )
    assert [await deleted(env, t) for t in NAMES] == [0, 0, 0]


async def test_deleting_a_service_takes_only_its_checks(env: Env) -> None:
    phone = await env.login()
    graph, _ = await make_graph(phone, checks=2)
    await phone.push_ok(
        [phone.op("monitor_services", graph.service, "delete", base=await head(phone))]
    )
    assert [await deleted(env, t) for t in NAMES] == [0, 1, 2]


async def test_purge_removes_children_first(env: Env) -> None:
    phone = await env.login()
    graph, _ = await make_graph(phone, checks=2)
    await phone.push_ok(
        [phone.op("monitor_servers", graph.server, "delete", base=await head(phone))]
    )
    top = await head(phone)
    env.clock.advance(days=31)
    await phone.refresh()
    await phone.pull_ok(top)
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged == 4
    for table in NAMES:
        assert await env.scalar(f"SELECT count(*) FROM {table}") == 0  # noqa: S608
