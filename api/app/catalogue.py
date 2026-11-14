"""What the api schema contains: its views (with column types) and functions
(with argument names and types). Read from PostgreSQL's catalogue, so the API
always matches the database; nothing is hand-maintained here."""
from dataclasses import dataclass, field

from .db import pool


@dataclass
class Column:
    name: str
    type: str          # PostgreSQL type, e.g. 'integer', 'date', 'character varying(30)'


@dataclass
class View:
    name: str
    columns: dict[str, Column]
    comment: str | None = None


@dataclass
class Arg:
    name: str
    type: str
    has_default: bool


@dataclass
class Function:
    name: str
    args: list[Arg]
    returns_set: bool           # setof / returns table -> list of rows
    returns: str                # return type text, for docs
    out_columns: list[Column] = field(default_factory=list)
    comment: str | None = None


@dataclass
class Catalogue:
    views: dict[str, View]
    functions: dict[str, Function]


VIEWS_SQL = """
select c.relname as view, a.attname as col, format_type(a.atttypid, a.atttypmod) as type,
       obj_description(c.oid, 'pg_class') as comment
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where n.nspname = 'api' and c.relkind in ('v', 'm', 'r')
order by c.relname, a.attnum
"""

FUNCTIONS_SQL = """
select p.proname as name, p.proretset as returns_set,
       pg_get_function_result(p.oid) as returns,
       coalesce(p.proargnames, '{}') as argnames,
       coalesce(p.proargmodes::text[], '{}') as argmodes,
       coalesce(p.proallargtypes, p.proargtypes::oid[]) as argtypes,
       p.pronargs as n_in, p.pronargdefaults as n_defaults,
       obj_description(p.oid, 'pg_proc') as comment
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'api' and p.prokind = 'f'
order by p.proname
"""


def load() -> Catalogue:
    with pool.connection() as conn, conn.cursor() as cur:
        views: dict[str, View] = {}
        for r in cur.execute(VIEWS_SQL):
            v = views.setdefault(r["view"], View(r["view"], {}, r["comment"]))
            v.columns[r["col"]] = Column(r["col"], r["type"])

        functions: dict[str, Function] = {}
        rows = cur.execute(FUNCTIONS_SQL).fetchall()
        for r in rows:
            names, modes, types = r["argnames"], r["argmodes"], r["argtypes"]
            modes = modes or ["i"] * len(types)
            ins, outs = [], []
            for i, t in enumerate(types):
                tname = cur.execute("select format_type(%s, null) as t", (t,)).fetchone()["t"]
                nm = names[i] if i < len(names) and names[i] else f"arg{i + 1}"
                if modes[i] in ("i", "b", "v"):
                    ins.append((nm, tname))
                if modes[i] in ("o", "b", "t"):
                    outs.append(Column(nm, tname))
            first_default = r["n_in"] - r["n_defaults"]
            args = [Arg(nm, t, i >= first_default) for i, (nm, t) in enumerate(ins)]
            if r["name"] in functions:
                raise RuntimeError(f"api.{r['name']} is overloaded; give each api function a unique name")
            functions[r["name"]] = Function(r["name"], args, r["returns_set"], r["returns"], outs, r["comment"])
        conn.rollback()
    return Catalogue(views, functions)
