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
│   ├── data_model_slide.svg                   One-page summary of the data model for slides (16:9, key columns only)
│   ├── architecture_slide.svg                 One-page architecture for slides (16:9): thin UI and API, the database as the product
│   ├── architecture_slide.png                 The same, as an image (rendered from the SVG)
│   ├── api_overview_slide.svg/.png            Slide: the Overview page with the API call behind each area
│   ├── api_availability_slide.svg/.png        Slide: the Availability page with the API call behind each area
│   ├── screens/                               Page screenshots for the slides (DEMO, light theme) and capture.js, which takes them
│   └── pages_pocs/                            Clickable page mockups (open the .html files in a browser)
├── db/
│   ├── migrations/                            dbmate migrations, applied in order
│   │   ├── 0001_schema.sql                    The data model as SQL: 15 tables in the core schema, multi-tenant
│   │   ├── 0002_api_schema.sql                The api schema (the contract), api_access and api_user roles
│   │   ├── 0003_reference_data.sql            Tenants (LIVE, DEMO) and their starter attribute types and rules
│   │   ├── 0004_demo.sql                      Demo data loader and api.reset_demo_data (demo tenants only)
│   │   ├── 0005_postgrest.sql                 PostgREST request hook (X-Tenant, X-User) and API descriptions
│   │   ├── 0006_availability_read.sql         Read API for the availability page: locations, course figures, bars, week summary, warnings, clash check
│   │   ├── 0007_facts_not_bands.sql           Facts, not colour bands (D29): allocation percentages; week summary by course
│   │   ├── 0008_bars_full_dates.sql           fn_bed_bars returns full dates; the UI fits bars to the weeks shown
│   │   ├── 0009_write_allocations.sql         Write API for course bookings: allocate, cancel, move, set status; clash rules (D30)
│   │   ├── 0010_course_dates_warning.sql      Warning for course bookings outside their course dates (strict)
│   │   ├── 0011_overview.sql                  Overview page: site_id on course figures and warnings; weekly overview function
│   │   ├── 0012_load_demo_data.sql            Loads DEMO's sample data on a new install (only if DEMO has no beds)
│   │   ├── 0013_candidate_beds.sql            Course-first booking (D35): candidate beds for a course and dates, with a ranked suggestion
│   │   ├── 0014_courses_write.sql             Course management (D36): create, update, update loaded, cancel (with its bookings)
│   │   ├── 0015_audit_trail.sql               Audit trail as sentences (D37): api.audit, api.audit_requests, request ids
│   │   ├── 0016_demo_courses_mon_sun.sql      DEMO sample courses run Monday to Sunday, like a week block; reloads an untouched DEMO
│   │   ├── 0017_external_bookings_outages.sql External bookings and outages (D38): fn_book_external, fn_add_outage; audit wording
│   │   ├── 0018_check_excluding_allocation.sql fn_check_allocation can leave out one booking, to check a move before saving it
│   │   ├── 0019_edit_external_and_outages.sql Change external bookings and outages (D39): fn_update_external, fn_update_outage, fn_remove_outage
│   │   ├── 0020_demo_problems.sql             DEMO sample data shows every kind of warning: adds a double booking and an early arrival
│   │   └── 0021_capacity_warnings.sql         Warnings when a site's scheduled or loaded places plus external bookings exceed its beds in service (D40)
│   ├── test/
│   │   ├── Dockerfile                         Test-only image: PostgreSQL 16 + pgTAP + pg_prove + dbmate
│   │   └── run-tests.sh                       Throwaway database, migrations, tests, rollback check
│   ├── tests/                                 pgTAP tests (schemas and roles, tenancy, reference data, demo reset, PostgREST hook, availability read API, write API, course-dates warning, overview, candidate beds, course management, audit trail, external bookings and outages, checking a move, changing external bookings and outages, capacity warnings)
│   ├── api-contract.txt                       Snapshot of the API contract: the api schema's views and functions
│   └── setup/
│       ├── roles.sql                          Sets api_user's password from .env; tells PostgREST to reload (run by db-roles)
│       └── api_contract.sql                   Lists the api schema's views and functions (used by scripts/api-contract.sh)
├── scripts/
│   ├── db-up.sh                               Starts db, runs migrate and db-roles, shows their output and result
│   ├── db-seed.sh                             Resets the DEMO tenant's sample data to today (calls api.reset_demo_data)
│   ├── db-reset.sh                            Wipes the local database and rebuilds it with sample data
│   ├── db-test.sh                             Runs the database tests in a throwaway database
│   ├── api-contract.sh                        Updates or checks the API contract snapshot (db/api-contract.txt)
│   ├── up.sh                                  Starts everything (database, API, API docs, UI) and checks each answers
│   └── ui-npm.sh                              Runs npm for the UI in the official node image (no Node needed locally)
├── ui/                                        React + TypeScript app (Vite); Dockerfile (node builds, caddy:2-alpine serves), Caddyfile
├── compose.yaml                               Docker Compose services (db, migrate, db-roles, api, ui, db-test)
├── compose.override.yaml                      Local dev extras, loaded automatically (database and API ports, API docs page, ui-dev)
├── compose.prod.yaml                          Production on one server: HTTPS and login on 80/443 (docs/deploy.md)
├── deploy/caddy/                              Production Caddyfile; users.caddy (login accounts, not in git)
└── .env.example                               Settings to copy into .env
```

## Running it

Needs Git and Docker with Compose v2 (Docker Desktop, Podman or Rancher Desktop). Nothing else: the database, API and UI all run in containers. On Windows, run the commands in Git Bash.

**Quick start**

```
git clone https://github.com/jackent601/TC26_4.git
cd TC26_4
cp .env.example .env          # then set POSTGRES_PASSWORD and API_DB_PASSWORD to anything
scripts/up.sh                 # first run takes a few minutes; ends with "All up. Open http://localhost:8080"
```

Open `http://localhost:8080`, choose **DEMO** in the side bar (it comes with sample data, D34) and type your name under "Your name". Stop with `docker compose down` (data is kept); start again with `scripts/up.sh`. If a port is taken (8080 UI, 8000 API, 8081 API docs, 5432 database), change it in `.env`.

**Database only**

```
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

**Tenants and demo data.** The database is multi-tenant: LIVE and DEMO to start with (decisions D24, D25). Every query sees one tenant at a time, selected with `api.use_tenant('LIVE')` or `api.use_tenant('DEMO')`; with none selected nothing is visible. Sample data only ever goes into the DEMO tenant: a new install loads it (migration 0012, D34), and `scripts/db-seed.sh` resets it (the same `api.reset_demo_data()` as the UI's "Reset demo data" button), and it refuses for any non-demo tenant. `scripts/db-reset.sh` wipes the whole local volume and rebuilds everything. Demo dates are relative to the day it is loaded: five weeks from the Monday two weeks ago, with today in the middle week.

**Database tests** run in their own throwaway database, never the one above: `scripts/db-test.sh` (or `docker compose --profile test build db-test` then `docker compose --profile test run --rm db-test`). It applies every migration to an empty database, runs the pgTAP tests in `db/tests/`, checks every migration rolls back and re-applies, and ends with `ALL PASSED` or `FAILED`. pgTAP is only in the test image, never in the deployed database.

**API contract.** The contract between the UI and the back end (D22) is the `api` schema itself: its views and functions with their types, which PostgREST serves as-is. `db/api-contract.txt` is a snapshot of it. With the database running, `scripts/api-contract.sh --check` fails if the contract has changed, and `scripts/api-contract.sh` updates the snapshot, so contract changes are always deliberate and visible in commits. There are no API unit tests because there is no API code: the behaviour is tested in pgTAP (`scripts/db-test.sh`).

**UI.** `scripts/up.sh` starts everything, rebuilds the UI and checks each service answers; then open `http://localhost:8080` (`UI_PORT`). The **Overview** page shows, for the chosen sites and weeks, a weekly chart (beds in service as a dashed line; per week, bars for scheduled and loaded places and a stack of allocated, external and free beds on the busiest night; hover a week for its figures, click the legend to show or hide a series), then **Warnings** and **Courses** tabs (a timeline of courses with scheduled, loaded and allocated, coloured by band). A collapsible side bar holds the pages, the tenant switch (a DEMO pill shows next to the page title on DEMO), "Your name" and the theme (light, dark or follow the system); the page title sits in a bar along the top. All colours come from theme tokens in `ui/src/styles.css`, so light and dark stay in step. and the home page shows `api.health` for the selected tenant, with "Reset demo data" on DEMO only. The Availability page (`/availability`) shows the estate tree against nights, with bars per bed (whole days, from the arrival day to the departure day, here and on the Courses tab) and busiest-night counts on collapsed rows, a legend and warnings strip, read-only popups for everything clickable, and week-block selection (click or drag) that opens a "New allocation" popup listing clashes where a course can be booked into the selected beds; a booking's popup sets its status, moves it or cancels it (an external booking's also changes its reference and name), an outage's popup changes its dates and reason or removes it (D39), and a booking bar can be dragged to another bed and/or days, which opens a popup to confirm the move with its clashes (0018 lets the clash check leave the booking itself out). A course's popup (from the Overview, a warning or a booking) has **Book beds**: with the course's dates and the number of beds still needed, the database suggests free beds that keep the course together and fill rooms, the user ticks or unticks beds (clashes are shown, blocked ones can't be chosen) and books them in one go (D35). **New** on the Overview and Availability toolbars adds a course, an external booking (reference, name, dates and beds ticked by room, each with its clashes) or an outage (any site, building, block, floor, room or bed, with a reason; bookings it lands on are listed and saved as warnings, D38). **New › Course** adds a course (code, name, site, dates, scheduled, loaded, status); so does the faint "New course" row at the top of the Courses tab, where dragging across weeks (as on the availability grid) fills in the dates, Monday to Sunday; and the course popup edits those details, updates the loaded figure, or cancels the course together with its bookings (D36); changing dates or site warns about bookings left outside them. Every change is audited and readable as a sentence (D37): the course and booking popups end with a **History** list ("Phil · 15/11 16:02 · booked FIN-03 into Room 101 bed A, 23/11 to 28/11"), and the Overview's **History** tab lists the latest changes at the chosen sites, one line per action, with a filter by user. Every change is checked, audited and refreshed by the database (D30-D32), and the name typed in the header ("Your name") is sent as `X-User` for the audit log; its toolbar has a location filter (tick the sites, buildings or blocks to show: ticking a parent ticks everything under it; remembered per tenant), a week-range picker (click the dates: a first and last week, or 4, 6, 8 or 12 weeks; 1 to 26 weeks), and the Legend and Settings as popovers, the grid fills the window (days widen to fit, down to a minimum width), and its view settings (weeks shown, minimum day width, colour basis and thresholds, collapsed rows) are kept in the browser. The `ui` image is built from `ui/Dockerfile` with official images only: Node builds the static files, `caddy:2-alpine` serves them and forwards `/api/*` to PostgREST (decision I6). No Node is needed on your machine: npm runs in the official node image.

```
docker compose --profile dev up ui-dev   # dev server with live reload: http://localhost:5173
scripts/ui-npm.sh run gen:api            # regenerate ui/src/api/schema.d.ts after changing the api schema (API must be running)
scripts/ui-npm.sh install <package>      # add a dependency
scripts/ui-npm.sh run build              # type-check and build, as the Dockerfile does
```

**Deploying.** To put it on the internet behind a login (one AWS Lightsail server, about $12 a month), follow [docs/deploy.md](docs/deploy.md): `scripts/deploy.sh` starts it, `scripts/users.sh` manages the logins (D41).

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

1. **No named individuals.** There is no people table. A course's attendees are anonymous and numbered (`individual_no`), an internal identifier the UI never shows (D31); a course may be allocated beyond `scheduled` or `loaded`, and extra individuals take the course defaults. `scheduled` is the planned headcount; `loaded` is the number actually registered, updated as registrations come in. Their attributes (e.g. individual 3 is female, needs step-free access) live in `course_individual_attributes` and override the course defaults in `course_attributes`.
2. **The allocation is the booking.** There is no separate attendance or booking table. `allocations` carries the status (`ALLOCATED` → `BOOKED` → `CHECKED_IN` → `CHECKED_OUT`, or `NO_SHOW` / `CANCELLED`) and the check-in/out times. An individual can have several allocations, e.g. a room move mid-stay.
3. **External bookings** (made outside the tool, e.g. in the booking system) are allocations with no course and no individual number, `source = 'EXTERNAL'`.
4. **Location attributes apply at any level.** Each `location_attributes` row sets exactly one of `site_id` … `bed_id`, with a date range. Attributes are inherited down to beds. `attribute_types.inherit_mode` says how: `NEAREST` (the value set nearest the bed wins, so a room can override its floor) or `ANY` (applies if set at any level above, and can't be overridden).
5. **Outages are attributes, not a separate table.** Taking somewhere out of action is a location attribute `OUT_OF_ACTION = 'Y'` with dates and the reason in `comments`. Its attribute type is `inherit_mode = ANY`, `allow_overlap = Y`, `comment_required = Y`, and a `LOCATION_BLOCKS` rule makes it block every allocation. Both rows are created for every tenant by migration 0003.
6. **Rules are data.** `rules` holds suitability rules of five types: `COMPARE` (individual attribute vs location attribute, e.g. grade ≥ floor minimum), `REQUIRES` (individual flag needs location flag, e.g. step-free), `MATCH_WITHIN` (everyone in a room, floor or block shares an attribute, e.g. no mixed-gender rooms), `SOLE_USE` (individual should not share a room) and `LOCATION_BLOCKS` (location flag blocks everyone, e.g. out of action). Each has a severity: `BLOCK`, `WARNING` or `INFO`.
7. **Warn, don't block.** Everything saves and is shown as a warning, including double bookings and out-of-action beds; a tenant can make those two clashes block by setting their rule's severity to `BLOCK` (D11, D30).
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

- `attribute_types.allow_overlap = 'N'`: no two rows for the same attribute and location with overlapping dates.
- `attribute_types.comment_required = 'Y'`: every row of that attribute has a comment.
- Status transitions on `allocations`: deferred (D31); any change is allowed and audited.
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

## Known limitations

- **Warnings cover only four checks so far.** `api.warnings` (a view, worked out on every read) reports courses loaded above scheduled, bookings on out-of-action beds, double bookings, and course bookings outside their course's dates. The suitability rules already held as data in `core.rules` (migration 0003) are not yet evaluated:
  - `NO_MIXED_GENDER`: occupants of different genders sharing a room;
  - `GRADE_SUITABLE`: seniority checks, an individual's grade below a location's minimum grade;
  - `STEP_FREE_NEEDED`: an individual who needs step-free access placed where there isn't any;
  - `WORK_PATTERN_FLOOR`: full-time and part-time individuals sharing a floor.

  Also not checked: the same individual (course and individual number) in two beds on the same night, e.g. from a room move that overlaps.

  These need the effective attributes of each bed (inherited down the estate) and of each individual (course defaults plus individual overrides) first. Once added, they also belong in the bar flags and in `api.fn_check_allocation`, which today checks only bookings and outages. The DEMO data already contains a case of each. Planned for the rest of phase 1 (`docs/build_plan.md`).

- **A cancelled course can't be reopened in the UI.** The Courses tab and the warnings leave cancelled courses out, so reinstating one (`api.fn_update_course` with a status, D36) is API-only until the tab can show cancelled courses.

- **The audit log is not yet hardened for production.** It is readable in the UI and API (D37), but `changed_by` is the name from the `X-User` header until logins exist, and nothing stops the owner role editing the log. A demo reset clears it with the rest of the tenant's data.

- **Clash severity is changed in the database.** Whether a double booking or an out-of-action bed blocks or warns is the rule's severity in `core.rules` (D30); there is no screen for rules yet.

- **Bookings outside course dates are strict, with no allowance** (migration 0010). Any night before the course's start or departure after its end warns, so a normal arrival the night before a course also warns. The warning is fixed at WARNING, not a rule, so it can't be switched off or set to block. Parked options: an allowance (e.g. 1 night either side) as a team setting on a `COURSE_DATES` rule (which could then also block), or as facts plus a personal allowance in the UI, like the colour thresholds (D29).

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
