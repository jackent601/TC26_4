"""OpenAPI document generated from the api schema (decision D22: the spec is
the contract between UI and back end). Every view becomes a GET path with a
typed row schema; every function becomes a POST path with typed arguments.
The UI's typed client is generated from this document."""
from . import state

TYPE_MAP = {
    "integer": {"type": "integer"}, "smallint": {"type": "integer"}, "bigint": {"type": "integer"},
    "numeric": {"type": "number"}, "real": {"type": "number"}, "double precision": {"type": "number"},
    "boolean": {"type": "boolean"},
    "date": {"type": "string", "format": "date"},
    "timestamp without time zone": {"type": "string", "format": "date-time"},
    "timestamp with time zone": {"type": "string", "format": "date-time"},
    "json": {}, "jsonb": {},
}

FILTER_HELP = ("Filter rows with col=op.value. Operators: eq, neq, lt, lte, gt, gte, "
               "in (e.g. in.(a,b)), is (null|true|false). Also select=a,b, order=a.asc,b.desc, limit, offset.")

TENANT_HEADER = {"name": "X-Tenant", "in": "header", "required": False,
                 "schema": {"type": "string"}, "description": "Tenant code, e.g. LIVE or DEMO"}
ERROR = {"description": "Error", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}


def json_type(pg_type: str) -> dict:
    base = pg_type.split("(")[0].strip()
    return dict(TYPE_MAP.get(base, {"type": "string"}))


def _schema_name(prefix: str, name: str) -> str:
    return prefix + "".join(p.capitalize() for p in name.split("_"))


def build(base: dict) -> dict:
    doc = dict(base)
    paths = dict(doc.get("paths", {}))
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    schemas["Error"] = {"type": "object", "properties": {"error": {"type": "string"}, "code": {"type": "string"}}}

    for v in sorted(state.catalogue.views.values(), key=lambda v: v.name):
        sname = _schema_name("", v.name)
        schemas[sname] = {"type": "object",
                          "properties": {c.name: json_type(c.type) | {"nullable": True} for c in v.columns.values()}}
        paths[f"/api/{v.name}"] = {"get": {
            "tags": ["views"], "operationId": f"get_{v.name}",
            "summary": v.comment or f"Read api.{v.name}", "description": FILTER_HELP,
            "parameters": [TENANT_HEADER] + [
                {"name": p, "in": "query", "required": False, "schema": {"type": "string"}}
                for p in ("select", "order", "limit", "offset")],
            "responses": {"200": {"description": "Rows", "content": {"application/json": {
                "schema": {"type": "array", "items": {"$ref": f"#/components/schemas/{sname}"}}}}},
                "400": ERROR, "403": ERROR, "404": ERROR}}}

    for f in sorted(state.catalogue.functions.values(), key=lambda f: f.name):
        args_name = _schema_name("Args", f.name)
        schemas[args_name] = {"type": "object",
                              "properties": {a.name: json_type(a.type) for a in f.args},
                              "required": [a.name for a in f.args if not a.has_default]}
        if f.out_columns:
            row = {"type": "object", "properties": {c.name: json_type(c.type) | {"nullable": True} for c in f.out_columns}}
            result = {"type": "array", "items": row}
        else:
            result = json_type(f.returns) | {"nullable": True}
        paths[f"/api/rpc/{f.name}"] = {"post": {
            "tags": ["functions"], "operationId": f"rpc_{f.name}",
            "summary": f.comment or f"Call api.{f.name} (returns {f.returns})",
            "parameters": [TENANT_HEADER],
            "requestBody": {"required": bool(schemas[args_name]["required"]), "content": {"application/json": {
                "schema": {"$ref": f"#/components/schemas/{args_name}"}}}},
            "responses": {"200": {"description": "Result", "content": {"application/json": {"schema": result}}},
                          "400": ERROR, "403": ERROR, "404": ERROR, "409": ERROR}}}

    doc["paths"] = paths
    return doc
