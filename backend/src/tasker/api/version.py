from fastapi import APIRouter
from pydantic import BaseModel

from tasker.version import API_SCHEMA_VERSION, APP_VERSION, MIN_CLIENT_SCHEMA_VERSION

router = APIRouter(tags=["meta"])


class VersionOut(BaseModel):
    app_version: str
    api_schema_version: int
    min_client_schema_version: int


@router.get("/version")
async def version() -> VersionOut:
    return VersionOut(
        app_version=APP_VERSION,
        api_schema_version=API_SCHEMA_VERSION,
        min_client_schema_version=MIN_CLIENT_SCHEMA_VERSION,
    )
