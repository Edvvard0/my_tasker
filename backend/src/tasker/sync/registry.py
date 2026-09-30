"""Registry of synchronised tables: modules declare columns, validators and parent links."""

import json
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from pydantic import AwareDatetime, Field, StrictBool, StrictInt, StringConstraints, TypeAdapter
from sqlalchemy.dialects.postgresql import JSONB, TIMESTAMP
from sqlalchemy.dialects.postgresql import UUID as PG_UUID
from sqlalchemy.types import TypeEngine

from tasker.ids import is_uuid7

SERVICE_FIELDS = (
    "id",
    "created_at",
    "updated_at",
    "deleted_at",
    "server_version",
    "origin_device_id",
)

# Returns an error message, or None when the value is fine.
RowValidator = Callable[[Mapping[str, Any]], str | None]
IdRule = Callable[[uuid.UUID, Mapping[str, Any]], str | None]


@dataclass(frozen=True, slots=True)
class ColumnSpec:
    name: str
    sql_type: TypeEngine[Any]
    adapter: Any  # pydantic TypeAdapter (or a duck-typed equivalent)
    nullable: bool = False
    required: bool = True
    immutable: bool = False
    parent: str | None = None


class _StringParsed:
    """Duck-typed adapter: only JSON strings are accepted, then parsed by ``inner``."""

    def __init__(self, inner: "TypeAdapter[Any]") -> None:
        self._inner = inner

    def validate_python(self, value: Any) -> Any:
        if not isinstance(value, str):
            raise ValueError("expected a string")
        return self._inner.validate_python(value)

    def dump_python(self, value: Any, *, mode: Literal["json", "python"] = "json") -> Any:
        return self._inner.dump_python(value, mode=mode)


def text_column(
    name: str,
    *,
    max_length: int = 1000,
    min_length: int = 0,
    pattern: str | None = None,
    nullable: bool = False,
    required: bool = True,
    immutable: bool = False,
) -> ColumnSpec:
    constraints = StringConstraints(min_length=min_length, max_length=max_length, pattern=pattern)
    return ColumnSpec(
        name,
        sa.Text(),
        TypeAdapter(Annotated[str, constraints], config={"strict": True}),
        nullable=nullable,
        required=required,
        immutable=immutable,
    )


def int_column(
    name: str,
    *,
    ge: int = -(2**63),
    le: int = 2**63 - 1,
    nullable: bool = False,
    required: bool = True,
) -> ColumnSpec:
    adapter: TypeAdapter[int] = TypeAdapter(Annotated[StrictInt, Field(ge=ge, le=le)])
    return ColumnSpec(name, sa.BigInteger(), adapter, nullable=nullable, required=required)


def bool_column(name: str, *, nullable: bool = False, required: bool = True) -> ColumnSpec:
    return ColumnSpec(
        name, sa.Boolean(), TypeAdapter(StrictBool), nullable=nullable, required=required
    )


def datetime_column(name: str, *, nullable: bool = False, required: bool = True) -> ColumnSpec:
    return ColumnSpec(
        name,
        TIMESTAMP(timezone=True),
        _StringParsed(TypeAdapter(AwareDatetime)),
        nullable=nullable,
        required=required,
    )


def enum_column(
    name: str, values: tuple[str, ...], *, nullable: bool = False, required: bool = True
) -> ColumnSpec:
    pattern = "^(" + "|".join(values) + ")$"
    return ColumnSpec(
        name,
        sa.Text(),
        TypeAdapter(Annotated[str, StringConstraints(pattern=pattern)], config={"strict": True}),
        nullable=nullable,
        required=required,
    )


def json_column(
    name: str, *, max_bytes: int = 16384, nullable: bool = False, required: bool = True
) -> ColumnSpec:
    return ColumnSpec(
        name,
        JSONB(none_as_null=False),
        _JsonAdapter(max_bytes),
        nullable=nullable,
        required=required,
    )


class _JsonAdapter:
    """Duck-typed adapter: any JSON value whose serialised size is bounded."""

    def __init__(self, max_bytes: int) -> None:
        self._max_bytes = max_bytes

    def validate_python(self, value: Any) -> Any:
        try:
            encoded = json.dumps(value, allow_nan=False, separators=(",", ":"))
        except (TypeError, ValueError) as exc:
            raise ValueError("not a JSON value") from exc
        if len(encoded.encode()) > self._max_bytes:
            raise ValueError(f"value is larger than {self._max_bytes} bytes")
        return value

    def dump_python(self, value: Any, *, mode: str = "json") -> Any:
        return value


def reference_column(
    name: str, parent: str, *, nullable: bool = False, required: bool = True
) -> ColumnSpec:
    return ColumnSpec(
        name,
        PG_UUID(as_uuid=True),
        _StringParsed(TypeAdapter(uuid.UUID)),
        nullable=nullable,
        required=required,
        parent=parent,
    )


def uuid_column(name: str, *, nullable: bool = False, required: bool = True) -> ColumnSpec:
    return ColumnSpec(
        name,
        PG_UUID(as_uuid=True),
        _StringParsed(TypeAdapter(uuid.UUID)),
        nullable=nullable,
        required=required,
    )


def uuid7_id_rule(row_id: uuid.UUID, _values: Mapping[str, Any]) -> str | None:
    return None if is_uuid7(row_id) else "id must be a UUIDv7"


@dataclass(slots=True)
class SyncTableSpec:
    name: str
    columns: tuple[ColumnSpec, ...]
    table: sa.Table
    id_rule: IdRule = uuid7_id_rule
    validators: tuple[RowValidator, ...] = ()
    by_name: dict[str, ColumnSpec] = field(init=False)

    def __post_init__(self) -> None:
        self.by_name = {column.name: column for column in self.columns}

    def parents(self) -> list[ColumnSpec]:
        return [column for column in self.columns if column.parent is not None]


def define_sync_table(
    metadata: sa.MetaData,
    name: str,
    columns: tuple[ColumnSpec, ...],
    *,
    id_rule: IdRule = uuid7_id_rule,
    validators: tuple[RowValidator, ...] = (),
) -> SyncTableSpec:
    """Build the SQLAlchemy table (service columns + declared columns) and its spec."""
    for column in columns:
        if column.name in SERVICE_FIELDS or column.name == "field_meta":
            raise ValueError(f"{column.name!r} is a reserved service column")
    sa_columns: list[sa.Column[Any]] = [
        sa.Column("id", PG_UUID(as_uuid=True), primary_key=True),
        sa.Column("created_at", TIMESTAMP(timezone=True), nullable=False),
        sa.Column("updated_at", sa.Text, nullable=False),
        sa.Column("deleted_at", TIMESTAMP(timezone=True)),
        sa.Column("server_version", sa.BigInteger, nullable=False, index=True),
        sa.Column("origin_device_id", PG_UUID(as_uuid=True), nullable=False),
        sa.Column("field_meta", JSONB, nullable=False, server_default="{}"),
    ]
    for column in columns:
        args: list[Any] = [column.name, column.sql_type]
        if column.parent is not None:
            args.append(sa.ForeignKey(f"{column.parent}.id"))
        sa_columns.append(sa.Column(*args, nullable=column.nullable or not column.required))
    table = sa.Table(name, metadata, *sa_columns)
    return SyncTableSpec(name, tuple(columns), table, id_rule, validators)


class SyncRegistry:
    def __init__(self) -> None:
        self._tables: dict[str, SyncTableSpec] = {}

    def register(self, spec: SyncTableSpec) -> SyncTableSpec:
        if spec.name in self._tables:
            raise ValueError(f"sync table {spec.name!r} is already registered")
        for column in spec.parents():
            if column.parent not in self._tables:
                raise ValueError(f"parent table {column.parent!r} must be registered first")
        self._tables[spec.name] = spec
        return spec

    def get(self, name: str) -> SyncTableSpec | None:
        return self._tables.get(name)

    def tables(self) -> list[SyncTableSpec]:
        return list(self._tables.values())

    def children_of(self, name: str) -> list[tuple[SyncTableSpec, ColumnSpec]]:
        return [
            (spec, column)
            for spec in self._tables.values()
            for column in spec.parents()
            if column.parent == name
        ]

    def purge_order(self) -> list[SyncTableSpec]:
        """Children before parents (parents are registered first, so reverse order works)."""
        return list(reversed(self._tables.values()))
