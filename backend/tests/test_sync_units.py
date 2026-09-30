import uuid
from datetime import UTC, datetime

import pytest
import sqlalchemy as sa

from tasker.clock import SystemClock, from_ms, to_ms
from tasker.hlc import HLC_LENGTH, HlcClock, HlcError, format_hlc, parse_hlc
from tasker.ids import is_uuid7, uuid7
from tasker.sync.registry import (
    SyncRegistry,
    bool_column,
    datetime_column,
    define_sync_table,
    enum_column,
    int_column,
    json_column,
    reference_column,
    text_column,
    uuid_column,
)
from tasker.sync.user_settings import settings_id, user_settings

DEVICE = "0195f2a0-0000-7000-8000-00000000000a"


def test_uuid7_is_valid_sortable_and_strictly_increasing() -> None:
    values = [uuid7() for _ in range(2000)]
    assert all(is_uuid7(value) for value in values)
    assert values == sorted(values)
    assert len(set(values)) == len(values)
    assert not is_uuid7(uuid.uuid4())
    assert not is_uuid7(uuid.uuid1())
    fixed = uuid7(ms=1_790_856_000_123)
    assert is_uuid7(fixed)
    assert fixed.hex.startswith(f"{1_790_856_000_123:012x}")


def test_clock_helpers_round_trip() -> None:
    assert to_ms(datetime(2026, 10, 1, 12, 0, 0, 123000, tzinfo=UTC)) == 1_790_856_000_123
    assert from_ms(1_790_856_000_123) == datetime(2026, 10, 1, 12, 0, 0, 123000, tzinfo=UTC)
    now = SystemClock().now()
    assert now.tzinfo is UTC
    assert from_ms(to_ms(now)) <= now


def test_hlc_string_is_fixed_length_and_ordered() -> None:
    a = format_hlc(1000, 2, DEVICE)
    assert len(a) == HLC_LENGTH
    assert format_hlc(1000, 10, DEVICE) > a
    assert format_hlc(1001, 0, DEVICE) > format_hlc(1000, 99999, DEVICE)
    assert parse_hlc(a) == parse_hlc(a)
    with pytest.raises(HlcError):
        parse_hlc(5)


def test_hlc_clock_never_goes_backwards() -> None:
    clock = HlcClock(DEVICE)
    stamps = [clock.send(now) for now in (100, 100, 90, 100, 200, 150)]
    assert stamps == sorted(stamps)
    assert len(set(stamps)) == len(stamps)
    clock.receive(format_hlc(5000, 3, str(uuid.UUID(int=7))), 300)
    assert clock.send(300) > format_hlc(5000, 3, str(uuid.UUID(int=7)))


def test_settings_id_is_deterministic_and_key_specific() -> None:
    assert settings_id("ui.theme") == settings_id("ui.theme")
    assert settings_id("ui.theme") != settings_id("ui.lang")
    assert str(settings_id("ui.theme")) == "826e9351-d34d-5a3d-99d0-d20367415629"
    assert user_settings.id_rule(settings_id("a"), {"key": "a"}) is None
    assert user_settings.id_rule(uuid7(), {"key": "a"}) is not None


def test_registry_rules() -> None:
    metadata = sa.MetaData()
    parent = define_sync_table(metadata, "p", (text_column("title"),))
    child = define_sync_table(metadata, "c", (reference_column("p_id", "p"),))
    orphan = define_sync_table(metadata, "o", (reference_column("x_id", "missing"),))
    registry = SyncRegistry()
    with pytest.raises(ValueError, match="must be registered first"):
        registry.register(child)
    registry.register(parent)
    registry.register(child)
    with pytest.raises(ValueError, match="already registered"):
        registry.register(parent)
    with pytest.raises(ValueError, match="must be registered first"):
        registry.register(orphan)
    assert registry.get("p") is parent
    assert registry.get("nope") is None
    assert [spec.name for spec in registry.tables()] == ["p", "c"]
    assert [spec.name for spec in registry.purge_order()] == ["c", "p"]
    assert [(spec.name, col.name) for spec, col in registry.children_of("p")] == [("c", "p_id")]
    assert registry.children_of("c") == []
    assert [col.name for col in child.parents()] == ["p_id"]


@pytest.mark.parametrize(
    "reserved",
    [
        "id",
        "created_at",
        "updated_at",
        "deleted_at",
        "server_version",
        "origin_device_id",
        "field_meta",
    ],
)
def test_service_column_names_are_reserved(reserved: str) -> None:
    with pytest.raises(ValueError, match="reserved"):
        define_sync_table(sa.MetaData(), "t", (text_column(reserved),))


def test_defined_table_has_service_columns_and_index() -> None:
    spec = define_sync_table(sa.MetaData(), "t", (int_column("n", required=False),))
    names = {column.name for column in spec.table.columns}
    assert {
        "id",
        "created_at",
        "updated_at",
        "deleted_at",
        "server_version",
        "origin_device_id",
        "field_meta",
        "n",
    } <= names
    assert spec.table.c.n.nullable is True  # optional columns may stay empty
    assert any(index.columns.keys() == ["server_version"] for index in spec.table.indexes)


@pytest.mark.parametrize(
    ("column", "good", "bad"),
    [
        (text_column("t", max_length=3, min_length=1), ["a", "abc"], ["", "abcd", 5, None]),
        (text_column("t", pattern=r"^[a-z]+$"), ["abc"], ["ABC", "a b"]),
        (int_column("n", ge=0, le=5), [0, 5], [-1, 6, 1.5, True, "1"]),
        (bool_column("b"), [True, False], [1, 0, "true"]),
        (
            datetime_column("d"),
            ["2026-10-01T00:00:00Z", "2026-10-01T00:00:00+03:00"],
            ["2026-10-01T00:00:00", "x", 5],
        ),
        (enum_column("e", ("x", "y")), ["x", "y"], ["z", "xy", 1]),
        (
            json_column("j", max_bytes=10),
            [1, "a", [1], {"a": 1}, None],
            ["x" * 20, float("nan"), {1, 2}],
        ),
        (uuid_column("u"), ["0195f2a0-0000-7000-8000-00000000000a"], ["nope", 5]),
    ],
)
def test_column_validation(column, good, bad) -> None:  # type: ignore[no-untyped-def]
    for value in good:
        column.adapter.validate_python(value)
    for value in bad:
        with pytest.raises((ValueError, TypeError)):
            column.adapter.validate_python(value)


def test_json_column_dump_is_identity() -> None:
    assert json_column("j").adapter.dump_python({"a": [1]}, mode="json") == {"a": [1]}
