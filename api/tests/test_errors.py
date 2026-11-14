"""Database errors become the right HTTP status, and a rule's own message is
passed through (except for unexpected errors, which stay generic)."""
import json

import pytest

from app.main import _status_for, database_error


@pytest.mark.parametrize("sqlstate,status", [
    ("P0001", 400),   # raise exception in an api function: a rule said no
    ("23505", 409),   # unique violation
    ("23503", 409),   # foreign key violation
    ("23514", 409),   # check violation
    ("22P02", 400),   # invalid input syntax, e.g. 'abc' for integer
    ("22007", 400),   # invalid date
    ("42501", 403),   # permission denied / row-level security
    ("42P01", 500),   # undefined table: our bug, not the caller's
    (None, 500),
])
def test_status_mapping(sqlstate, status):
    assert _status_for(sqlstate) == status


class FakeDiag:
    def __init__(self, message):
        self.message_primary = message


class FakeDbError(Exception):
    def __init__(self, sqlstate, message):
        super().__init__(message)
        self.sqlstate = sqlstate
        self.diag = FakeDiag(message)


def body(response):
    return json.loads(response.body)


def test_rule_message_is_passed_through():
    r = database_error(None, FakeDbError("P0001", "Reset is only allowed for a demo tenant"))
    assert r.status_code == 400
    assert body(r) == {"error": "Reset is only allowed for a demo tenant", "code": "P0001"}


def test_unexpected_errors_do_not_leak_details():
    r = database_error(None, FakeDbError("XX000", "internal detail about tables"))
    assert r.status_code == 500
    assert body(r)["error"] == "Database error"
