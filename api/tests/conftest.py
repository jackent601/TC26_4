"""Shared test fixtures: a made-up api catalogue, so unit tests need no database."""
import pytest

from app.catalogue import Arg, Catalogue, Column, Function, View


@pytest.fixture
def beds_view():
    return View("beds", {
        "bed_id": Column("bed_id", "integer"),
        "code": Column("code", "character varying(30)"),
        "room": Column("room", "text"),
        "valid_from": Column("valid_from", "date"),
        "active": Column("active", "boolean"),
    }, comment="Beds of the current tenant")


@pytest.fixture
def allocate_fn():
    return Function(
        "allocate",
        [Arg("p_bed_id", "integer", False), Arg("p_from", "date", False), Arg("p_note", "text", True)],
        returns_set=False, returns="integer", comment="Allocate a bed")


@pytest.fixture
def summary_fn():
    return Function(
        "summary", [], returns_set=True, returns="TABLE(tenant text, beds bigint)",
        out_columns=[Column("tenant", "text"), Column("beds", "bigint")])


@pytest.fixture
def catalogue(beds_view, allocate_fn, summary_fn):
    return Catalogue({"beds": beds_view},
                     {"allocate": allocate_fn, "summary": summary_fn})
