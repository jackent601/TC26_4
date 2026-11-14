# Handover: build session of 14 Nov 2026

Context from a long Claude session (in the Claude app, writing to this folder remotely) for whoever picks the work up next, e.g. in Claude Code. General conventions are in `CLAUDE.md`. Delete or update this file once it's no longer current.

## Where things stand

- **Branch:** `postgrest` (branched from `master` after D26). It swaps the FastAPI API for the official PostgREST image (D27).
- **Done:** step 1 (database) and the API.
  - Migrations 0001–0005: multi-tenant core model (15 tables, row-level security), `api` schema and roles, per-tenant reference data, demo data loader and `api.reset_demo_data`, PostgREST pre-request hook.
  - Migration 0006: availability read API (see below).
  - pgTAP: 6 files, 83 checks, plus a rollback/re-apply check; all passing.
  - PostgREST v14.18 tested against the database (tenants, errors, health check, CORS, OpenAPI).
- FastAPI leftovers removed and the PostgREST switch committed; PostgREST v14.18 runs on the user's machine (DEMO health shows 23 beds). `postgrest` is not merged into `master` yet.

## UI skeleton (end of phase 0): built, not yet committed

- `ui/`: React 19 + TypeScript 5 (Vite 8), React Router, TanStack Query, `openapi-fetch` with types from `scripts/ui-npm.sh run gen:api`. Header with the tenant switch (from `api.tenants`, remembered in local storage, defaults to the first non-demo tenant), "DEMO DATA" banner, `api.health`, "Reset demo data" on DEMO only.
- `ui/Dockerfile` (I6): `node:22.23-alpine` builds, `caddy:2.11-alpine` serves; `ui/Caddyfile` has SPA fallback, `/api/*` → `api:3000`, `admin off`, security headers, long cache for `/assets/*` and `no-cache` for the rest.
- `ui-dev` (dev profile, official node image) runs Vite on 5173 and npm via `scripts/ui-npm.sh`; `scripts/up.sh` starts everything and checks it.
- Checked in this session: build passes; `/`, deep links and `/api/health` through Caddy; LIVE and DEMO switch in the browser; reset refused for LIVE; dev server proxy. "Reset demo data" was not clicked in the browser.
- Not done: locking down PostgREST's CORS. The `api-docs` page (port 8081) calls the API from another origin, so it needs CORS or a route through Caddy first.

## Phase 1 read API: `0006_availability_read.sql` (built, not yet committed)

Based on the SQL in `claude_availability_page_overview.md`, with the agreed changes:
- `api.locations` reads each level's table (empty locations show, `bed_count` 0) and has `sort_order`; beds are numbered by code within their room.
- Functions are PL/pgSQL so they can validate: P0001 for `p_to <= p_from`, `p_weeks` outside 1–52, `p_basis` other than `scheduled`/`loaded`, red threshold above green. They also filter by tenant explicitly.
- `DOUBLE_BOOKING` severity is hard-coded WARNING until D11 is decided. Messages name the booking: "SAF-14 #3 is double-booked (Room 101 bed A)".
- The `fn_` prefix stays on functions (`reset_demo_data` is a special case).
- Tests (`db/tests/006_availability_read.sql`, now covering 0006–0008) assert as the test superuser: pgTAP lives in `public`, which `api_user` can't use, and row-level security still applies through `app_owner`. One check calls every endpoint as `api_user`. `002_tenancy` now counts base tables only (the helper views have `tenant_id`).
- `fn_week_summary` breaks ties on the earliest night; on the demo data, week 2's busiest night is night 7, not 10 (BK-4519 overlaps it).
- Contract snapshot and `ui/src/api/schema.d.ts` regenerated.

Still to do in phase 1: effective attributes per bed and individual, and rule warnings (gender, grade, step-free, work pattern) in `api.warnings` and as a flag on bars.

## Phase 2: the availability page in React (in progress)

Rebuilding `docs/pages_pocs/availability.html` on the 0006 endpoints (spec: `claude_availability_page_overview.md`), in five agreed steps:
1. **Done:** `/availability` route; data hooks keyed by tenant (`ui/src/pages/availability/data.ts`); view settings in local storage (`settings.ts`; collapsed rows per tenant); header controls (week navigation, Today, Colour by, Expand all, Collapse to floors, Settings panel).
2. **Done:** grid (`TimelineGrid.tsx`): tree rows, night columns with week lines and weekend shading, axis that stays visible at the bottom, bars on bed rows (outage, allocation, external; on-outage outline, loaded-above-scheduled icon), busiest-night counts on collapsed rows from `fn_week_summary`. Checked in the browser on DEMO, with both bases.
3. **Done:** legend (`LegendAndWarnings.tsx`; shows the user's basis and thresholds) and warnings strip (`api.warnings` that haven't ended before the first night shown, via the PostgREST filter `end_date=gt.<first night>`, no upper limit; earliest first, hidden when empty; booking warnings get their dates). Items aren't clickable yet: step 4 makes them open the course or booking.
4. **Done:** read-only popups (`Popups.tsx`, native `<dialog>`): location (path, beds, outages in the weeks shown), allocation (course, individual, bed, nights, status, scheduled, loaded with time, allocated vs basis and band, warnings, "Open course"), external booking, outage (where set, dates, reason, bookings affected via `fn_check_allocation`), week breakdown (busiest night, counts, courses with bands), course (from the warnings strip or "Open course"). Booking warnings open the booking if it's in the weeks loaded, else the warning's details. Each says which edit form comes in phase 3. Migration 0008 made `fn_bed_bars` return full dates (popups need them); the grid cuts bars to the weeks shown. Closing goes through one function (×, Close, Esc via `cancel`, backdrop) and returns focus to the opener: in testing the browser's `close` event never arrived, so it isn't relied on.
5. Selection (click a week, drag weeks and beds) and the "New allocation" popup with clashes from `fn_check_allocation`; Allocate disabled until phase 3.

Notes: since 0007 (D29) the database returns facts only. `fn_week_summary(p_from, p_weeks)` gives beds by category (free, out_of_action, external, course per `course_id`) on each week's busiest night; `api.course_figures` has `pct_scheduled` and `pct_loaded`. Colour bands exist only in the UI (`look.tsx`, `courseColour`), used by both bars and collapsed rows, so switching Colour by or a threshold makes no request. pgTAP for 0007 is in `db/tests/006_availability_read.sql` (36 checks; 84 in all). The first week shown defaults to the Monday two weeks ago and isn't remembered. The mockup's "Departure day" and "Allow clashes" settings were left out: D9 fixes the week block, and D11 is a database rule.

## The availability page (agreed in the mockup)

Full spec: `claude_availability_page_overview.md`. In short:

Mockup: `docs/pages_pocs/availability.html` (open offline) and its README. Key points:
- Tree on the left (site > building > block > floor > room > bed); one column per night; bars for allocations, external bookings, outages (hatched).
- Course colours: allocated vs `scheduled` or `loaded` (a "Colour by" switch, D13); green at or above the green threshold, amber between, red below the red threshold.
- Collapsed rows: per-week counts of beds by state on the week's limiting (busiest) night.
- Allocating: click a week = one week block (Monday first night, Sunday departure, D9); drag across weeks and down across beds for a group (D10); the popup allows exact dates and lists clashes.
- Clashes (double booking, outages) are allowed with a warning by default; a setting can make them block (D11, open: where that setting lives).
- Warnings strip: courses with loaded > scheduled (D14) and bookings in out-of-action beds.

## Decisions and why (short)

- **Database-first** from the start: the user's main requirement, because production platform and hosting are unknown. Earlier history: an Oracle APEX proof of concept existed; the user moved away from Oracle for this rebuild, but portability to Oracle still matters (PL/pgSQL → PL/SQL, row-level security → VPD, the tenant setting → an application context; VPD may need Enterprise Edition).
- **Separate services, not one image** (D20): the user wants clear db / api / ui separation.
- **FastAPI → PostgREST** (D27): FastAPI worked and was tested (52 unit tests), but PostgREST proves there is no logic outside SQL and needs no custom image. FastAPI is in git history as the reference for a non-PostgreSQL back end.
- **Tenants instead of a separate demo database** (D24): the user chose tenancy for the demo, and for possible multiple teams later. Reference data is per tenant.
- **Demo data in a migration-installed function** (D25), not a seed file: one reset path for scripts and the UI.
- **pgTAP only in a test image** (I2): the deployed `db` is plain `postgres:16`.
- **dbmate's official image for migrations, plus a one-shot `db-roles`** (I1): passwords never live in migrations or git.
- **Week blocks Mon–Sun** (D9), groups by drag (D10), clashes warn (D11), scheduled vs loaded (D12–D14).

## Gotchas found

- dbmate runs each migration and its own bookkeeping in one transaction: `set local search_path` broke dbmate's insert, hence the schema-qualified names.
- Inside the `db` container, `psql` to `localhost` is trusted without a password (official image default). Test passwords with host `db`.
- The user's Docker Compose doesn't support `docker compose ps --format '{{...}}'`; the scripts use `docker inspect` instead.
- Re-running `docker compose up` reuses one-shot containers and their old logs; `scripts/db-up.sh` removes them first.
- The user edited `scripts/db-up.sh` slightly after it was written; leave their changes alone.
- PostgREST `--ready` needs `PGRST_ADMIN_SERVER_HOST=localhost` (set in compose).

## Open questions

- Where the D11 "clashes block" setting lives: severity on built-in rules (needs new rule types, e.g. `DOUBLE_BOOKING`) or a settings table. Decide with the write functions (phase 3).
- Status order: the requirements sheet says Booked → Allocated; the schema says ALLOCATED → BOOKED. Confirm with the team.
- How users log in at work (e.g. Entra ID): decides PostgREST JWT setup.
- Hosting: on-premises or cloud.
- The booking-system export format (phase 5 import).
- Whether live instances ship with demo data loaded (a `DEMO_ENABLED`-style setting was discussed, not built).

## About the user

Jason, a software developer in the UK, on Windows with Git Bash and Docker Desktop. Wants to work step by step and check each step himself; likes concise explanations with the reasoning; prefers minimal custom images and keeping the core value visibly in the data model. Asks "why" questions about tooling (Docker targets, `--build`, script lines): answer them directly.
