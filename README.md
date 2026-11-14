# Accommodation allocation tool

A tool to replace a team's accommodation-booking spreadsheet. The team books beds for people attending training courses across an estate of sites, buildings, blocks, floors, rooms and beds. Today this is done in one large spreadsheet plus knowledge held in people's heads: who can go where, what clashes, what an out-of-action room affects, nor can they tell if courses have been successfully allocated.

The tool needs to:

- accept course requests (dates, headcount, and attributes of the course or of individuals on it);
- know which beds suit which individuals/courses, from attributes and rules that change over time;
- allocate beds without double-booking or using out-of-action beds;
- show warnings for anything unsuitable or missing, without blocking the user;
- track each booking through to check-in and check-out.
- handle attributes at all accommodation levels, most notables attribute type OUTAGE which denies users from allocating to any affected room
- visualise all of this

**Status: design stage, build starting.** The data model for the MVP is agreed (below) and the PoC platform is chosen (`docs/build_plan.md`). Business logic goes in the database; keep table structure standard SQL where possible.

## Repository layout

```
.
├── README.md                                  This file
├── CLAUDE.md                                  Guidance for Claude (principles, conventions, how to run and test)
├── claude_handover.md                         State of work in progress, for picking up in a new session
├── claude_availability_page_overview.md       What the availability page must do, as agreed (spec for building it)
├── docs/
│   ├── Accommodation System Requirements.xlsx Agreed requirements (summarised below)
│   ├── build_plan.md                          How the PoC is built: architecture, API design, phases
│   ├── decisions.md                           Short log of PoC design decisions
│   ├── erd.dot                                ER diagram source (Graphviz); erd.png and erd.svg are built from it
│   ├── build_erd.sh                           Rebuilds erd.png and erd.svg from erd.dot
│   ├── erd.md                                 Data model: Mermaid ER diagram plus the rules the diagram can't show
│   ├── erd.png                                The same ER diagram as an image
│   ├── erd.svg                                The same ER diagram as a scalable image
│   └── pages_pocs/                            Clickable page mockups (open the .html files in a browser)
├── db/
│   ├── migrations/                            dbmate migrations, applied in order
│   │   ├── 0001_schema.sql                    The data model as SQL: 15 tables in the core schema, multi-tenant
│   │   ├── 0002_api_schema.sql                The api schema (the contract), api_access and api_user roles
│   │   ├── 0003_reference_data.sql            Tenants (LIVE, DEMO) and their starter attribute types and rules
│   │   ├── 0004_demo.sql                      Demo data loader and api.reset_demo_data (demo tenants only)
│   │   ├── 0005_postgrest.sql                 PostgREST request hook (X-Tenant, X-User) and API descriptions
│   │   ├── 0006_availability_read.sql         Read API for the availability page: locations, course figures, bars, week summary, warnings, clash check
│   │   └── 0007_facts_not_bands.sql           Facts, not colour bands (D29): allocation percentages; week summary by course
│   ├── test/
│   │   ├── Dockerfile                         Test-only image: PostgreSQL 16 + pgTAP + pg_prove + dbmate
│   │   └── run-tests.sh                       Throwaway database, migrations, tests, rollback check
│   ├── tests/                                 pgTAP tests (schemas and roles, tenancy, reference data, demo reset, PostgREST hook, availability read API)
│   ├── api-contract.txt                       Snapshot of the API contract: the api schema's views and functions
│   └── setup/
│       ├── roles.sql                          Sets api_user's password from .env; tells PostgREST to reload (run by db-roles)
│       └── api_contract.sql                   Lists the api schema's views and functions (used by scripts/api-contract.sh)
├── scripts/
│   ├── db-up.sh                               Starts db, runs migrate and db-roles, shows their output and result
│   ├── db-seed.sh                             Loads or resets the DEMO tenant's sample data (calls api.reset_demo_data)
│   ├── db-reset.sh                            Wipes the local database and rebuilds it with sample data
│   ├── db-test.sh                             Runs the database tests in a throwaway database
│   ├── api-contract.sh                        Updates or checks the API contract snapshot (db/api-contract.txt)
│   ├── up.sh                                  Starts everything (database, API, API docs, UI) and checks each answers
│   └── ui-npm.sh                              Runs npm for the UI in the official node image (no Node needed locally)
├── ui/                                        React + TypeScript app (Vite); Dockerfile (node builds, caddy:2-alpine serves), Caddyfile
├── compose.yaml                               Docker Compose services (db, migrate, db-roles, api, ui, db-test)
├── compose.override.yaml                      Local dev extras, loaded automatically (database and API ports, API docs page, ui-dev)
└── .env.example                               Settings to copy into .env
```

## Running it

Needs Docker (or Podman / Rancher Desktop).

```
cp .env.example .env          # then change the passwords
docker compose up db migrate db-roles  # PostgreSQL, then migrations, then role passwords
# or, detached with the output and a pass/fail summary (Git Bash):
scripts/db-up.sh
docker compose exec db psql -U accomm_owner -d accomm -c "\dt core.*"
```

**API.** The API is the official PostgREST image, configured only: it serves the database's `api` schema as HTTP, with no application code (decision D27). `docker compose up -d api` starts the database, migrations, role passwords and the API, in that order. In local dev it's on `http://localhost:8000` (`API_PORT` in `.env`), and a browsable docs page is on `http://localhost:8081`. Choose a tenant with the `X-Tenant` header, e.g.:

```
curl -H "X-Tenant: DEMO" http://localhost:8000/health
curl -H "X-Tenant: DEMO" "http://localhost:8000/tenants?select=code,name&order=code.asc"
curl -X POST -H "X-Tenant: DEMO" http://localhost:8000/rpc/reset_demo_data
```

Every view in the `api` schema is a `GET /<view>` (filters like `?col=eq.value`, `select=`, `order=`, `limit=`, `offset=`), and every function is a `POST /rpc/<function>` with its arguments as JSON. The browser reaches the same paths under `/api/` through the UI's Caddy. New views and functions appear after the next migration run (`db-roles` tells PostgREST to reload).

**Tenants and demo data.** The database is multi-tenant: LIVE and DEMO to start with (decisions D24, D25). Every query sees one tenant at a time, selected with `api.use_tenant('LIVE')` or `api.use_tenant('DEMO')`; with none selected nothing is visible. Sample data only ever goes into the DEMO tenant: `scripts/db-seed.sh` loads or resets it (the same `api.reset_demo_data()` as the UI's "Reset demo data" button), and it refuses for any non-demo tenant. `scripts/db-reset.sh` wipes the whole local volume and rebuilds everything. Demo dates are relative to the day it is loaded: five weeks from the Monday two weeks ago, with today in the middle week.

**Database tests** run in their own throwaway database, never the one above: `scripts/db-test.sh` (or `docker compose --profile test build db-test` then `docker compose --profile test run --rm db-test`). It applies every migration to an empty database, runs the pgTAP tests in `db/tests/`, checks every migration rolls back and re-applies, and ends with `ALL PASSED` or `FAILED`. pgTAP is only in the test image, never in the deployed database.

**API contract.** The contract between the UI and the back end (D22) is the `api` schema itself: its views and functions with their types, which PostgREST serves as-is. `db/api-contract.txt` is a snapshot of it. With the database running, `scripts/api-contract.sh --check` fails if the contract has changed, and `scripts/api-contract.sh` updates the snapshot, so contract changes are always deliberate and visible in commits. There are no API unit tests because there is no API code: the behaviour is tested in pgTAP (`scripts/db-test.sh`).

**UI.** `scripts/up.sh` starts everything, rebuilds the UI and checks each service answers; then open `http://localhost:8080` (`UI_PORT`). The header switches between tenants (a "DEMO DATA" banner shows on DEMO), and the home page shows `api.health` for the selected tenant, with "Reset demo data" on DEMO only. The Availability page (`/availability`) shows the estate tree against nights, with bars per bed and busiest-night counts on collapsed rows; its view settings (weeks shown, day width, colour basis and thresholds, collapsed rows) are kept in the browser. The `ui` image is built from `ui/Dockerfile` with official images only: Node builds the static files, `caddy:2-alpine` serves them and forwards `/api/*` to PostgREST (decision I6). No Node is needed on your machine: npm runs in the official node image.

```
docker compose --profile dev up ui-dev   # dev server with live reload: http://localhost:5173
scripts/ui-npm.sh run gen:api            # regenerate ui/src/api/schema.d.ts after changing the api schema (API must be running)
scripts/ui-npm.sh install <package>      # add a dependency
scripts/ui-npm.sh run build              # type-check and build, as the Dockerfile does
```

For local development the database is also published on `localhost:5432` (set `POSTGRES_PORT` in `.env` to change it). Connect any client (DBeaver, pgAdmin, VS Code, psql) with host `localhost`, the port, database `accomm`, user `accomm_owner` and the password from `.env`. It listens on localhost only. To run without the dev extras: `docker compose -f compose.yaml up`.

### File details

- **`docs/Accommodation System Requirements.xlsx`**: one sheet, ten requirements, each with minimum behaviour, a demonstration test and a priority. Summarised in [Requirements](#requirements).
- **`docs/decisions.md`**: short log of PoC design decisions (where logic lives, database choice, open points). Add an entry when something is settled.
- **`docs/erd.md`**: the main description of the data model. A table of the five groups of tables, the full ER diagram as Mermaid (shows in GitHub, GitLab and VS Code), and a list of rules enforced by checks or application logic rather than relationships.
- **`docs/erd.dot`**: Graphviz source for the diagram images. Rebuild them with `sh docs/build_erd.sh` (needs Graphviz installed).
- **`docs/erd.png`, `docs/erd.svg`**: the same model drawn with Graphviz from `erd.dot`, grouped and coloured by area (Supply blue, Demand green, Vocabulary purple, Allocation orange, Audit grey). Use the SVG to zoom.
- **`db/migrations/0001_schema.sql`**: the source of truth for the model. Standard SQL that has been loaded and tested on PostgreSQL 16. Notes at the top explain the small changes needed for SQL Server, MySQL or SQLite (identity columns). Structure only: no data, views, triggers or functions.

If the model changes, add a new migration in `db/migrations/` (or, before anything is deployed, edit `0001_schema.sql`), then bring `erd.md` and `erd.dot` into line and rebuild the images with `sh docs/build_erd.sh`.

## Data model (MVP)

15 tables in six groups, multi-tenant. See `docs/erd.md` for the diagram.

| Group | Tables | Purpose |
|---|---|---|
| Tenancy | `tenants` | LIVE, DEMO, and any added later. Every other table has `tenant_id`; row-level security shows only the current tenant's rows |
| Supply | `sites` > `buildings` > `blocks` > `floors` > `rooms` > `beds`, plus `location_attributes` | The estate down to the bed, and dated attributes set at any level of it |
| Vocabulary and rules | `attribute_types`, `rules` | The list of attributes and how they behave; suitability rules stored as data |
| Demand | `courses`, `course_attributes`, `course_individual_attributes` | Courses, their default attributes, and attributes of individual (anonymous) attendees |
| Allocation | `allocations` | An individual on a course, or an external booking, in a bed for a range of nights. Also holds the booking status and check-in/out times |
| Audit | `audit_log` | Change history. Standalone, no foreign keys |

### Key design decisions

These were settled while simplifying an earlier, Oracle APEX-based proof of concept. Keep them unless there's a reason to revisit.

1. **No named individuals.** There is no people table. A course's attendees are anonymous and numbered 1 to the greater of `scheduled` and `loaded` (`individual_no`). `scheduled` is the planned headcount; `loaded` is the number actually registered, updated as registrations come in. Their attributes (e.g. individual 3 is female, needs step-free access) live in `course_individual_attributes` and override the course defaults in `course_attributes`.
2. **The allocation is the booking.** There is no separate attendance or booking table. `allocations` carries the status (`ALLOCATED` → `BOOKED` → `CHECKED_IN` → `CHECKED_OUT`, or `NO_SHOW` / `CANCELLED`) and the check-in/out times. An individual can have several allocations, e.g. a room move mid-stay.
3. **External bookings** (made outside the tool, e.g. in the booking system) are allocations with no course and no individual number, `source = 'EXTERNAL'`.
4. **Location attributes apply at any level.** Each `location_attributes` row sets exactly one of `site_id` … `bed_id`, with a date range. Attributes are inherited down to beds. `attribute_types.inherit_mode` says how: `NEAREST` (the value set nearest the bed wins, so a room can override its floor) or `ANY` (applies if set at any level above, and can't be overridden).
5. **Outages are attributes, not a separate table.** Taking somewhere out of action is a location attribute `OUT_OF_ACTION = 'Y'` with dates and the reason in `comments`. Its attribute type is `inherit_mode = ANY`, `allow_overlap = Y`, `comment_required = Y`, and a `LOCATION_BLOCKS` rule makes it block every allocation. Both rows are created for every tenant by migration 0003.
6. **Rules are data.** `rules` holds suitability rules of five types: `COMPARE` (individual attribute vs location attribute, e.g. grade ≥ floor minimum), `REQUIRES` (individual flag needs location flag, e.g. step-free), `MATCH_WITHIN` (everyone in a room, floor or block shares an attribute, e.g. no mixed-gender rooms), `SOLE_USE` (individual should not share a room) and `LOCATION_BLOCKS` (location flag blocks everyone, e.g. out of action). Each has a severity: `BLOCK`, `WARNING` or `INFO`.
7. **Warn, don't block.** Only physical impossibilities block an allocation: two people in one bed, one individual in two beds at once, or an out-of-action bed. Everything else saves and is shown as a warning.
8. **Warnings are never stored.** Conflicts and warnings are worked out by queries every time they're shown. For the MVP there is no way to accept or dismiss a warning.
9. **Dates are half-open.** Start is the first night; end is the departure day (exclusive). Two stays overlap when `a.start_date < b.end_date and b.start_date < a.end_date`. Use this everywhere.
10. **Generate nights, don't store them.** Availability ("free beds per night") generates the nights for the requested period in the query (e.g. `generate_series` in PostgreSQL, a recursive query elsewhere). There is no calendar table.
11. **Audit log is standalone** for the MVP: no foreign keys. It keeps `course_id` and `individual_no` only for looking up one individual's history.
12. **Multi-tenant.** Every table belongs to a tenant (LIVE, DEMO, ...). Links include `tenant_id`, so rows can't cross tenants, and row-level security filters every query to the current tenant. Reference data is per tenant. See D24 and D25 in `docs/decisions.md`.

### Deliberately left out of the MVP

| Left out | Consequence | Could come back as |
|---|---|---|
| Room adjacency | Rules can't say "not in neighbouring rooms"; approximate with floor or block scope | A `room_adjacency` table and an `ADJACENT` rule scope |
| Accepting warnings | A warning someone has deliberately allowed keeps showing; the warnings screen needs good filters | An acknowledgements table keyed by allocation and warning code |
| Named people | No names or contact details for check-in lists or notifications | A people table linked from allocations |
| Dated individual attributes | Changes to an individual's attributes aren't time-bound | `valid_from` / `valid_to` columns, as on location attributes |

### Enforced in application logic, not the schema

- `individual_no` is between 1 and the greater of the course's `scheduled` and `loaded` (it isn't a foreign key, as individuals have no table).
- `attribute_types.allow_overlap = 'N'`: no two rows for the same attribute and location with overlapping dates.
- `attribute_types.comment_required = 'Y'`: every row of that attribute has a comment.
- Status transitions on `allocations` follow the order above.
- Writing to `audit_log` when allocations change.
- Warning when a course has `loaded > scheduled` (over-subscribed).

## Requirements

From `docs/Accommodation System Requirements.xlsx`:

| Requirement | Minimum behaviour | Priority |
|---|---|---|
| Data import | Load or paste the agreed accommodation and booking data without re-keying; report rejected or missing fields | Must |
| Availability view | Show available, allocated and unavailable capacity by date and location; identify the limiting date | Must |
| Booking | Create an individual or group/course requirement for a date range | Must |
| Allocation | Recommend or make suitable bed allocations, preventing obvious conflicts | Must |
| Conflict warning | Flag over-capacity, duplicate booking, unsuitable allocation and missing information | Must |
| Outage modelling | Take a block, room or bed out of action and show who or what is affected | Must |
| Check-in/out | Record status through to checked in and checked out, and show exceptions | Must |
| Notification output | Generate arrival/allocation information suitable for email or Teams | Should |
| Management information | Occupancy, forecast pressure, conflicts, no-shows and overdue check-outs in one view | Should |
| Audit/history | Record allocation and status changes and who made them | Could (prototype); required for live use |

## Open questions

- **Platform and database:** chosen for the PoC (PostgreSQL, dbmate, PostgREST, Caddy as Docker Compose services; see `docs/build_plan.md`). Production hosting is still open.
- **Booking system export:** what format it comes in, and whether it has room IDs and references we can match on. This decides how import and reconciliation work.
- **External bookings:** do they carry attributes such as gender? If not, rooms they occupy will show "missing information" warnings.
- **Ownership:** who maintains the attribute list and the rules once they're written down?
- **Allocation suggestions:** the earlier proof of concept used a simple one-at-a-time ("greedy") suggestion. Later this could become a proper optimisation using a constraint solver, treating `BLOCK` rules as hard constraints and warnings as costs.

## Suggested next steps

See [`docs/build_plan.md`](docs/build_plan.md) for the build phases. Platform chosen: PostgreSQL, dbmate, PostgREST and a Caddy-served UI as Docker Compose services (decisions D17–D27).

1. ~~Choose the platform and database.~~ Done.
2. Add the `OUT_OF_ACTION` reference data (attribute type and rule) as a migration or seed script.
3. Write the core queries: effective attributes per bed and per individual, conflicts and warnings, and availability by night.
4. Build the course, allocation, conflicts and arrivals screens, then import.
