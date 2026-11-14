"""The OpenAPI document is built from the api catalogue: one GET per view with a
typed row schema, one POST per function with typed arguments and result."""
import pytest

from app import openapi, state


@pytest.fixture
def doc(catalogue, monkeypatch):
    monkeypatch.setattr(state, "catalogue", catalogue)
    return openapi.build({"openapi": "3.1.0", "info": {"title": "t", "version": "0"}, "paths": {}})


def test_every_view_and_function_has_a_path(doc):
    assert set(doc["paths"]) == {"/api/beds", "/api/rpc/allocate", "/api/rpc/summary"}
    assert "get" in doc["paths"]["/api/beds"]
    assert "post" in doc["paths"]["/api/rpc/allocate"]


def test_view_row_schema_has_typed_columns(doc):
    props = doc["components"]["schemas"]["Beds"]["properties"]
    assert props["bed_id"]["type"] == "integer"
    assert props["code"]["type"] == "string"
    assert props["valid_from"] == {"type": "string", "format": "date", "nullable": True}
    assert props["active"]["type"] == "boolean"


def test_view_returns_a_list_of_rows(doc):
    schema = doc["paths"]["/api/beds"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert schema == {"type": "array", "items": {"$ref": "#/components/schemas/Beds"}}


def test_database_comment_becomes_the_summary(doc):
    assert doc["paths"]["/api/beds"]["get"]["summary"] == "Beds of the current tenant"


def test_function_arguments_and_required(doc):
    args = doc["components"]["schemas"]["ArgsAllocate"]
    assert args["properties"]["p_bed_id"]["type"] == "integer"
    assert args["properties"]["p_from"]["format"] == "date"
    assert args["required"] == ["p_bed_id", "p_from"]          # p_note has a default


def test_scalar_and_table_results(doc):
    scalar = doc["paths"]["/api/rpc/allocate"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert scalar["type"] == "integer"
    table = doc["paths"]["/api/rpc/summary"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert table["type"] == "array"
    assert set(table["items"]["properties"]) == {"tenant", "beds"}


def test_tenant_header_and_error_schema(doc):
    params = doc["paths"]["/api/beds"]["get"]["parameters"]
    assert any(p["name"] == "X-Tenant" and p["in"] == "header" for p in params)
    assert "Error" in doc["components"]["schemas"]


def test_operation_ids_are_unique(doc):
    ids = [op["operationId"] for path in doc["paths"].values() for op in path.values()]
    assert len(ids) == len(set(ids))
