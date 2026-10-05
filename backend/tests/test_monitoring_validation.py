"""Server-side validation of the Stage 9 tables, driven through the real push endpoint."""

from typing import Any

import pytest

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.monitoring_support import Graph, check_fields, make_graph, server_fields, service_fields
from tests.test_work_validation import Case, run_cases


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


@pytest.fixture
async def graph(phone: DeviceClient) -> Graph:
    return (await make_graph(phone))[0]


async def test_server_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (label, "monitor_servers", None, server_fields(phone, **over), expected)

    await run_cases(
        phone,
        [
            case("plain server", None),
            case("ip address", None, host="93.184.216.34"),
            case("with provider and note", None, provider="Hetzner", note="основной"),
            case("blank name", "validation_failed", name="  "),
            case("long name", "invalid_field", name="x" * 101),
            case("empty host", "invalid_field", host=""),
            case("localhost", "validation_failed", host="localhost"),
            case("loopback", "validation_failed", host="127.0.0.1"),
            case("private address", "validation_failed", host="192.168.1.10"),
            case("metadata address", "validation_failed", host="169.254.169.254"),
            case("internal name", "validation_failed", host="db.internal"),
            case("host with a scheme", "validation_failed", host="https://example.com"),
            case("host with a port", "validation_failed", host="example.com:22"),
            case("long note", "invalid_field", note="x" * 2001),
            case("host missing", "invalid_field", host=None),
        ],
    )


async def test_service_columns(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (
            label,
            "monitor_services",
            None,
            service_fields(phone, graph.server, **over),
            expected,
        )

    await run_cases(
        phone,
        [
            case("plain service", None),
            case("critical with a work project", None, critical=True, work_project_id=str(uuid7())),
            case("blank name", "validation_failed", name=" "),
            case("not a bool", "invalid_field", critical="yes"),
            case("bad project id", "invalid_field", work_project_id="nope"),
            case("server does not exist", "parent_not_found", server_id=str(uuid7())),
            case("long note", "invalid_field", note="x" * 2001),
        ],
    )


async def test_check_columns_by_kind(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (label, "monitor_checks", None, check_fields(phone, graph.service, **over), expected)

    await run_cases(
        phone,
        [
            case("http", None),
            case("http with status and keyword", None, expected_status=204, keyword="OK"),
            case("tcp", None, kind="tcp", url=None, host="example.com", port=5432),
            case("dns", None, kind="dns", url=None, host="example.com", dns_record_type="A"),
            case(
                "dns with expected value",
                None,
                kind="dns",
                url=None,
                host="example.com",
                dns_record_type="MX",
                expected_value="mail.example.com",
            ),
            case("ssl default port", None, kind="ssl", url=None, host="example.com"),
            case(
                "ssl with port and days",
                None,
                kind="ssl",
                url=None,
                host="example.com",
                port=8443,
                ssl_min_days=30,
            ),
            case("http without url", "validation_failed", url=None),
            case("tcp without port", "validation_failed", kind="tcp", url=None, host="example.com"),
            case("tcp without host", "validation_failed", kind="tcp", url=None, port=22),
            case(
                "dns without record type",
                "validation_failed",
                kind="dns",
                url=None,
                host="example.com",
            ),
            case("ssl without host", "validation_failed", kind="ssl", url=None),
            case("http with a host too", "validation_failed", host="example.com"),
            case(
                "tcp with a url too", "validation_failed", kind="tcp", host="example.com", port=22
            ),
            case("http with a port", "validation_failed", port=80),
            case(
                "dns with a port",
                "validation_failed",
                kind="dns",
                url=None,
                host="example.com",
                dns_record_type="A",
                port=53,
            ),
            case(
                "tcp with a keyword",
                "validation_failed",
                kind="tcp",
                url=None,
                host="example.com",
                port=22,
                keyword="x",
            ),
            case("unknown kind", "invalid_field", kind="icmp"),
            case(
                "unknown record type",
                "invalid_field",
                kind="dns",
                url=None,
                host="example.com",
                dns_record_type="SRV",
            ),
            case("interval 9", "invalid_field", interval_seconds=9, timeout_seconds=5),
            case("interval 3601", "invalid_field", interval_seconds=3601),
            case("interval 10", None, interval_seconds=10, timeout_seconds=5),
            case("timeout 31", "invalid_field", interval_seconds=60, timeout_seconds=31),
            case(
                "timeout equals interval",
                "validation_failed",
                interval_seconds=10,
                timeout_seconds=10,
            ),
            case("timeout 0", "invalid_field", timeout_seconds=0),
            case("port 0", "invalid_field", kind="tcp", url=None, host="example.com", port=0),
            case(
                "port 65536", "invalid_field", kind="tcp", url=None, host="example.com", port=65536
            ),
            case("status 99", "invalid_field", expected_status=99),
            case("status 600", "invalid_field", expected_status=600),
            case("keyword with a space", "invalid_field", keyword="two words"),
            case("keyword with a wildcard", "invalid_field", keyword="a*b"),
            case("keyword with a bracket", "invalid_field", keyword="a]b"),
            case("keyword with a quote", "invalid_field", keyword="a'b"),
            case("keyword of 101 characters", "invalid_field", keyword="k" * 101),
            case(
                "expected value with a space",
                "invalid_field",
                kind="dns",
                url=None,
                host="example.com",
                dns_record_type="A",
                expected_value="1.2.3.4 5.6.7.8",
            ),
            case(
                "ssl days 0",
                "invalid_field",
                kind="ssl",
                url=None,
                host="example.com",
                ssl_min_days=0,
            ),
            case("blank name", "validation_failed", name="  "),
            case("service does not exist", "parent_not_found", service_id=str(uuid7())),
        ],
    )


async def test_ssrf_targets_are_refused(phone: DeviceClient, graph: Graph) -> None:
    """The headline security rule: nothing that points into the server's own network is stored."""

    def http(url: str) -> dict[str, Any]:
        return check_fields(phone, graph.service, url=url)

    def host(kind: str, value: str, **over: Any) -> dict[str, Any]:
        base: dict[str, Any] = {"kind": kind, "url": None, "host": value, **over}
        return check_fields(phone, graph.service, **base)

    bad_urls = [
        "http://localhost/",
        "http://127.0.0.1:8000/health",
        "http://[::1]/",
        "http://169.254.169.254/latest/meta-data/",
        "http://metadata.google.internal/",
        "http://10.0.0.5/",
        "http://172.16.0.1/",
        "http://192.168.0.1/",
        "http://100.64.0.1/",
        "http://0.0.0.0/",
        "http://2130706433/",
        "http://0x7f.0.0.1/",
        "http://127.1/",
        "http://[::ffff:127.0.0.1]/",
        "http://postgres:5432/",
        "http://api:8000/",
        "http://gatus:8080/",
        "http://worker.internal/",
        "https://user:pw@example.com/",
        "ftp://example.com/",
        "file:///etc/passwd",
        "gopher://example.com/",
        "https://example.com#frag",
    ]
    cases: list[Case] = [
        (u, "monitor_checks", None, http(u), "validation_failed") for u in bad_urls
    ]
    for kind, extra in (("tcp", {"port": 5432}), ("ssl", {}), ("dns", {"dns_record_type": "A"})):
        for value in (
            "127.0.0.1",
            "10.1.1.1",
            "169.254.169.254",
            "localhost",
            "postgres",
            "::1",
            "fd00::1",
        ):
            cases.append(
                (
                    f"{kind} {value}",
                    "monitor_checks",
                    None,
                    host(kind, value, **extra),
                    "validation_failed",
                )
            )
    cases.append(("public url", "monitor_checks", None, http("https://example.com/"), None))
    cases.append(
        ("public tcp", "monitor_checks", None, host("tcp", "93.184.216.34", port=22), None)
    )
    await run_cases(phone, cases)


async def test_immutable_columns(phone: DeviceClient, graph: Graph) -> None:
    other = str(uuid7())
    edits = [
        ("monitor_services", graph.service, {"server_id": other}),
        ("monitor_checks", graph.check, {"service_id": other}),
        ("monitor_checks", graph.check, {"kind": "tcp"}),
    ]
    for table, row_id, fields in edits:
        (result,) = await phone.push_ok([phone.op(table, row_id, fields=fields, base=1)])
        assert result["code"] == "immutable_field", (table, fields)
    (renamed,) = await phone.push_ok(
        [
            phone.op(
                "monitor_checks",
                graph.check,
                fields={"name": "Другое имя", "interval_seconds": 30},
                base=1,
            )
        ]
    )
    assert renamed["status"] == "applied"


async def test_an_edit_that_breaks_the_merged_row_is_refused(
    phone: DeviceClient, graph: Graph
) -> None:
    (result,) = await phone.push_ok(
        [phone.op("monitor_checks", graph.check, fields={"url": "http://10.0.0.1/"}, base=1)]
    )
    assert result["code"] == "validation_failed"
    (result,) = await phone.push_ok(
        [phone.op("monitor_checks", graph.check, fields={"timeout_seconds": 20}, base=1)]
    )
    assert result["code"] == "validation_failed"  # equal to the interval of 20
    (result,) = await phone.push_ok(
        [phone.op("monitor_servers", graph.server, fields={"host": "127.0.0.1"}, base=1)]
    )
    assert result["code"] == "validation_failed"
