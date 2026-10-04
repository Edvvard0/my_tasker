"""HTTP surface of Stage 6: ``POST /banks/statements/parse`` (spec stage6_banks.md, section 6)."""

import asyncio
from typing import Annotated, Any, Literal

import sqlalchemy as sa
from fastapi import APIRouter, Depends, Query, Request

from tasker.auth.deps import DeviceDep, RuntimeDep, require_schema_version
from tasker.banks.statements import StatementError, parse_statement
from tasker.banks.tables import merchant_category_rules
from tasker.db import SessionDep
from tasker.errors import ApiError
from tasker.uploads import read_capped

router = APIRouter(tags=["banks"], dependencies=[Depends(require_schema_version)])


async def _user_rules(session: SessionDep) -> list[dict[str, Any]]:
    table = merchant_category_rules.table
    async with session.begin():
        rows = (
            await session.execute(
                sa.select(table.c.id, table.c.merchant_key, table.c.match_type, table.c.kind)
                .add_columns(table.c.category_id)
                .where(table.c.deleted_at.is_(None))
            )
        ).all()
    return [
        {
            "id": str(row.id),
            "merchant_key": row.merchant_key,
            "match_type": row.match_type,
            "kind": row.kind,
            "category_id": str(row.category_id),
        }
        for row in rows
    ]


@router.post("/banks/statements/parse")
async def parse_bank_statement(
    request: Request,
    _: DeviceDep,
    session: SessionDep,
    rt: RuntimeDep,
    file_format: Annotated[Literal["csv", "xlsx", "pdf"] | None, Query(alias="format")] = None,
    bank: Literal["auto", "tbank", "vtb", "generic"] = "auto",
) -> dict[str, Any]:
    """The raw file is the request body. It is parsed in memory and never stored; the answer
    lists candidate operations (nothing is created on the server)."""
    data = await read_capped(request, rt.settings.banks_statement_max_bytes)
    if not data:
        raise ApiError(400, "empty_file", "The file is empty")
    rules = await _user_rules(session)
    try:
        result: dict[str, Any] = await asyncio.to_thread(
            parse_statement, data, file_format, bank, rules
        )
    except StatementError as exc:
        raise ApiError(422, exc.code, exc.message) from exc
    return result
