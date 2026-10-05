"""Builds ``shared-test-vectors/monitoring/*.json``: inputs are written here, expected values come
from the reference implementation (``tasker.monitoring``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.monitoring_vectors_gen``. A test checks that the
files on disk are exactly this output.
"""

import json
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from tasker.monitoring import alerts, stats, targets

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "monitoring"
Case = tuple[str, dict[str, Any]]  # (name, input)

# ------------------------------------------------------------------ targets.json


def host(value: str) -> dict[str, Any]:
    return {"op": "host", "value": value}


def url(value: str) -> dict[str, Any]:
    return {"op": "url", "value": value}


TARGETS: list[Case] = [
    ("host_plain_name", host("example.com")),
    ("host_subdomain", host("sub.example.co.uk")),
    ("host_upper_case_is_lowered", host("EXAMPLE.COM")),
    ("host_trailing_dot_is_dropped", host("example.com.")),
    ("host_punycode", host("xn--80ak6aa92e.com")),
    ("host_sslip_style_name", host("203-0-113-7.sslip.io")),
    ("host_name_that_looks_like_hex_but_has_a_real_tld", host("0x7f000001.com")),
    ("host_public_ipv4", host("8.8.8.8")),
    ("host_public_ipv6", host("2606:4700:4700::1111")),
    ("host_public_ipv6_in_brackets", host("[2606:4700:4700::1111]")),
    ("host_mapped_public_ipv4", host("::ffff:8.8.8.8")),
    ("host_empty", host("")),
    ("host_localhost", host("localhost")),
    ("host_service_name_of_the_compose_network", host("postgres")),
    ("host_single_label_api", host("api")),
    ("host_loopback_v4", host("127.0.0.1")),
    ("host_loopback_v4_other", host("127.255.255.254")),
    ("host_private_10", host("10.0.0.5")),
    ("host_private_172", host("172.16.0.1")),
    ("host_private_192", host("192.168.1.1")),
    ("host_cloud_metadata", host("169.254.169.254")),
    ("host_link_local_other", host("169.254.1.1")),
    ("host_carrier_grade_nat", host("100.64.0.1")),
    ("host_unspecified", host("0.0.0.0")),
    ("host_broadcast", host("255.255.255.255")),
    ("host_multicast", host("224.0.0.1")),
    ("host_documentation_range", host("192.0.2.1")),
    ("host_loopback_v6", host("::1")),
    ("host_loopback_v6_in_brackets", host("[::1]")),
    ("host_link_local_v6", host("fe80::1")),
    ("host_unique_local_v6", host("fc00::1")),
    ("host_mapped_loopback", host("::ffff:127.0.0.1")),
    ("host_mapped_private", host("::ffff:10.0.0.1")),
    ("host_short_ipv4_form", host("127.1")),
    ("host_hex_ipv4_form", host("0x7f.0.0.1")),
    ("host_octal_ipv4_form", host("0177.0.0.1")),
    ("host_decimal_ipv4_form", host("2130706433")),
    ("host_ipv4_in_brackets", host("[1.2.3.4]")),
    ("host_gcp_metadata_name", host("metadata.google.internal")),
    ("host_dot_local", host("printer.local")),
    ("host_dot_localhost", host("app.localhost")),
    ("host_dot_lan", host("nas.lan")),
    ("host_home_arpa", host("x.home.arpa")),
    ("host_dot_corp", host("wiki.corp")),
    ("host_dot_test", host("service.test")),
    ("host_space_inside", host("exa mple.com")),
    ("host_with_a_path", host("example.com/path")),
    ("host_with_userinfo", host("user@example.com")),
    ("host_with_a_port", host("example.com:80")),
    ("host_with_a_percent", host("example.com%2e")),
    ("host_non_ascii", host("пример.рф")),
    ("host_leading_dash", host("-bad.example.com")),
    ("host_empty_label", host("a..example.com")),
    ("host_label_of_64_characters", host("a" * 64 + ".com")),
    ("host_one_letter_tld", host("example.c")),
    ("host_name_over_253_characters", host(".".join(["a" * 60] * 5) + ".com")),
    ("host_brackets_around_a_name", host("[example.com]")),
    ("url_https_plain", url("https://example.com")),
    ("url_http_with_path", url("http://example.com/health")),
    ("url_port_and_query", url("https://example.com:8443/a?b=c")),
    ("url_scheme_and_host_in_upper_case", url("HTTP://Example.COM/x")),
    ("url_public_ipv6", url("https://[2606:4700:4700::1111]/")),
    ("url_public_ipv4", url("https://8.8.8.8/")),
    ("url_empty", url("")),
    ("url_ftp", url("ftp://example.com")),
    ("url_javascript", url("javascript:alert(1)")),
    ("url_scheme_relative", url("//example.com")),
    ("url_without_scheme", url("example.com")),
    ("url_localhost", url("http://localhost")),
    ("url_loopback", url("http://127.0.0.1:8080/")),
    ("url_loopback_v6", url("http://[::1]/")),
    ("url_metadata_service", url("http://169.254.169.254/latest/meta-data/")),
    ("url_gcp_metadata_name", url("http://metadata.google.internal/computeMetadata/v1/")),
    ("url_private", url("http://10.1.2.3/")),
    ("url_decimal_loopback", url("http://2130706433/")),
    ("url_hex_loopback", url("http://0x7f.0.0.1/")),
    ("url_mapped_loopback", url("http://[::ffff:127.0.0.1]/")),
    ("url_compose_service_name", url("http://service/")),
    ("url_internal_zone", url("http://x.internal/")),
    ("url_with_credentials", url("https://user:pw@example.com/")),
    ("url_with_empty_credentials", url("https://@example.com")),
    ("url_with_a_fragment", url("https://example.com/#top")),
    ("url_with_an_empty_fragment", url("https://example.com/#")),
    ("url_port_zero", url("https://example.com:0/")),
    ("url_port_too_large", url("https://example.com:99999/")),
    ("url_without_a_host", url("http://")),
    ("url_empty_host_with_a_path", url("http:///path")),
    ("url_with_a_space", url("https://exa mple.com")),
    ("url_with_a_backslash", url("https://example.com\\@evil.test")),
    ("url_over_2000_characters", url("https://example.com/" + "a" * 2000)),
    (
        "addresses_all_public",
        {"op": "addresses", "values": ["93.184.216.34", "2606:2800:220:1::1"]},
    ),
    (
        "addresses_one_private_among_public",
        {"op": "addresses", "values": ["93.184.216.34", "10.0.0.1"]},
    ),
    ("addresses_loopback_only", {"op": "addresses", "values": ["127.0.0.1"]}),
    ("addresses_none", {"op": "addresses", "values": []}),
    ("addresses_mapped_private", {"op": "addresses", "values": ["::ffff:192.168.0.1"]}),
    ("addresses_with_a_scope", {"op": "addresses", "values": ["fe80::1%eth0"]}),
]


def run_target(given: dict[str, Any]) -> Any:
    if given["op"] == "host":
        return targets.check_host(given["value"]).as_json()
    if given["op"] == "url":
        return targets.check_url(given["value"]).as_json()
    return {"reason": targets.check_addresses(given["values"])}


# ------------------------------------------------------------------ alerts.json


def o(
    service: str, check: str, at: int, ok: bool = True, reason: str | None = None
) -> dict[str, Any]:
    return {
        "service": service,
        "check": check,
        "at": at,
        "ok": ok,
        "reason": None if ok else (reason or "HTTP 502"),
    }


def bad(service: str, check: str, at: int, reason: str | None = None) -> dict[str, Any]:
    return o(service, check, at, False, reason)


def tick(now: int, *observations: dict[str, Any], quiet: bool = False) -> dict[str, Any]:
    return {"now": now, "quiet": quiet, "observations": list(observations)}


def scenario(
    cycles: list[dict[str, Any]],
    services: dict[str, bool] | None = None,
    /,
    **policy: int,
) -> dict[str, Any]:
    """``services``: id -> critical (default: one non-critical service ``s1``)."""
    chosen = services if services is not None else {"s1": False}
    return {
        "policy": policy,
        "services": {sid: {"critical": critical} for sid, critical in chosen.items()},
        "cycles": cycles,
    }


def fails(service: str, check: str, start: int, count: int, step: int = 20) -> list[dict[str, Any]]:
    return [bad(service, check, start + i * step) for i in range(count)]


FALL = [tick(1, o("s1", "c1", 0)), tick(21, bad("s1", "c1", 20)), tick(41, bad("s1", "c1", 40))]
FAST = {"fail_threshold": 1, "recover_threshold": 1}

ALERTS: list[Case] = [
    (
        "fall_alert_once_then_recovery",
        scenario(
            [
                *FALL,
                tick(61, bad("s1", "c1", 60)),
                tick(71),
                tick(81, o("s1", "c1", 80)),
                tick(101, o("s1", "c1", 100)),
            ]
        ),
    ),
    ("two_failures_are_not_enough", scenario([*FALL, tick(100), tick(200)])),
    (
        "a_success_resets_the_failure_count",
        scenario(
            [
                tick(1, bad("s1", "c1", 0), bad("s1", "c1", 20)),
                tick(41, o("s1", "c1", 40)),
                tick(101, bad("s1", "c1", 60), bad("s1", "c1", 80)),
                tick(200),
            ]
        ),
    ),
    (
        "the_alert_waits_for_the_group_delay",
        scenario([*FALL, tick(61, bad("s1", "c1", 60)), tick(65), tick(69), tick(70)]),
    ),
    (
        "one_success_is_not_a_recovery",
        scenario(
            [*FALL, tick(61, bad("s1", "c1", 60)), tick(71), tick(81, o("s1", "c1", 80)), tick(95)]
        ),
    ),
    (
        "recovery_inside_the_delay_is_silent",
        scenario(
            [
                *FALL,
                tick(61, bad("s1", "c1", 60)),
                tick(65, o("s1", "c1", 62), o("s1", "c1", 64)),
                tick(80),
                tick(200),
            ]
        ),
    ),
    (
        "no_repeat_while_down",
        scenario([*FALL, tick(61, bad("s1", "c1", 60)), *[tick(70 + i * 300) for i in range(11)]]),
    ),
    (
        "reminders_after_one_hour_then_every_four",
        scenario(
            [
                *FALL,
                tick(61, bad("s1", "c1", 60)),
                tick(71),
                tick(3670),
                tick(3671),
                tick(10000),
                tick(18070),
                tick(18071),
            ]
        ),
    ),
    (
        "since_is_the_start_of_the_failure_streak",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(500, bad("s1", "c1", 300), bad("s1", "c1", 400), bad("s1", "c1", 480)),
                tick(520),
            ]
        ),
    ),
    (
        "first_run_never_up_still_alerts",
        scenario([tick(1, bad("s1", "c1", 0), bad("s1", "c1", 20), bad("s1", "c1", 40)), tick(60)]),
    ),
    (
        "first_success_is_no_event",
        scenario([tick(1, o("s1", "c1", 0)), tick(100, o("s1", "c1", 90))]),
    ),
    (
        "two_checks_one_alert_one_recovery",
        scenario(
            [
                tick(1, o("s1", "c1", 0), o("s1", "c2", 0)),
                tick(61, bad("s1", "c1", 20), bad("s1", "c1", 40), bad("s1", "c1", 60)),
                tick(71),
                tick(121, bad("s1", "c2", 80), bad("s1", "c2", 100), bad("s1", "c2", 120)),
                tick(141, o("s1", "c1", 130), o("s1", "c1", 140)),
                tick(161, o("s1", "c2", 150), o("s1", "c2", 160)),
            ]
        ),
    ),
    (
        "a_check_that_fails_again_after_one_success_stays_down",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(61, *fails("s1", "c1", 20, 3)),
                tick(71),
                tick(91, o("s1", "c1", 80), bad("s1", "c1", 90)),
                tick(200),
            ]
        ),
    ),
    (
        "two_services_down_together_make_one_group_message",
        scenario(
            [
                tick(1, o("s1", "c1", 0), o("s2", "c2", 0)),
                tick(61, *fails("s1", "c1", 20, 3), *fails("s2", "c2", 20, 3)),
                tick(71),
            ],
            {"s1": False, "s2": False},
        ),
    ),
    (
        "three_services_down_together_suspect_the_monitor",
        scenario(
            [
                tick(1, *[o(s, "c", 0) for s in ("s1", "s2", "s3")]),
                tick(61, *[b for s in ("s1", "s2", "s3") for b in fails(s, "c", 20, 3)]),
                tick(71),
            ],
            {"s1": False, "s2": False, "s3": False},
        ),
    ),
    (
        "five_services_down_together",
        scenario(
            [
                tick(61, *[b for s in ("a", "b", "c", "d", "e") for b in fails(s, "k", 0, 3)]),
                tick(80),
            ],
            dict.fromkeys(("a", "b", "c", "d", "e"), False),
        ),
    ),
    (
        "one_down_one_up_is_a_single_message",
        scenario(
            [
                tick(1, o("s1", "c1", 0), o("s2", "c2", 0)),
                tick(61, *fails("s1", "c1", 20, 3), o("s2", "c2", 30), o("s2", "c2", 50)),
                tick(71),
            ],
            {"s1": False, "s2": False},
        ),
    ),
    (
        "falls_in_different_cycles_stay_separate",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3)),
                tick(71),
                tick(141, *fails("s2", "c2", 80, 3)),
                tick(151),
            ],
            {"s1": False, "s2": False},
        ),
    ),
    (
        "simultaneous_recoveries_make_one_group_message",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3), *fails("s2", "c2", 0, 3)),
                tick(71),
                tick(
                    120,
                    o("s1", "c1", 100),
                    o("s1", "c1", 110),
                    o("s2", "c2", 100),
                    o("s2", "c2", 110),
                ),
            ],
            {"s1": False, "s2": False},
        ),
    ),
    (
        "group_threshold_of_three_keeps_two_apart",
        scenario(
            [tick(61, *fails("s1", "c1", 0, 3), *fails("s2", "c2", 0, 3)), tick(71)],
            {"s1": False, "s2": False},
            group_min=3,
        ),
    ),
    (
        "no_group_delay_alerts_in_the_same_cycle",
        scenario([tick(61, *fails("s1", "c1", 0, 3))], group_delay=0),
    ),
    (
        "thresholds_of_one",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(21, bad("s1", "c1", 20)),
                tick(40),
                tick(61, o("s1", "c1", 60)),
            ],
            **FAST,
        ),
    ),
    (
        "flapping_one_message_then_silence_then_stable",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(101, bad("s1", "c1", 100)),
                tick(111),
                tick(201, o("s1", "c1", 200)),
                tick(301, bad("s1", "c1", 300)),
                tick(311),
                tick(401, o("s1", "c1", 400)),
                tick(500),
                tick(2000),
                tick(2201),
            ],
            **FAST,
        ),
    ),
    (
        "flapping_that_ends_down_says_so_and_resumes_reminders",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(101, bad("s1", "c1", 100)),
                tick(111),
                tick(201, o("s1", "c1", 200)),
                tick(301, bad("s1", "c1", 300)),
                tick(311),
                tick(401, o("s1", "c1", 400)),
                tick(501, bad("s1", "c1", 500)),
                tick(520),
                tick(2300),
                tick(2301),
                tick(5900),
                tick(5901),
            ],
            **FAST,
        ),
    ),
    (
        "three_changes_are_not_flapping",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(101, bad("s1", "c1", 100)),
                tick(111),
                tick(201, o("s1", "c1", 200)),
                tick(301, bad("s1", "c1", 300)),
                tick(311),
            ],
            **FAST,
        ),
    ),
    (
        "outages_far_apart_are_separate_incidents",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                tick(101, bad("s1", "c1", 100)),
                tick(111),
                tick(201, o("s1", "c1", 200)),
                tick(3001, bad("s1", "c1", 3000)),
                tick(3011),
                tick(3101, o("s1", "c1", 3100)),
            ],
            **FAST,
        ),
    ),
    (
        "flapping_notice_is_sent_once_however_long_it_lasts",
        scenario(
            [
                tick(1, o("s1", "c1", 0)),
                *[
                    tick(
                        100 + i * 100,
                        o("s1", "c1", 100 + i * 100) if i % 2 else bad("s1", "c1", 100 + i * 100),
                    )
                    for i in range(1, 12)
                ],
            ],
            **FAST,
        ),
    ),
    (
        "quiet_hours_hold_the_alert_of_a_normal_service",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3), quiet=True),
                tick(100, quiet=True),
                tick(5000, quiet=True),
                tick(6000, quiet=False),
                tick(6100, quiet=False),
            ]
        ),
    ),
    (
        "quiet_hours_do_not_hold_a_critical_service",
        scenario(
            [tick(61, *fails("s1", "c1", 0, 3), quiet=True), tick(71, quiet=True)], {"s1": True}
        ),
    ),
    (
        "a_short_outage_inside_quiet_hours_is_silent",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3), quiet=True),
                tick(300, o("s1", "c1", 100), o("s1", "c1", 120), quiet=True),
                tick(400, quiet=False),
            ]
        ),
    ),
    (
        "a_recovery_is_never_held_by_quiet_hours",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3)),
                tick(71),
                tick(200, o("s1", "c1", 100), o("s1", "c1", 120), quiet=True),
            ]
        ),
    ),
    (
        "quiet_hours_hold_a_reminder",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3)),
                tick(71),
                tick(3700, quiet=True),
                tick(9000, quiet=False),
                tick(12000),
                tick(23400),
            ]
        ),
    ),
    (
        "quiet_hours_swallow_the_flapping_notice_and_its_end",
        scenario(
            [
                tick(1, o("s1", "c1", 0), quiet=True),
                tick(101, bad("s1", "c1", 100), quiet=True),
                tick(201, o("s1", "c1", 200), quiet=True),
                tick(301, bad("s1", "c1", 300), quiet=True),
                tick(401, o("s1", "c1", 400), quiet=True),
                tick(2500, quiet=True),
            ],
            **FAST,
        ),
    ),
    (
        "quiet_flapping_that_ends_down_sends_the_held_alert_when_the_quiet_hours_end",
        scenario(
            [
                tick(1, o("s1", "c1", 0), quiet=True),
                tick(101, bad("s1", "c1", 100), quiet=True),
                tick(201, o("s1", "c1", 200), quiet=True),
                tick(301, bad("s1", "c1", 300), quiet=True),
                tick(401, o("s1", "c1", 400), quiet=True),
                tick(501, bad("s1", "c1", 500), quiet=True),
                tick(2500, quiet=True),
                tick(2600, quiet=False),
            ],
            **FAST,
        ),
    ),
    (
        "a_critical_service_gets_the_flapping_notice_in_quiet_hours",
        scenario(
            [
                tick(1, o("s1", "c1", 0), quiet=True),
                tick(101, bad("s1", "c1", 100), quiet=True),
                tick(201, o("s1", "c1", 200), quiet=True),
                tick(301, bad("s1", "c1", 300), quiet=True),
                tick(401, o("s1", "c1", 400), quiet=True),
            ],
            {"s1": True},
            **FAST,
        ),
    ),
    (
        "observations_are_taken_in_time_order",
        scenario(
            [tick(100, bad("s1", "c1", 60), bad("s1", "c1", 20), bad("s1", "c1", 40)), tick(120)]
        ),
    ),
    (
        "a_deleted_service_is_dropped_without_a_message",
        {
            "policy": {},
            "services": {"s1": {"critical": False}, "s2": {"critical": False}},
            "cycles": [
                tick(61, *fails("s1", "c1", 0, 3), *fails("s2", "c2", 0, 3)),
                {"now": 71, "quiet": False, "observations": [], "drop": ["s2"]},
                tick(3700),
            ],
        },
    ),
    (
        "a_deleted_fallen_check_ends_the_incident_with_one_recovery",
        {
            "policy": {},
            "services": {"s1": {"critical": False, "checks": ["A", "B"]}},
            "cycles": [
                tick(1, o("s1", "A", 0), o("s1", "B", 0)),
                tick(61, o("s1", "A", 20), *fails("s1", "B", 20, 3)),
                tick(71),
                {
                    "now": 81,
                    "quiet": False,
                    "observations": [o("s1", "A", 80)],
                    "drop_checks": {"s1": ["B"]},
                },
                tick(120),
                tick(4000),
            ],
        },
    ),
    (
        "a_deleted_fallen_check_before_the_alert_is_silent",
        {
            "policy": {},
            "services": {"s1": {"critical": False, "checks": ["A", "B"]}},
            "cycles": [
                tick(1, o("s1", "A", 0), o("s1", "B", 0)),
                tick(61, o("s1", "A", 20), *fails("s1", "B", 20, 3)),
                {
                    "now": 65,
                    "quiet": False,
                    "observations": [],
                    "drop_checks": {"s1": ["B"]},
                },
                tick(200),
            ],
        },
    ),
    (
        "a_deleted_fallen_check_leaves_only_a_check_without_results_silently_closed",
        {
            "policy": {},
            "services": {"s1": {"critical": False, "checks": ["A", "B"]}},
            "cycles": [
                tick(61, *fails("s1", "B", 0, 3)),
                tick(71),
                {
                    "now": 81,
                    "quiet": False,
                    "observations": [],
                    "drop_checks": {"s1": ["B"]},
                },
                tick(4000),
            ],
        },
    ),
    (
        "a_deleted_healthy_check_does_not_end_an_incident",
        {
            "policy": {},
            "services": {"s1": {"critical": False, "checks": ["A", "B"]}},
            "cycles": [
                tick(1, o("s1", "B", 0)),
                tick(61, *fails("s1", "A", 0, 3)),
                tick(71),
                {
                    "now": 81,
                    "quiet": False,
                    "observations": [],
                    "drop_checks": {"s1": ["B"]},
                },
                tick(3700),
            ],
        },
    ),
    (
        "silence_is_not_recovery",
        scenario(
            [tick(61, *fails("s1", "c1", 0, 3)), tick(71), *[tick(100 + i * 50) for i in range(20)]]
        ),
    ),
    (
        "incident_numbers_count_up_per_service",
        scenario(
            [
                tick(61, *fails("s1", "c1", 0, 3)),
                tick(71),
                tick(121, o("s1", "c1", 100), o("s1", "c1", 110)),
                tick(4000, *fails("s1", "c1", 3900, 3)),
                tick(4020),
            ]
        ),
    ),
]


def run_alerts(given: dict[str, Any]) -> Any:
    policy = alerts.policy_from(given.get("policy"))
    services = dict(given["services"])
    states: dict[str, Any] = {}
    cycles = []
    incidents: dict[tuple[str, int], dict[str, Any]] = {}
    for cycle in given["cycles"]:
        for gone in cycle.get("drop", ()):
            services.pop(gone, None)
        for sid, removed in cycle.get("drop_checks", {}).items():
            kept = [c for c in services[sid]["checks"] if c not in removed]
            services[sid] = {**services[sid], "checks": kept}
        by_service: dict[str, list[dict[str, Any]]] = {}
        for item in cycle["observations"]:
            by_service.setdefault(item["service"], []).append(
                {k: item[k] for k in ("check", "at", "ok", "reason")}
            )
        states, events, messages = alerts.run_cycle(
            states, services, by_service, cycle["now"], cycle["quiet"], policy
        )
        for sid, items in events.items():
            for event in items:
                if event["type"] == "opened":
                    incidents[(sid, event["n"])] = {
                        "service": sid,
                        "n": event["n"],
                        "started_at": event["started_at"],
                        "ended_at": None,
                    }
                elif event["type"] == "closed":
                    incidents[(sid, event["n"])]["ended_at"] = event["ended_at"]
        cycles.append({"now": cycle["now"], "messages": messages})
    return {
        "cycles": cycles,
        "incidents": [incidents[key] for key in sorted(incidents)],
        "final": {
            sid: {"status": state["status"], "flapping": state["flapping"]}
            for sid, state in sorted(states.items())
        },
    }


# ------------------------------------------------------------------ quiet.json


def utc(text: str) -> int:
    return int(datetime.fromisoformat(text).replace(tzinfo=UTC).timestamp())


def quiet(now: str, tz: str, start: str | None, end: str | None) -> dict[str, Any]:
    return {"now": utc(now), "tz": tz, "start": start, "end": end}


MSK = "Europe/Moscow"
QUIET: list[Case] = [
    ("evening_inside_the_night_window", quiet("2026-10-01T20:30:00", MSK, "23:00", "08:00")),
    ("after_midnight_inside_the_night_window", quiet("2026-10-01T22:00:00", MSK, "23:00", "08:00")),
    ("one_minute_before_the_start", quiet("2026-10-01T19:59:00", MSK, "23:00", "08:00")),
    ("the_start_minute_is_quiet", quiet("2026-10-01T20:00:00", MSK, "23:00", "08:00")),
    ("one_minute_before_the_end_is_quiet", quiet("2026-10-02T04:59:00", MSK, "23:00", "08:00")),
    ("the_end_minute_is_not_quiet", quiet("2026-10-02T05:00:00", MSK, "23:00", "08:00")),
    ("midday_is_not_quiet", quiet("2026-10-01T09:00:00", MSK, "23:00", "08:00")),
    ("window_inside_one_day", quiet("2026-10-01T10:30:00", MSK, "13:00", "14:00")),
    ("window_inside_one_day_outside", quiet("2026-10-01T12:30:00", MSK, "13:00", "14:00")),
    ("start_equals_end_is_never_quiet", quiet("2026-10-01T20:30:00", MSK, "23:00", "23:00")),
    ("no_window", quiet("2026-10-01T20:30:00", MSK, None, None)),
    ("only_a_start_is_no_window", quiet("2026-10-01T20:30:00", MSK, "23:00", None)),
    (
        "zone_of_the_window_matters",
        quiet("2026-10-01T20:30:00", "Asia/Vladivostok", "23:00", "08:00"),
    ),
    (
        "berlin_after_the_spring_switch",
        quiet("2026-03-29T01:30:00", "Europe/Berlin", "03:15", "03:45"),
    ),
    (
        "berlin_before_the_spring_switch",
        quiet("2026-03-29T00:30:00", "Europe/Berlin", "03:15", "03:45"),
    ),
    (
        "berlin_overlap_hour_first_pass",
        quiet("2026-10-25T00:30:00", "Europe/Berlin", "02:15", "02:45"),
    ),
    (
        "berlin_overlap_hour_second_pass",
        quiet("2026-10-25T01:30:00", "Europe/Berlin", "02:15", "02:45"),
    ),
    ("whole_day_window", quiet("2026-10-01T12:00:00", MSK, "00:00", "23:59")),
]


def run_quiet(given: dict[str, Any]) -> Any:
    return {"quiet": alerts.is_quiet(given["now"], given["tz"], given["start"], given["end"])}


# ------------------------------------------------------------------ availability.json

H = 3600
NOW = utc("2026-10-10T12:34:56")
NOW_H = NOW - NOW % H


def b(back: int, total: int, ok: int) -> dict[str, int]:
    """A bucket ``back`` hours before the bucket of NOW."""
    return {"hour": NOW_H - back * H, "total": total, "ok": ok}


AVAIL: list[Case] = [
    ("no_checks", {"buckets": [], "now": NOW, "hours": 24}),
    ("all_ok", {"buckets": [b(0, 60, 60), b(1, 60, 60)], "now": NOW, "hours": 24}),
    ("all_failed", {"buckets": [b(0, 10, 0)], "now": NOW, "hours": 24}),
    ("half", {"buckets": [b(0, 10, 5), b(3, 10, 5)], "now": NOW, "hours": 24}),
    ("floor_of_basis_points", {"buckets": [b(0, 3, 2)], "now": NOW, "hours": 24}),
    ("one_failure_in_ten_thousand", {"buckets": [b(1, 9999, 9998)], "now": NOW, "hours": 24}),
    ("the_current_bucket_counts", {"buckets": [b(0, 1, 0)], "now": NOW, "hours": 24}),
    ("the_24th_bucket_counts", {"buckets": [b(23, 10, 10), b(0, 10, 0)], "now": NOW, "hours": 24}),
    (
        "the_25th_bucket_does_not",
        {"buckets": [b(24, 10, 0), b(0, 10, 10)], "now": NOW, "hours": 24},
    ),
    (
        "a_future_bucket_is_ignored",
        {"buckets": [b(-1, 10, 0), b(0, 10, 10)], "now": NOW, "hours": 24},
    ),
    (
        "seven_days",
        {"buckets": [b(167, 60, 59), b(168, 60, 0), b(10, 60, 60)], "now": NOW, "hours": 168},
    ),
    (
        "thirty_days",
        {"buckets": [b(719, 60, 30), b(720, 60, 0), b(5, 60, 60)], "now": NOW, "hours": 720},
    ),
    (
        "on_the_hour_exactly",
        {"buckets": [{"hour": NOW_H, "total": 4, "ok": 3}], "now": NOW_H, "hours": 24},
    ),
    ("a_window_of_one_hour", {"buckets": [b(0, 10, 9), b(1, 10, 0)], "now": NOW, "hours": 1}),
]


def run_availability(given: dict[str, Any]) -> Any:
    return {"bp": stats.availability_bp(given["buckets"], given["now"], given["hours"])}


FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "targets": (
        "check_host / check_url / check_addresses (op host, url, addresses): where a check may point; "
        "{valid, host} or {valid: false, reason}, {reason} for addresses",
        TARGETS,
        run_target,
    ),
    "alerts": (
        "run_cycle over a timeline: the messages of every cycle, the incidents and the final status "
        "of every service (anti-spam rules of the Telegram alerts)",
        ALERTS,
        run_alerts,
    ),
    "quiet": ("is_quiet(now, tz, start, end): inside the quiet hours or not", QUIET, run_quiet),
    "availability": (
        "availability_bp(buckets, now, hours): successful checks in basis points over hourly buckets",
        AVAIL,
        run_availability,
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
