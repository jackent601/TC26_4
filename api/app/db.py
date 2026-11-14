"""Database access: a connection pool and one helper that runs work inside a
transaction with the request's tenant and user set (decision D24)."""
from contextlib import contextmanager
import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

pool = ConnectionPool(
    conninfo=os.environ.get("DATABASE_URL", ""),
    min_size=1,
    max_size=int(os.environ.get("DB_POOL_MAX", "10")),
    open=False,
    kwargs={"row_factory": dict_row, "autocommit": False},
)


@contextmanager
def transaction(tenant: str | None, user: str):
    """Yield a cursor inside one transaction. The tenant (if any) and the user
    are set with transaction scope, so nothing leaks into the next request."""
    with pool.connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute("select set_config('app.user', %s, true)", (user,))
                if tenant:
                    cur.execute("select api.use_tenant(%s)", (tenant,))
                yield cur
