"""Accommodation allocation API: a thin layer over the database's api schema.
Business logic lives in the database (D22); this service only maps HTTP to it."""
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, Request
from fastapi.exceptions import HTTPException
from fastapi.openapi.utils import get_openapi
from fastapi.responses import JSONResponse

from . import openapi, state
from .db import pool
from .generic import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool.open(wait=True, timeout=30)
    state.reload()
    yield
    pool.close()


app = FastAPI(
    title="Accommodation allocation API",
    version="0.1.0",
    description="Generated from the database's api schema. Select a tenant with the X-Tenant header.",
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
    redoc_url=None,
    lifespan=lifespan,
)
app.include_router(router)


def custom_openapi():
    state.reload()   # always describe the database as it is now
    base = get_openapi(title=app.title, version=app.version, description=app.description, routes=app.routes)
    return openapi.build(base)


app.openapi = custom_openapi


# ------------------------------- errors -----------------------------------
# PostgreSQL error class -> HTTP status. Messages raised by api functions
# (e.g. "Reset is only allowed for a demo tenant") are passed through as-is.
def _status_for(sqlstate: str | None) -> int:
    if not sqlstate:
        return 500
    if sqlstate == "P0001":            # raise exception in an api function: a rule said no
        return 400
    if sqlstate.startswith("23"):      # integrity constraint (unique, foreign key, check)
        return 409
    if sqlstate.startswith("22"):      # bad data, e.g. 'abc' for an integer
        return 400
    if sqlstate == "42501":            # permission / row-level security
        return 403
    return 500


@app.exception_handler(psycopg.Error)
def database_error(request: Request, exc: psycopg.Error):
    code = getattr(exc, "sqlstate", None)
    status = _status_for(code)
    message = exc.diag.message_primary if getattr(exc, "diag", None) and exc.diag.message_primary else str(exc)
    if status == 500:
        message = "Database error"
    return JSONResponse(status_code=status, content={"error": message, "code": code})


@app.exception_handler(HTTPException)
def http_error(request: Request, exc: HTTPException):
    body = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
    return JSONResponse(status_code=exc.status_code, content=body)
