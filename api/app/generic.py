"""Generic layer (decision D16): maps HTTP to the database's api schema.

  GET  /api/{view}?col=op.value&select=a,b&order=a.asc,b.desc&limit=50&offset=0
  POST /api/rpc/{function}   JSON body = named arguments

URL shapes follow PostgREST, so another back end serving the same contract
could replace this one (D22). Only objects in the api schema are reachable;
identifiers come from the database catalogue and are always quoted, and every
value is sent as a query parameter, never pasted into SQL.
"""
from typing import Any

from fastapi import APIRouter, Body, HTTPException, Request
from psycopg import sql
from psycopg.types.json import Jsonb

from . import state
from .db import transaction

router = APIRouter()

# PostgREST-style operators -> SQL
OPS = {"eq": "=", "neq": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
RESERVED = {"select", "order", "limit", "offset"}
MAX_LIMIT = 1000


def _tenant(request: Request) -> str | None:
    return request.headers.get("x-tenant") or state.settings.default_tenant


def _user(request: Request) -> str:
    # No login yet: the UI may say who is acting; replaced by real auth later.
    return request.headers.get("x-user") or "anonymous"


def _bad(msg: str) -> HTTPException:
    return HTTPException(status_code=400, detail={"error": msg})


def build_select(view, params: dict[str, str]):
    """Return (query, values) for a GET on a view. Raises 400 on bad input."""
    cols = view.columns

    # select=
    if "select" in params:
        wanted = [c.strip() for c in params["select"].split(",") if c.strip()]
        for c in wanted:
            if c not in cols:
                raise _bad(f"Unknown column in select: {c}")
        select_list = sql.SQL(", ").join(sql.Identifier(c) for c in wanted)
    else:
        select_list = sql.SQL("*")

    # filters: col=op.value
    where, values = [], []
    for key, raw in params.items():
        if key in RESERVED:
            continue
        if key not in cols:
            raise _bad(f"Unknown column: {key}")
        if "." not in raw:
            raise _bad(f"Filter must look like {key}=op.value, e.g. {key}=eq.123")
        op, value = raw.split(".", 1)
        col_type = sql.SQL(cols[key].type)            # from the catalogue, not the request
        ident = sql.Identifier(key)
        if op in OPS:
            where.append(sql.SQL("{} {} %s::{}").format(ident, sql.SQL(OPS[op]), col_type))
            values.append(value)
        elif op == "in":
            if not (value.startswith("(") and value.endswith(")")):
                raise _bad(f"in needs a list, e.g. {key}=in.(a,b)")
            items = [v.strip() for v in value[1:-1].split(",") if v.strip()]
            where.append(sql.SQL("{} = any(%s::{}[])").format(ident, col_type))
            values.append(items)
        elif op == "is":
            if value not in ("null", "true", "false"):
                raise _bad("is takes null, true or false")
            where.append(sql.SQL("{} is " + value).format(ident))
        else:
            raise _bad(f"Unknown operator: {op} (use eq, neq, lt, lte, gt, gte, in, is)")

    # order=col.asc,col2.desc
    order_parts = []
    if params.get("order"):
        for part in params["order"].split(","):
            name, _, direction = part.strip().partition(".")
            if name not in cols:
                raise _bad(f"Unknown column in order: {name}")
            direction = (direction or "asc").lower()
            if direction not in ("asc", "desc"):
                raise _bad("order direction must be asc or desc")
            order_parts.append(sql.SQL("{} " + direction).format(sql.Identifier(name)))

    try:
        limit = min(int(params.get("limit", MAX_LIMIT)), MAX_LIMIT)
        offset = max(int(params.get("offset", 0)), 0)
    except ValueError:
        raise _bad("limit and offset must be whole numbers")

    q = sql.SQL("select {} from api.{}").format(select_list, sql.Identifier(view.name))
    if where:
        q += sql.SQL(" where ") + sql.SQL(" and ").join(where)
    if order_parts:
        q += sql.SQL(" order by ") + sql.SQL(", ").join(order_parts)
    q += sql.SQL(" limit %s offset %s")
    values += [limit, offset]
    return q, values


def build_call(fn, body: dict[str, Any]):
    """Return (query, values) for calling an api function with named arguments."""
    known = {a.name: a for a in fn.args}
    for k in body:
        if k not in known:
            raise _bad(f"Unknown argument for {fn.name}: {k}")
    missing = [a.name for a in fn.args if not a.has_default and a.name not in body]
    if missing:
        raise _bad(f"Missing argument(s) for {fn.name}: {', '.join(missing)}")
    parts, values = [], []
    for a in fn.args:
        if a.name in body:
            parts.append(sql.SQL("{} => %s::{}").format(sql.Identifier(a.name), sql.SQL(a.type)))
            v = body[a.name]
            values.append(Jsonb(v) if isinstance(v, (dict, list)) else v)
    q = sql.SQL("select * from api.{}({})").format(sql.Identifier(fn.name), sql.SQL(", ").join(parts))
    return q, values


@router.get("/api/{view_name}", include_in_schema=False)
def read_view(view_name: str, request: Request):
    view = state.lookup_view(view_name)
    if view is None:
        raise HTTPException(status_code=404, detail={"error": f"No such view: {view_name}"})
    q, values = build_select(view, dict(request.query_params))
    with transaction(_tenant(request), _user(request)) as cur:
        return cur.execute(q, values).fetchall()


@router.post("/api/rpc/{fn_name}", include_in_schema=False)
def call_function(fn_name: str, request: Request, body: dict[str, Any] | None = Body(default=None)):
    fn = state.lookup_function(fn_name)
    if fn is None:
        raise HTTPException(status_code=404, detail={"error": f"No such function: {fn_name}"})
    q, values = build_call(fn, body or {})
    with transaction(_tenant(request), _user(request)) as cur:
        rows = cur.execute(q, values).fetchall()
    if fn.returns_set or fn.out_columns:
        return rows
    # Scalar result: return the bare value.
    return next(iter(rows[0].values())) if rows else None
