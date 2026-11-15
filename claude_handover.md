# Handover: build session of 14 Nov 2026

Context from a long Claude session (in the Claude app, writing to this folder remotely) for whoever picks the work up next, e.g. in Claude Code. General conventions are in `CLAUDE.md`. Delete or update this file once it's no longer current.

## Where things stand

- **Branch:** `write-operations`, branched from `postgrest` on 15 Nov 2026 for phase 3 (write API). `postgrest` holds everything up to the finished read-only availability page; neither is merged into `master` yet.
- **Parked:** rule warnings (rest of phase 1: gender, grade, step-free, work pattern), so the write API could come first. See README "Known limitations".
- **Done:** step 1 (database) and the API.
  - Migrations 0001–0005: multi-tenant core model (15 tables, row-level security), `api` schema and roles, per-tenant reference data, demo data loader and `api.reset_demo_data`, PostgREST pre-request hook.
  - Migration 0006: availability read API (see below).
  - Migrations 0007–0008: facts not colour bands (D29); full bar dates. Migrations 0009–0010: write API and course-dates warning (below).
  - pgTAP: 8 files, 137 checks, plus a rollback/re-apply check; all passing.
  - PostgREST v14.18 tested against the database (tenants, errors, health check, CORS, OpenAPI).
- FastAPI leftovers removed and the PostgREST switch committed; PostgREST v14.18 runs on the user's machine (DEMO health shows 23 beds). `postgrest` is not merged into `master` yet.

## UI skeleton (end of phase 0): built, not yet committed

- `ui/`: React 19 + TypeScript 5 (Vite 8), React Router, TanStack Query, `openapi-fetch` with types from `scripts/ui-npm.sh run gen:api`. Header with the tenant switch (from `api.tenants`, remembered in local storage, defaults to the first non-demo tenant), "DEMO DATA" banner, `api.health`, "Reset demo data" on DEMO only.
- `ui/Dockerfile` (I6): `node:22.23-alpine` builds, `caddy:2.11-alpine` serves; `ui/Caddyfile` has SPA fallback, `/api/*` → `api:3000`, `admin off`, security headers, long cache for `/assets/*` and `no-cache` for the rest.
- `ui-dev` (dev profile, official node image) runs Vite on 5173 and npm via `scripts/ui-npm.sh`; `scripts/up.sh` starts everything and checks it.
- Checked in this session: build passes; `/`, deep links and `/api/health` through Caddy; LIVE and DEMO switch in the browser; reset refused for LIVE; dev server proxy. "Reset demo data" was not clicked in the browser.
- Not done: locking down PostgREST's CORS. The `api-docs` page (port 8081) calls the API from another origin, so it needs CORS or a route through Caddy first.

## UI look (15 Nov 2026, uncommitted at the time of writing)

- **Theme:** tokens in `ui/src/styles.css`, as CSS variables for surfaces, text, borders, accent, danger/ok, grid lines, row levels and bar states. They're redefined under `:root[data-theme="dark"]`. `src/theme.tsx` holds Light / System / Dark (stored as `accomm.theme`; System follows the OS live). A small script in `index.html` applies it before React loads, so there's no flash. No hard-coded colours outside the tokens.
- **Shell** (`src/Layout.tsx`, icons in `src/icons.tsx`): a collapsible side bar (232 px, or 64 px icons only; stored as `accomm.nav.collapsed`) with the pages, then tenant, "Your name" and theme at the bottom. The title bar shows the page name and, on DEMO, a DEMO pill (tooltip: sample data, can be reset). The DEMO DATA banner was removed at the user's request. Pages in `FILL` (availability) fill the main area with no page scroll.
- **Availability:** the page h1 and subtitle are gone (the title bar has them). The toolbar has week navigation on the left and Colour by, Expand all, Collapse to floors, **Legend** and **Settings** on the right; the last two are popovers that close on a click outside or Esc. The legend is a vertical list (beds, courses by basis, markers).
- **Grid fills the page:** it takes the remaining height, the axis sits at the bottom, and a `ResizeObserver` widens days to fill the width. The setting is now `minDayWidth` (default 16 px, renamed so old stored widths don't carry over); below it the grid scrolls sideways. The label column is 260 px (`LABEL_WIDTH` must match `.av-label`).
- **Checked in the browser** at 1440×860, in dark and light: no horizontal scroll, the legend popover, and collapsing the side bar (days widen from 21 to 25 px).
- **Week range:** the dates in the toolbar open a picker (`RangePicker` in `Controls.tsx`). It takes a first and last week (any date snaps to its Monday; the last week is included) or quick 4, 6, 8 or 12 weeks from the first. Show sets the start and `weeks` (now 1–26; the database allows 52). `Popover` takes a custom trigger and a `close` callback.
- **Location filter** (`Filter.tsx`): a toolbar button showing "All locations", one block's name, "2 of 3 blocks" or "No locations". It opens a tick-box tree of sites, buildings and blocks: ticking a parent ticks every block under it, and a parent with some ticked is half-ticked (indeterminate). All and None buttons. State: `{ blocks: string[] | null }` (null = all, so new blocks show; ticking everything goes back to null), stored per tenant as `accomm.availability.filter.<tenant>.v2`. `pruneTree` keeps ticked blocks with their sites and buildings; a site or building missing some blocks is copied with `partial: true` and a bed count of what's shown. Partial headers can't collapse (no toggle, "filtered" in the label), because fn_week_summary's counts for them cover all their blocks. Display only: the data requests still cover the whole estate.

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

## Phase 2: the availability page in React (read-only parts done)

Rebuilding `docs/pages_pocs/availability.html` on the 0006 endpoints (spec: `claude_availability_page_overview.md`), in five agreed steps:
1. **Done:** `/availability` route; data hooks keyed by tenant (`ui/src/pages/availability/data.ts`); view settings in local storage (`settings.ts`; collapsed rows per tenant); header controls (week navigation, Today, Colour by, Expand all, Collapse to floors, Settings panel).
2. **Done:** grid (`TimelineGrid.tsx`): tree rows, night columns with week lines and weekend shading, axis that stays visible at the bottom, bars on bed rows (outage, allocation, external; on-outage outline, loaded-above-scheduled icon), busiest-night counts on collapsed rows from `fn_week_summary`. Checked in the browser on DEMO, with both bases.
3. **Done:** legend (`LegendAndWarnings.tsx`; shows the user's basis and thresholds) and warnings strip (`api.warnings` that haven't ended before the first night shown, via the PostgREST filter `end_date=gt.<first night>`, no upper limit; earliest first, hidden when empty; booking warnings get their dates). Items open the course or booking (step 4).
4. **Done:** read-only popups (`Popups.tsx`, native `<dialog>`): location (path, beds, outages in the weeks shown), allocation (course, individual, bed, nights, status, scheduled, loaded with time, allocated vs basis and band, warnings, "Open course"), external booking, outage (where set, dates, reason, bookings affected via `fn_check_allocation`), week breakdown (busiest night, counts, courses with bands), course (from the warnings strip or "Open course"). Booking warnings open the booking if it's in the weeks loaded, else the warning's details. Each says which edit form comes in phase 3. Migration 0008 made `fn_bed_bars` return full dates (popups need them); the grid cuts bars to the weeks shown. Closing goes through one function (×, Close, Esc via `cancel`, backdrop) and returns focus to the opener: in testing the browser's `close` event never arrived, so it isn't relied on.
5. **Done:** selection (`TimelineGrid.tsx`): an invisible button (`.av-add`) fills the empty part of each bed row. Clicking it selects that week block (Monday first night, Sunday departure, 6 nights, D9). Dragging selects across weeks and down across beds, skipping group rows (D10), with a dashed outline labelled e.g. "4 beds · 2 weeks · 02/11 – 15/11". Activating it from the keyboard selects the first week shown. On release the "New allocation" popup lists the beds, has editable first night and departure, the number of nights, and every clash from `fn_check_allocation` ("allowed with a warning, D11"). Allocate is disabled until phase 3, and choosing the course and individuals comes then too. Limits: dragging doesn't scroll the grid, so a selection is limited to the part on screen. There's no "clashes block" mode yet: that waits on D11's setting.

Notes: since 0007 (D29) the database returns facts only. `fn_week_summary(p_from, p_weeks)` gives beds by category (free, out_of_action, external, course per `course_id`) on each week's busiest night; `api.course_figures` has `pct_scheduled` and `pct_loaded`. Colour bands exist only in the UI (`look.tsx`, `courseColour`), used by both bars and collapsed rows, so switching Colour by or a threshold makes no request. pgTAP for 0007 is in `db/tests/006_availability_read.sql` (36 checks; 84 in all). The first week shown defaults to the Monday two weeks ago and isn't remembered. The mockup's "Departure day" and "Allow clashes" settings were left out: D9 fixes the week block, and D11 is a database rule.

## Phase 3 write API: `0009_write_allocations.sql` (database and course-booking UI done)

Agreed with the user (D30–D32):
- **Clashes are rules (D30):** new rule type `BED_CLASH`, a `DOUBLE_BOOKING` rule per tenant (WARNING). With `OUT_OF_ACTION`, each rule's severity decides: WARNING saves with a warning, BLOCK refuses the whole request. An inactive rule isn't checked. `core.load_reference_data` now wraps the 0003 loader (renamed `load_reference_data_0003`) and adds the rule.
- **Individuals are internal (D31):** `individual_no` is kept for attributes and rules but never shown. Course booking assigns the course's lowest number not already in a bed on those nights, with no upper limit, so a course can be allocated beyond scheduled or loaded. Messages from `api.warnings` and `fn_check_allocation` name the course, not "#n". Status is per allocation (one bed, one stay); any change is allowed for now, and transition rules are deferred.
- **Course booking first (D32):** `api.fn_allocate_course(course, bed_ids[], from, to)` returns `(allocation_id, bed_id, warnings[])`. `fn_cancel_allocation(id)` keeps the row as CANCELLED. `fn_move_allocation(id, bed?, from?, to?)` takes whatever is left null from the current values. `fn_set_status(id, status)` sets or clears the check-in and check-out times. All are audited to `core.audit_log` (detail is JSON; the user comes from `X-User`). Beds are locked (`for update`) while allocating. `fn_check_allocation` gained `blocks`.
- **Helpers** in `api_internal` (not endpoints): `bed_clashes`, `audit`, `require_tenant`.
- **Tests:** `db/tests/007_write_api.sql` (43 checks). A pgTAP gotcha: one statement can't see rows its own function call inserted, so tests read back in a second statement.
- **Tried on the user's stack** through Caddy with `X-User`, then DEMO was reset.
- **UI (done):**
  - **Your name:** a "Your name" box in the header (`src/user.tsx`, kept in local storage). `tenantHeaders` adds it as `X-User`, with non-ASCII characters replaced by "?".
  - **Writes** in `pages/availability/writes.ts`. Each one refreshes every query on success.
  - **New allocation popup:** "Course booking" and "One-off booking" boxes; one-off is disabled until it's built (needs `LOCAL` bookings without a course). It has a course picker listing only courses that run on at least one selected night (earliest first, defaulting to the first; it switches to that if the dates change so the chosen course no longer runs, and says "No courses run on these nights" when none do) and "Use the course's dates". The clash list says "Not allowed" and disables Allocate when any clash `blocks`. After saving, the popup shows what was saved and the warnings returned.
  - **Booking popup** (course allocations only, not external bookings): a Change section with status, move (bed and/or dates) and cancel (with a confirm). Results and returned warnings go to a dismissible notice under the warnings strip.
  - **No "#n" shown:** bars read e.g. `TEC-07 · 6/10`, and the popup title is the course. Attribute badges wait for the parked rule warnings.
  - **Checked in the browser on DEMO** (reset afterwards): booking a free week; booking onto INT-22 (saved with a warning); the same with `DOUBLE_BOOKING` set to BLOCK ("Not allowed", Allocate disabled); then status, move and cancel. The audit log showed all four as "UI tester".
- **Course-dates warning (`0010_course_dates_warning.sql`):** a course booking with any night before its course's start, or departure after its end, warns. It's strict, with no allowance (parked; README "Known limitations"), and fixed at WARNING, not a rule. `api_internal.course_dates_warning` is used by:
  - `api.warnings` (kind `OUTSIDE_COURSE_DATES`);
  - the warnings `fn_allocate_course` and `fn_move_allocation` return;
  - `fn_check_allocation`'s new optional `p_course_id`, which adds a `COURSE_DATES` row with no bed.

  The New allocation popup shows it under the clashes and it clears with "Use the course's dates". Tests: `db/tests/008_course_dates.sql` (10 checks; 137 in all). The 0010 down section restores 0009's function bodies, which were extracted from 0009.
- **Not built:** one-off bookings, outage editing (`set_location_attribute`), course create/update and `update_loaded`. Status transitions are deferred (D31).
- **Known limitation:** the same individual in two beds on the same night isn't checked (README).

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

- ~~Where the D11 "clashes block" setting lives~~: rule severity (D30).
- Status order and transitions: deferred (D31). The requirements sheet says Booked → Allocated; the schema says ALLOCATED → BOOKED. Confirm with the team.
- How users log in at work (e.g. Entra ID): decides PostgREST JWT setup.
- Hosting: on-premises or cloud.
- The booking-system export format (phase 5 import).
- Whether live instances ship with demo data loaded (a `DEMO_ENABLED`-style setting was discussed, not built).

## About the user

Jason, a software developer in the UK, on Windows with Git Bash and Docker Desktop. Wants to work step by step and check each step himself; likes concise explanations with the reasoning; prefers minimal custom images and keeping the core value visibly in the data model. Asks "why" questions about tooling (Docker targets, `--build`, script lines): answer them directly.

## Course management (0013, 15 Nov 2026, uncommitted at the time of writing)

Branch `phil-dev` (renamed from a short-lived `course-first-booking`), holding 0012 and 0013 uncommitted on top of `main`.

- **Database (`0013_courses_write.sql`, D35):** `api.fn_create_course`, `fn_update_course` (nulls keep values; `p_clear_site` removes the site; `p_notes` empty clears notes; returns warnings for live bookings left outside the dates or on another site), `fn_update_loaded` (stamps `loaded_at`), `fn_cancel_course` (cancels the course and its live allocations, each audited with reason "course cancelled"). Shared checks in `api_internal.check_course` (code unique per tenant, case-insensitive; lengths; dates; non-negative figures; status REQUESTED or CONFIRMED; site in the tenant). A cancelled course is reinstated by `fn_update_course` with a status; its bookings stay cancelled. Tests: `db/tests/011_courses_write.sql` (25 checks; 194 in all), all passing with the rollback check.
- **UI:** "New course" on the Overview toolbar (`NewCoursePopup`; after saving it offers "Book beds"). The Course popup's placeholder is replaced by `CourseChanges`: the same `CourseFields` form, Save changes (only changed fields are sent), Update loaded, and Cancel course with a confirm; a cancelled course shows a Reinstate form instead. Hooks in `writes.ts` build the request bodies from the generated `paths` types. The Overview notice now lists returned warnings like the Availability one.
- **Not in the UI:** notes (the API takes them, but `api.course_figures` doesn't return them; add the column to the view when a form needs it); reopening a cancelled course (the Courses tab hides them); the audit log (no `api` view); rule severities (changed in `core.rules` directly). All listed in README "Known limitations".
- **Checked:** `scripts/db-test.sh` ALL PASSED, `gen:api` and `scripts/api-contract.sh` run, UI build (see below).

## Course-first booking (0012, 15 Nov 2026, uncommitted at the time of writing)

Checked on the Mac: `scripts/db-test.sh` ALL PASSED (169 checks, rollback and re-apply of 12 migrations), `scripts/api-contract.sh --check` unchanged after the hand edit, `scripts/ui-npm.sh run gen:api` regenerated the client, and `scripts/ui-npm.sh run build` passed.

- **Database (`0012_candidate_beds.sql`, D34):**
  - `api.fn_candidate_beds(p_course_id, p_from, p_to, p_beds)`: every bed on the course's site (all beds when it has no site), in estate order, with `free` (no booking or outage on the nights, whatever the rules say), `warnings` (the clashes the active rules would raise, worded like `bed_clashes`), `blocks`, `course_in_room`, and a suggestion of `p_beds` free beds (`suggested`, `rank`). Greedy: rooms where the course already has a bed first, then rooms with the most free beds, then estate order; a room is taken whole while it fits what is still needed, then the smallest room that can hold the rest is split. `stable`, so no temp tables: the per-bed facts come from `api_internal.candidate_bed_facts` (not an endpoint), called more than once per request.
  - Tests: `db/tests/010_candidate_beds.sql` (22 checks), with the expected suggestions worked out by hand from the demo estate (Block A floors 1-3, Block B floor 1; rooms 103, 204 and 303 have one bed).
  - `db/api-contract.txt` and `ui/src/api/schema.d.ts` are the script outputs (contract confirmed unchanged; client regenerated).
- **UI:** the Course popup has a "Book beds" action (`BookCoursePopup` in `Popups.tsx`; `useCandidateBeds` in `data.ts`; `CandidateBed` and the `bookCourse` popup kind in `types.ts`). First night and departure default to the course's dates; beds needed defaults to the larger of scheduled and loaded less allocated. Candidate beds are listed by room with the suggestion ticked; ticking by hand is remembered per dates-and-quantity until "Back to the suggestion"; blocked beds can't be ticked. Booking calls `fn_allocate_course` with the ticked beds and shows the same result view as the grid's New allocation popup (`AllocatedResult`, shared). Works from the Overview too (it uses the same `PopupView`).
- **Docs:** D34 in `docs/decisions.md`; build plan phase 4 and the suggestions paragraph; README migrations, tests and UI paragraph.

## Overview page (0011, 15 Nov 2026, uncommitted at the time of writing)

- **Database (`0011_overview.sql`, D33):**
  - `api.course_figures` and `api.warnings` gained `site_id`. For warnings it's the bed's site, or the course's for course-level warnings.
  - `api.fn_weekly_overview(p_from, p_weeks, p_site_ids)` returns per week: beds in service on the busiest night, split into allocated, external and free; plus scheduled and loaded totals and the number of courses running.
  - The down section restores 0007's `course_figures` and 0010's `warnings` (both dropped and recreated, since columns can't be removed in place).
  - Tests: `db/tests/009_overview.sql` (10 checks; 147 in all), with the weekly figures worked out by hand.
- **UI (`ui/src/pages/overview/`):**
  - Side bar entry "Overview".
  - Toolbar: week arrows, the shared `RangePicker`, and a site filter (`useSiteFilter`, per tenant `accomm.overview.sites.<tenant>`; null = all).
  - `WeeklyChart.tsx`: plain SVG themed by `--chart-*` tokens. A hover or focus target per week shows a tooltip; the legend buttons hide or show series.
  - Tabs: Warnings (`useWarnings` now takes an optional `to` and site ids, filtered in PostgREST) and Courses (`CourseTimeline.tsx`). Both open the same popups as Availability, through `PopupView`.
  - Course colours use the shared view settings (basis and thresholds).
- **Checked in the browser:** the chart matches the tested figures; tooltip, legend toggles, opening a warning and a course, and the site filter (None empties both).
