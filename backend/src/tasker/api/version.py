import structlog
from fastapi import APIRouter
from pydantic import BaseModel
from sqlalchemy.exc import SQLAlchemyError

from tasker.db import SessionDep
from tasker.epoch import read_epoch
from tasker.errors import ApiError
from tasker.version import API_SCHEMA_VERSION, APP_VERSION, MIN_CLIENT_SCHEMA_VERSION

log = structlog.get_logger("api.version")
router = APIRouter(tags=["meta"])


class VersionOut(BaseModel):
    app_version: str
    api_schema_version: int
    min_client_schema_version: int
    server_epoch: str


@router.get("/version")
async def version(session: SessionDep) -> VersionOut:
    try:
        async with session.begin():
            epoch = await read_epoch(session)
    except (SQLAlchemyError, OSError) as exc:
        log.warning("version_db_unavailable", error_type=type(exc).__name__)
        raise ApiError(503, "database_unavailable", "The database is not reachable") from exc
    return VersionOut(
        app_version=APP_VERSION,
        api_schema_version=API_SCHEMA_VERSION,
        min_client_schema_version=MIN_CLIENT_SCHEMA_VERSION,
        server_epoch=epoch,
    )
