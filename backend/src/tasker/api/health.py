from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from tasker.db import SessionDep
from tasker.readiness import check_readiness

router = APIRouter(prefix="/health", tags=["health"])


class LiveOut(BaseModel):
    status: str = "ok"


class NotReadyOut(BaseModel):
    status: str = "unavailable"
    reason: str


@router.get("/live")
async def live() -> LiveOut:
    return LiveOut()


@router.get("/ready", response_model=LiveOut, responses={503: {"model": NotReadyOut}})
async def ready(request: Request, session: SessionDep) -> Response:
    reason = await check_readiness(session, request.app.state.settings.ready_timeout)
    if reason is not None:
        return JSONResponse(NotReadyOut(reason=reason).model_dump(), status_code=503)
    return JSONResponse(LiveOut().model_dump())
