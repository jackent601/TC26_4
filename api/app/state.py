"""Process-wide state: settings and the api catalogue.

The catalogue is read at startup. If a request names a view or function that
isn't in it (e.g. a migration just added one), it is re-read once, so new
database objects appear without restarting the API."""
import os
from dataclasses import dataclass

from . import catalogue as cat


@dataclass
class Settings:
    default_tenant: str | None = os.environ.get("DEFAULT_TENANT") or None


settings = Settings()
catalogue: cat.Catalogue = cat.Catalogue({}, {})


def reload() -> None:
    global catalogue
    catalogue = cat.load()


def lookup_view(name: str):
    if name not in catalogue.views:
        reload()
    return catalogue.views.get(name)


def lookup_function(name: str):
    if name not in catalogue.functions:
        reload()
    return catalogue.functions.get(name)
