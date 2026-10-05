"""The generated engine configuration: valid YAML, no secrets, SSRF rules applied again."""

import asyncio
import json
import uuid
from pathlib import Path
from typing import Any

import yaml

from tasker.monitoring import config_gen
from tasker.monitoring.config_gen import CheckSpec, build_config, render_yaml
from tasker.monitoring.service import _write_atomic

SID = str(uuid.uuid4())


def spec(kind: str, **over: Any) -> CheckSpec:
    base: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "service_id": SID,
        "kind": kind,
        "interval_seconds": 20,
        "timeout_seconds": 5,
    }
    base.update(over)
    return CheckSpec(**base)


class Resolver:
    """A resolver that answers from a table and remembers what it was asked."""

    def __init__(self, table: dict[str, list[str]] | None = None) -> None:
        self.table = table or {}
        self.asked: list[str] = []

    async def __call__(self, host: str) -> list[str]:
        self.asked.append(host)
        return self.table.get(host, ["93.184.216.34"])


async def test_every_kind_becomes_an_endpoint() -> None:
    checks = [
        spec("http", url="https://example.com/health", expected_status=204, keyword="OK"),
        spec("http", url="https://example.com/"),
        spec("tcp", host="example.com", port=5432),
        spec("tcp", host="2606:4700:4700::1111", port=443),
        spec("dns", host="example.com", dns_record_type="A", expected_value="93.184.216.34"),
        spec("dns", host="example.com", dns_record_type="MX"),
        spec("ssl", host="example.com"),
        spec("ssl", host="example.com", port=8443, ssl_min_days=30),
    ]
    result = await build_config(checks, Resolver(), "1.1.1.1:53")
    assert result.rejected == []
    document = yaml.safe_load(result.text)
    endpoints = {e["name"]: e for e in document["endpoints"]}
    assert len(endpoints) == len(checks) + 1  # + the engine's own sentinel
    http, plain, tcp, tcp6, dns, dns_mx, ssl, ssl_custom = (endpoints[c.id] for c in checks)
    assert http["conditions"] == ["[STATUS] == 204", "[BODY] == pat(*OK*)"]
    assert plain["conditions"] == ["[STATUS] < 400"]
    assert http["client"] == {
        "timeout": "5s",
        "ignore-redirect": True,
    }  # redirects are never followed
    assert http["interval"] == "20s" and http["group"] == SID
    assert tcp["url"] == "tcp://example.com:5432" and tcp["conditions"] == ["[CONNECTED] == true"]
    assert tcp6["url"] == "tcp://[2606:4700:4700::1111]:443"
    assert dns["url"] == "1.1.1.1:53"
    assert dns["dns"] == {"query-name": "example.com", "query-type": "A"}
    assert dns["conditions"] == ["[DNS_RCODE] == NOERROR", "[BODY] == pat(*93.184.216.34*)"]
    assert dns_mx["conditions"] == ["[DNS_RCODE] == NOERROR"]
    assert "client" not in dns
    assert ssl["url"] == "https://example.com:443"
    assert ssl["conditions"] == ["[CONNECTED] == true", "[CERTIFICATE_EXPIRATION] > 336h"]
    assert ssl_custom["url"] == "https://example.com:8443"
    assert ssl_custom["conditions"][1] == "[CERTIFICATE_EXPIRATION] > 720h"
    assert document["web"]["port"] == 8080
    assert document["storage"]["type"] == "sqlite"
    assert endpoints[config_gen.SENTINEL_NAME]["url"] == "http://127.0.0.1:8080/health"


async def test_the_config_is_deterministic_and_sorted_by_check_id() -> None:
    checks = [spec("tcp", host="example.com", port=p) for p in (1, 2, 3, 4)]
    one = await build_config(checks, Resolver(), "1.1.1.1:53")
    two = await build_config(list(reversed(checks)), Resolver(), "1.1.1.1:53")
    assert one.text == two.text and one.digest == two.digest
    names = [e["name"] for e in yaml.safe_load(one.text)["endpoints"]][:-1]
    assert names == sorted(names)


async def test_rows_that_break_the_rules_are_left_out_with_a_reason() -> None:
    private = spec("http", url="http://10.0.0.1/")
    metadata = spec("tcp", host="169.254.169.254", port=80)
    loopback_name = spec("http", url="http://localhost:8000/")
    credentials = spec("http", url="https://user:pw@example.com/")
    rebinding = spec("http", url="https://rebind.example.org/")
    mixed = spec("tcp", host="mixed.example.org", port=22)
    fine = spec("tcp", host="fine.example.org", port=22)
    resolver = Resolver(
        {
            "rebind.example.org": ["127.0.0.1"],
            "mixed.example.org": ["93.184.216.34", "192.168.0.7"],
            "fine.example.org": ["93.184.216.34"],
        }
    )
    result = await build_config(
        [private, metadata, loopback_name, credentials, rebinding, mixed, fine],
        resolver,
        "1.1.1.1:53",
    )
    assert result.active == [fine.id]
    reasons = {r["check_id"]: r["reason"] for r in result.rejected}
    assert reasons == {
        private.id: "target_non_global_ip",
        metadata.id: "target_non_global_ip",
        loopback_name.id: "target_single_label",
        credentials.id: "target_userinfo",
        rebinding.id: "resolves_to_non_global",
        mixed.id: "resolves_to_non_global",
    }
    text = result.text
    for forbidden in ("10.0.0.1", "169.254.169.254", "localhost", "pw@", "rebind.example.org"):
        assert forbidden not in text.replace("127.0.0.1:8080", "")
    assert yaml.safe_load(text)["endpoints"][0]["name"] == fine.id


async def test_a_name_that_does_not_resolve_is_kept_and_ip_literals_are_not_resolved() -> None:
    resolver = Resolver({"gone.example.org": []})
    names = spec("tcp", host="gone.example.org", port=22)
    literal = spec("tcp", host="93.184.216.34", port=22)
    dns = spec("dns", host="queried.example.org", dns_record_type="A")
    result = await build_config([names, literal, dns], resolver, "1.1.1.1:53")
    assert sorted(result.active) == sorted([names.id, literal.id, dns.id])
    assert resolver.asked == ["gone.example.org"]  # not the literal, not the DNS-check's name


async def test_resolutions_run_in_parallel_but_bounded() -> None:
    running = 0
    peak = 0

    async def slow(host: str) -> list[str]:
        nonlocal running, peak
        running += 1
        peak = max(peak, running)
        await asyncio.sleep(0.01)
        running -= 1
        return ["93.184.216.34"]

    checks = [spec("tcp", host=f"h{i}.example.org", port=22) for i in range(40)]
    result = await build_config(checks, slow, "1.1.1.1:53")
    assert len(result.active) == 40
    assert 1 < peak <= config_gen.RESOLVE_PARALLEL


def test_the_yaml_writer_quotes_every_string() -> None:
    document = {
        "a": [{"name": "yes", "v": "null", "n": 5, "t": True, "u": "x: y # z", "e": 'é\n"q"'}],
        "empty": [],
    }
    assert yaml.safe_load(render_yaml(document)) == {
        "a": [{"name": "yes", "v": "null", "n": 5, "t": True, "u": "x: y # z", "e": 'é\n"q"'}],
        "empty": [],
    }
    assert yaml.safe_load(render_yaml({"x": {"y": {"z": [1, "2"]}}})) == {
        "x": {"y": {"z": [1, "2"]}}
    }


async def test_the_config_contains_no_secret_word_and_only_the_owners_targets() -> None:
    result = await build_config(
        [spec("http", url="https://example.com/")], Resolver(), "1.1.1.1:53"
    )
    lowered = result.text.lower()
    for word in ("token", "password", "secret", "telegram", "api_key"):
        assert word not in lowered


async def test_sync_config_writes_atomically_once_and_reports(tmp_path: Path) -> None:
    path = tmp_path / "monitor" / "config.yaml"
    assert _write_atomic(path, "a: 1\n") is True
    assert _write_atomic(path, "a: 1\n") is False
    assert _write_atomic(path, "a: 2\n") is True
    assert path.read_text() == "a: 2\n"
    assert not list(path.parent.glob("*.part"))
    assert json.loads(json.dumps({"x": 1})) == {"x": 1}


async def test_the_system_resolver_answers_with_addresses_or_nothing() -> None:
    assert "127.0.0.1" in await config_gen.system_resolver("localhost")
    assert await config_gen.system_resolver("no-such-name.invalid") == []
