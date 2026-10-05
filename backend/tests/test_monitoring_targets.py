"""Units and properties of the SSRF rules beyond the shared vectors."""

import ipaddress

from hypothesis import given
from hypothesis import strategies as st

from tasker.monitoring import targets


@given(st.text(max_size=300))
def test_check_host_never_raises(text: str) -> None:
    verdict = targets.check_host(text)
    assert verdict.valid == (verdict.reason is None)


@given(st.text(max_size=300))
def test_check_url_never_raises(text: str) -> None:
    verdict = targets.check_url(text)
    assert verdict.valid == (verdict.reason is None)


@given(st.ip_addresses(v=4) | st.ip_addresses(v=6))
def test_an_accepted_ip_literal_is_public(
    ip: ipaddress.IPv4Address | ipaddress.IPv6Address,
) -> None:
    verdict = targets.check_host(str(ip))
    if verdict.valid:
        assert not targets.non_global(str(ip))
        assert verdict.host is not None
        checked = ipaddress.ip_address(verdict.host)
        mapped = getattr(checked, "ipv4_mapped", None) or checked
        assert mapped.is_global and not mapped.is_multicast
    else:
        assert verdict.reason == "non_global_ip"


@given(st.ip_addresses(v=4) | st.ip_addresses(v=6), st.sampled_from(["http", "https"]))
def test_a_url_with_an_ip_literal_is_judged_like_the_host(
    ip: ipaddress.IPv4Address | ipaddress.IPv6Address, scheme: str
) -> None:
    host = f"[{ip}]" if ip.version == 6 else str(ip)
    assert targets.check_url(f"{scheme}://{host}/x").valid == targets.check_host(str(ip)).valid


@given(st.sampled_from(targets.RESERVED_SUFFIXES), st.from_regex(r"[a-z]{1,10}", fullmatch=True))
def test_reserved_suffixes_are_refused_at_any_depth(suffix: str, label: str) -> None:
    for name in (f"{label}.{suffix}", f"{label}.{label}.{suffix}"):
        verdict = targets.check_host(name)
        assert not verdict.valid
        assert verdict.reason in ("reserved_name", "bad_tld", "single_label")


def test_non_global_helper_on_garbage_is_true() -> None:
    assert targets.non_global("not an address")
    assert targets.non_global("")


def test_the_normalised_host_is_lower_case_without_brackets_or_the_trailing_dot() -> None:
    assert targets.check_host("Example.COM.").host == "example.com"
    assert targets.check_url("https://[2606:4700:4700::1111]:8443/").host == "2606:4700:4700::1111"
    assert targets.check_host("[2606:4700:4700::1111]").as_json() == {
        "valid": True,
        "host": "2606:4700:4700::1111",
    }
    assert targets.check_host("localhost").as_json() == {"valid": False, "reason": "single_label"}


def test_unparsable_urls_and_overlong_names() -> None:
    assert targets.check_url("http://[::1").reason == "bad_url"
    assert targets.check_host(".".join(["a" * 50] * 6)).reason == "too_long"
