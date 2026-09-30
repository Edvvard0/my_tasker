"""Shared vectors (shared-test-vectors/sync) checked against the Python implementations."""

import uuid
from typing import Any

import pytest

from tasker.hlc import HlcClock, HlcError, device_of, format_hlc, hlc_ms, parse_hlc
from tasker.sync.merge import delete_decision, field_decision, tombstone_edit_decision
from tasker.sync.registry import datetime_column, json_column, text_column
from tasker.sync.user_settings import settings_id
from tests.sync_sim.client import collapse, epoch_action, rebase_row
from tests.vectors import load_cases


def ids(cases: list[dict[str, Any]]) -> list[str]:
    return [case["name"] for case in cases]


HLC = load_cases("sync", "hlc")


@pytest.mark.parametrize("case", HLC, ids=ids(HLC))
def test_hlc_vectors(case: dict[str, Any]) -> None:
    data, expected = case["input"], case["expected"]
    match data["op"]:
        case "compare":
            a, b = data["a"], data["b"]
            assert (a > b) - (a < b) == expected
            assert (parse_hlc(a) > parse_hlc(b)) - (parse_hlc(a) < parse_hlc(b)) == expected
        case "format":
            if expected == {"error": True}:
                with pytest.raises(HlcError):
                    format_hlc(data["ms"], data["counter"], data["device"])
            else:
                assert format_hlc(data["ms"], data["counter"], data["device"]) == expected
        case "parse":
            if expected == {"error": True}:
                with pytest.raises(HlcError):
                    parse_hlc(data["value"])
            else:
                parsed = parse_hlc(data["value"])
                assert (parsed.ms, parsed.counter, parsed.device) == (
                    expected["ms"],
                    expected["counter"],
                    expected["device"],
                )
                assert hlc_ms(data["value"]) == expected["ms"]
                assert device_of(data["value"]) == expected["device"]
                assert str(parsed) == data["value"]
        case "send":
            clock = HlcClock(data["device"], data["state"]["l"], data["state"]["c"])
            assert clock.send(data["now"]) == expected["hlc"]
            assert (clock.last_ms, clock.counter) == (
                expected["state"]["l"],
                expected["state"]["c"],
            )
        case "receive":
            clock = HlcClock(uuid.UUID(int=1), data["state"]["l"], data["state"]["c"])
            clock.receive(data["remote"], data["now"])
            assert (clock.last_ms, clock.counter) == (
                expected["state"]["l"],
                expected["state"]["c"],
            )
        case other:  # pragma: no cover
            pytest.fail(f"unknown hlc op {other}")


MERGE = load_cases("sync", "merge")


@pytest.mark.parametrize("case", MERGE, ids=ids(MERGE))
def test_merge_vectors(case: dict[str, Any]) -> None:
    data = case["input"]
    if data["kind"] == "field":
        actual = field_decision(
            same_value=data["current"] == data["incoming"]
            and type(data["current"]) is type(data["incoming"]),
            entry=data["entry"],
            op_hlc=data["hlc"],
            base_version=data["base_version"],
        )
    elif data["kind"] == "delete":
        actual = delete_decision(
            already_deleted=data["deleted"],
            field_entries=data["fields"],
            op_hlc=data["hlc"],
            base_version=data["base_version"],
        )
    else:
        actual = tombstone_edit_decision(
            entry_deleted=data["entry"],
            op_hlc=data["hlc"],
            base_version=data["base_version"],
            restore=data["restore"],
        )
    assert actual == case["expected"]


OUTBOX = load_cases("sync", "outbox")


@pytest.mark.parametrize("case", OUTBOX, ids=ids(OUTBOX))
def test_outbox_vectors(case: dict[str, Any]) -> None:
    data = case["input"]
    if data["op"] == "collapse":
        assert collapse(data["outbox"], data["new"]) == case["expected"]
    else:
        assert rebase_row(data["server_row"], data["outbox"]) == case["expected"]["row"]


SETTINGS = load_cases("sync", "settings_id")


@pytest.mark.parametrize("case", SETTINGS, ids=ids(SETTINGS))
def test_settings_id_vectors(case: dict[str, Any]) -> None:
    assert str(settings_id(case["input"])) == case["expected"]


EPOCH = load_cases("sync", "epoch")


@pytest.mark.parametrize("case", EPOCH, ids=ids(EPOCH))
def test_epoch_vectors(case: dict[str, Any]) -> None:
    data = case["input"]
    assert epoch_action(data["stored"], data["received"]) == case["expected"]


VALIDATION = load_cases("sync", "validation")
_DATETIME = datetime_column("x").adapter
_TEXT = text_column("x", max_length=1000).adapter
_JSON = json_column("x", max_bytes=1_000_000).adapter


@pytest.mark.parametrize("case", VALIDATION, ids=ids(VALIDATION))
def test_validation_vectors(case: dict[str, Any]) -> None:
    data, expected = case["input"], case["expected"]
    if data["op"] == "nested_lists":
        value: Any = []
        for _ in range(data["depth"] - 1):
            value = [value]
        data = {"op": "json", "value": value}
        expected = value if expected is True else expected
    adapter = {"datetime": _DATETIME, "text": _TEXT, "json": _JSON}[data["op"]]
    if expected == {"error": True}:
        with pytest.raises(ValueError):  # noqa: PT011 - pydantic errors are ValueErrors too
            adapter.validate_python(data["value"])
    elif data["op"] == "datetime":
        assert adapter.dump_python(adapter.validate_python(data["value"]), mode="json") == expected
    else:
        assert adapter.validate_python(data["value"]) == expected
