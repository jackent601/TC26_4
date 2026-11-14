"""The generic layer turns HTTP requests into SQL safely: identifiers from the
catalogue (quoted), values only as parameters, bad input rejected with 400."""
import pytest
from fastapi import HTTPException
from psycopg.types.json import Jsonb

from app.generic import MAX_LIMIT, build_call, build_select


def sql_text(q):
    return q.as_string(None)


# ------------------------------- reading views ------------------------------

def test_plain_select_reads_the_api_view_with_default_limit(beds_view):
    q, values = build_select(beds_view, {})
    assert sql_text(q) == 'select * from api."beds" limit %s offset %s'
    assert values == [MAX_LIMIT, 0]


def test_select_list_is_quoted_identifiers(beds_view):
    q, _ = build_select(beds_view, {"select": "code,room"})
    assert sql_text(q).startswith('select "code", "room" from api."beds"')


@pytest.mark.parametrize("op,sql_op", [("eq", "="), ("neq", "<>"), ("lt", "<"),
                                       ("lte", "<="), ("gt", ">"), ("gte", ">=")])
def test_comparison_operators(beds_view, op, sql_op):
    q, values = build_select(beds_view, {"bed_id": f"{op}.5"})
    assert f'where "bed_id" {sql_op} %s::integer' in sql_text(q)
    assert values[0] == "5"


def test_value_is_cast_to_the_column_type(beds_view):
    q, values = build_select(beds_view, {"valid_from": "gte.2026-11-16"})
    assert '"valid_from" >= %s::date' in sql_text(q)
    assert values[0] == "2026-11-16"


def test_in_list(beds_view):
    q, values = build_select(beds_view, {"code": "in.(a, b,c)"})
    assert '"code" = any(%s::character varying(30)[])' in sql_text(q)
    assert values[0] == ["a", "b", "c"]


@pytest.mark.parametrize("v", ["null", "true", "false"])
def test_is(beds_view, v):
    q, values = build_select(beds_view, {"active": f"is.{v}"})
    assert f'"active" is {v}' in sql_text(q)
    assert values == [MAX_LIMIT, 0]          # no parameter for is


def test_several_filters_are_anded(beds_view):
    q, _ = build_select(beds_view, {"bed_id": "gt.1", "room": "eq.101"})
    assert 'where "bed_id" > %s::integer and "room" = %s::text' in sql_text(q)


def test_order(beds_view):
    q, _ = build_select(beds_view, {"order": "room.asc,bed_id.desc"})
    assert 'order by "room" asc, "bed_id" desc' in sql_text(q)


def test_order_defaults_to_ascending(beds_view):
    q, _ = build_select(beds_view, {"order": "room"})
    assert 'order by "room" asc' in sql_text(q)


def test_limit_is_capped_and_offset_not_negative(beds_view):
    _, values = build_select(beds_view, {"limit": "999999", "offset": "-5"})
    assert values[-2:] == [MAX_LIMIT, 0]


def test_values_never_appear_in_the_sql(beds_view):
    nasty = "x'; drop table core.beds; --"
    q, values = build_select(beds_view, {"room": f"eq.{nasty}"})
    assert nasty not in sql_text(q)
    assert values[0] == nasty


@pytest.mark.parametrize("params,message", [
    ({"nope": "eq.1"}, "Unknown column: nope"),
    ({"select": 'code";drop table x;--'}, "Unknown column in select"),
    ({"order": "nope.asc"}, "Unknown column in order"),
    ({"order": "room.sideways"}, "order direction must be asc or desc"),
    ({"room": "like.10%"}, "Unknown operator: like"),
    ({"room": "101"}, "Filter must look like room=op.value"),
    ({"code": "in.a,b"}, "in needs a list"),
    ({"active": "is.maybe"}, "is takes null, true or false"),
    ({"limit": "ten"}, "limit and offset must be whole numbers"),
])
def test_bad_input_is_rejected_with_400(beds_view, params, message):
    with pytest.raises(HTTPException) as e:
        build_select(beds_view, params)
    assert e.value.status_code == 400
    assert message in e.value.detail["error"]


# ------------------------------ calling functions ---------------------------

def test_call_uses_named_typed_arguments(allocate_fn):
    q, values = build_call(allocate_fn, {"p_bed_id": 7, "p_from": "2026-11-16"})
    assert sql_text(q) == 'select * from api."allocate"("p_bed_id" => %s::integer, "p_from" => %s::date)'
    assert values == [7, "2026-11-16"]


def test_optional_argument_is_passed_when_given(allocate_fn):
    q, values = build_call(allocate_fn, {"p_bed_id": 7, "p_from": "2026-11-16", "p_note": "hi"})
    assert '"p_note" => %s::text' in sql_text(q)
    assert values[-1] == "hi"


def test_function_with_no_arguments(summary_fn):
    q, values = build_call(summary_fn, {})
    assert sql_text(q) == 'select * from api."summary"()'
    assert values == []


def test_objects_are_sent_as_json(allocate_fn):
    _, values = build_call(allocate_fn, {"p_bed_id": 7, "p_from": "2026-11-16", "p_note": {"a": 1}})
    assert isinstance(values[-1], Jsonb)


def test_missing_required_argument(allocate_fn):
    with pytest.raises(HTTPException) as e:
        build_call(allocate_fn, {"p_bed_id": 7})
    assert e.value.status_code == 400
    assert "Missing argument(s) for allocate: p_from" in e.value.detail["error"]


def test_unknown_argument(allocate_fn):
    with pytest.raises(HTTPException) as e:
        build_call(allocate_fn, {"p_bed_id": 7, "p_from": "2026-11-16", "p_evil": 1})
    assert "Unknown argument for allocate: p_evil" in e.value.detail["error"]
