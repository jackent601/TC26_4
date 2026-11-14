# Build plan: accommodation allocation PoC

How the PoC is built and in what order. Decisions referenced as Dn are in [`decisions.md`](decisions.md).

## Principles

- **The data model and database functions are the core product** (D22). The back end essentially calls database functions and reads views; the API and UI around them are replaceable.
- **The database holds the logic** (D2). Rules, validation, warnings and audit live in SQL views and functions.
- **The API is thin** (D3, D4). Most endpoints map HTTP straight to a view or function. Custom code is only for what SQL can't do well (solving, file parsing, notifications), and even that reads through views and writes through functions.
- **The UI is thin.** It renders what the API returns and calls API functions; it holds no business rules.
- **Close to production, but light.** Real PostgreSQL, real migrations, tests, one command to run (`docker compose up`). Nothing that only makes sense at large scale.

## Architecture

Four services, each its own container, run together with Docker Compose (D20).

| Service | Image | Role | Exposed |
|---|---|---|---|
| `db` | `postgres:16` (official, unchanged) | Tables, views, functions; data on the `pgdata` volume | Only inside the Compose network (port 5432 published in dev only) |
| `migrate` | `ghcr.io/amacneil/dbmate` (official, unchanged) | Applies `db/migrations`, then exits | No |
| `db-roles` | `postgres:16` (official, used only for `psql`) | Sets role passwords from `.env` (`db/setup/roles.sql`), then exits | No |
| `api` | Built from `api/Dockerfile` (Python 3.12, FastAPI, uvicorn, psycopg 3) | Generic layer and custom modules | Inside the network only |
| `ui` | Built from `ui/Dockerfile`: Node builds the React app, then `caddy:2` serves the built files (no Node at run time) | Serves the app; passes `/api/*` to `api` | Port 8080 on the host |

```
Browser
  │  HTTP, one origin (localhost:8080)
  ▼
ui: Caddy ───────── serves the built React app (static files)
  │  /api/*  → api:8000
  ▼
api: FastAPI ────── generic layer: /api/<view>, /api/rpc/<function>
  │                 custom modules: /api/x/suggest, /api/x/import, ...
  │  SQL as role api_user (api schema only)
  ▼
db: PostgreSQL 16 ─ core schema: tables
  ▲                 api schema: views + functions (the contract)
  │
migrate: dbmate ─── runs once per `up`, then exits
```

Start-up order: `db` becomes healthy (`pg_isready`), `migrate` runs and exits successfully, `db-roles` runs and exits successfully, then `api` starts, then `ui`. Compose handles this with `depends_on` conditions.

```
cp .env.example .env
docker compose up --build
# open http://localhost:8080   (API docs: http://localhost:8080/api/docs)
```

Only `ui` is reachable from outside, so the browser always talks to one origin and the database is never exposed. Each service can be moved to a different host later (for example a managed PostgreSQL in place of `db`) by changing settings in `.env`.

Docker Desktop needs a paid licence in larger organisations; Podman and Rancher Desktop run the same Compose file.

## Database

**Schemas and roles (D17)**

| | Contents | Who can use it |
|---|---|---|
| `core` schema | The 15 tables from `0001_schema.sql` (including `tenants`) | `app_owner` only |
| `api` schema | Views (reads) and functions (writes) | `api_user` |
| `app_owner` role | Owns everything in `core` and `api`; not a superuser, cannot log in (I3) | Used only by migrations (`set local role app_owner`) |
| `api_user` role | Login role FastAPI connects as | `usage` on `api`, `select` on its views, `execute` on its functions; nothing on `core` |

- Functions in `api` are `security definer`, owned by the owner role, so they can write to `core` while `api_user` cannot.
- FastAPI sets `app.user` for each request (`set local`); write functions read it for `audit_log.changed_by`.
- **Tenancy (D24):** every table has `tenant_id`; row-level security (FORCEd, so it also applies inside `api` objects) shows and accepts only the current tenant's rows. FastAPI calls `api.use_tenant(code)` at the start of each request's transaction; with no tenant selected nothing is visible. Tenants: LIVE and DEMO, more can be added.
- Later, per-user roles (which users may use which tenants) can be added inside `api.use_tenant` without changing the API.

**Migrations (D19):** dbmate, one SQL file per change in `db/migrations/`, run by the `migrate` service on every `docker compose up` (already-applied files are skipped). `0001_schema.sql` moves there and gains dbmate's `-- migrate:up` marker.

**Reference and demo data:** reference data (attribute types and rules) is per tenant, installed by `core.load_reference_data` in migration 0003. Demo data (D25) is built by `core.load_sample_data` in migration 0004 and only ever loaded into a demo tenant, through `api.reset_demo_data()`; `db/seed/sample.sql` (run by `scripts/db-seed.sh`) just calls it for DEMO, and the UI's "Reset demo data" will call the same function.

**Tests:** pgTAP tests in `db/tests/`, run by a test-only service, `db-test` (Compose profile `test`): `docker compose --profile test run --rm db-test`. Its image (`db/test/Dockerfile`: `postgres:16` + pgTAP + `pg_prove` + dbmate) starts a throwaway in-memory PostgreSQL, applies all migrations from scratch, runs `pg_prove`, and exits with pass or fail. pgTAP is never installed in the deployed database. Every write function gets tests for its rules and warnings.

## API (FastAPI) (D16)

**Generic layer** (about 200 lines, in `api/app/generic.py`):

| Request | Runs | Notes |
|---|---|---|
| `GET /api/<view>?col=eq.x&order=col.asc&limit=50` | `select ... from api.<view> where ...` | Filters: `eq neq lt lte gt gte in is`; `select=`, `order=`, `limit=`, `offset=` |
| `POST /api/rpc/<function>` with JSON body | `select api.<function>(name => value, ...)` | Body keys become named arguments; result returned as JSON |

- Only objects that exist in the `api` schema are reachable. The list is read from the database catalogue at startup, and identifiers are quoted, never pasted into SQL.
- URL shapes copy PostgREST's, so the UI could later sit on PostgREST, or on ORDS if production is Oracle, with little change.
- Errors map from PostgreSQL error codes: a rule raised in a function (`P0001`) gives 400 with its message; constraint violations (`23xxx`) give 409.
- FastAPI publishes OpenAPI docs at `/api/docs`.

**Custom modules** (`api/app/modules/`), added when needed, each with its own `/api/x/...` routes:

| Module | Purpose | Phase |
|---|---|---|
| `suggest` | Allocation suggestions (see below) | 4 |
| `importer` | Parse the booking-system export, load a staging table, call the validation function, return rejected rows | 5 |
| `notify` | Build arrival and allocation messages for email or Teams | 5 |
| `solver` | Optimisation with OR-Tools (CP-SAT) | Later |

**Suggestions (D18):** the input is `api.v_candidate_beds` (each individual × eligible bed × the warnings that choice would raise); the output is a list of proposed allocations, applied through `api.apply_suggestions(...)`, which runs the same checks and audit as a manual allocation. Phase 4 implements the search in SQL (greedy). A solver can replace it later behind the same endpoint; the UI doesn't change.

## UI (D21)

- **React + TypeScript, built with Vite.** Caddy serves the built files; nginx is a drop-in alternative if the eventual host prefers it.
- **Typed API client** generated from FastAPI's OpenAPI document with `openapi-typescript` (`npm run gen:api`). A change to a view or function shows up as a type error in the UI.
- **Libraries:** TanStack Query (fetching, caching, refresh after saves), TanStack Table and TanStack Virtual (large grids), React Hook Form (popups and forms), React Router (pages), date-fns (dates).
- **Thin:** no business rules in the UI. It shows data from views, calls functions, and displays the warnings they return. Colour thresholds and similar display settings are fine in the UI; anything that decides what is allowed is not.
- **Structure:** each page under `src/pages/`, shared pieces (grid, popup, warnings strip) under `src/components/`, all API access under `src/api/`.
- **First page:** availability, ported from `docs/pages_pocs/availability.html`.
- **Development:** `npm run dev` runs Vite with instant reload and proxies `/api` to the `api` container.

## Repository layout

```
.
├── compose.yaml               The four services
├── compose.override.yaml      Dev extras, loaded automatically: db port on localhost; later bind mounts, auto-reload
├── .env.example               Ports, passwords, settings
├── db/
│   ├── migrations/            dbmate migrations (0001_schema.sql, 0002_api.sql, ...)
│   ├── seed/                  reference.sql, sample.sql
│   ├── setup/                 roles.sql (role passwords from .env)
│   ├── test/                  Dockerfile for the test-only db-test image
│   └── tests/                 pgTAP tests
├── api/
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── app/
│       ├── main.py            App setup, auth hook, error mapping
│       ├── generic.py         /api/<view> and /api/rpc/<function>
│       └── modules/           suggest, importer, notify, solver
├── ui/
│   ├── Dockerfile             Stage 1: node builds the app; stage 2: caddy:2 serves dist/
│   ├── Caddyfile              Static files (with SPA fallback); /api/* → api:8000
│   ├── package.json
│   ├── vite.config.ts         Dev server proxies /api to the api container
│   ├── index.html
│   └── src/
│       ├── main.tsx           App entry, router, query client
│       ├── api/               schema.d.ts (generated), client.ts (typed fetch helpers)
│       ├── components/        Shared UI: TimelineGrid, Popup, WarningsStrip, Legend
│       ├── pages/             Availability/, Courses/, ArrivalsDepartures/, ...
│       └── styles/
└── docs/                      README material, ERD, decisions, mockups, this plan
```

## Phases

| Phase | Delivers | Done when |
|---|---|---|
| 0. Scaffold | Compose file and the four services, dbmate, `core`/`api` schemas and roles, generic layer, React app skeleton with the generated client, one test view shown in the UI | `docker compose up` serves a page that shows data from `api` |
| 1. Read API | `api.v_bed_effective_attributes`, `api.fn_availability(from, to, location)`, `api.fn_bed_rows(...)` for the grid, `api.v_warnings` (rule warnings, double booking, outage clashes, loaded > scheduled) | pgTAP tests pass on the sample data |
| 2. Availability page | The mockup rebuilt in React and wired to phase 1 | Page matches the mockup using live data |
| 3. Write API | `api.allocate` (several beds, date range), `move_allocation`, `set_status`, `cancel_allocation`, `set_location_attribute` (incl. outages), course create/update, `update_loaded`; audit on every write | Popups save; pgTAP tests cover rules, warnings and audit |
| 4. Suggestions | `api.v_candidate_beds`, greedy `api.suggest_allocations`, `api.apply_suggestions`, "Suggest" in the UI | A course can be auto-allocated, warnings shown |
| 5. Remaining Musts and Shoulds | Import, check-in/out page with exceptions, outage impact view, notification output, manager view | Each requirement's demonstration test passes |
| Later | Single sign-on, OR-Tools solver (a module in `api`, or its own service if it gets heavy), deployment target | When the hosting decision is made |

## Open questions

- **Login:** how users sign in at work (e.g. Entra ID). Decides the auth hook in FastAPI and whether a sign-on proxy is needed.
- **Hosting:** on-premises or cloud; decides where each service runs and whether `db` becomes a managed PostgreSQL.
- **Clash setting (D11):** severity on built-in `rules` rows, or a settings table. Decide in phase 3.
- **Status order:** Allocated → Booked, or the reverse. Needed in phase 3.
- **Booking-system export format:** needed for phase 5 import.
