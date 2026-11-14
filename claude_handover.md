# Handover: build session of 14 Nov 2026

Context from a long Claude session (in the Claude app, writing to this folder remotely) for whoever picks the work up next, e.g. in Claude Code. General conventions are in `CLAUDE.md`. Delete or update this file once it's no longer current.

## Where things stand

- **Branch:** `postgrest` (branched from `master` after D26). It swaps the FastAPI API for the official PostgREST image (D27).
- **Done:** step 1 (database) and the API.
  - Migrations 0001–0005: multi-tenant core model (15 tables, row-level security), `api` schema and roles, per-tenant reference data, demo data loader and `api.reset_demo_data`, PostgREST pre-request hook.
  - pgTAP: 5 files, 48 checks, plus a rollback/re-apply check; all passing in the session's PostgreSQL 16.
  - PostgREST v14.18 tested against the database (tenants, errors, health check, CORS, OpenAPI).
- **Waiting on the user** (may already be done; check `git status` and `git log`):
  1. Delete the FastAPI leftovers: `git rm -r api scripts/api-test.sh`.
  2. Verify on their machine: `docker compose down --remove-orphans`, `scripts/db-up.sh` (should apply 0005), `docker compose up -d api api-docs`, `curl -H "X-Tenant: DEMO" http://localhost:8000/health` (23 beds once seeded), `scripts/api-contract.sh --check`, `scripts/db-test.sh` (48 tests, ALL PASSED).
  3. Commit on `postgrest`, then decide whether to merge into `master`.
- **Not verified:** the Docker image tags `postgrest/postgrest:v14.18` and `swaggerapi/swagger-ui` (latest) could not be checked from the session. If v14.18 won't pull, try `:latest` and pin what it reports.

## Next step: UI skeleton (end of phase 0)

Agreed scope (D21, adjusted for PostgREST):
- `ui/` with React + TypeScript (Vite). `ui/Dockerfile`: Node builds, then `caddy:2` serves `dist/`. The only service exposed outside (port 8080).
- `Caddyfile`: serve the app with SPA fallback; `handle_path /api/*` → `api:3000` (strip the prefix). Then PostgREST's CORS can be locked down, and `API_PUBLIC_URL` becomes `http://localhost:8080/api`.
- Typed client: PostgREST's OpenAPI is Swagger 2.0, so convert (e.g. `swagger2openapi`) then `openapi-typescript`; `npm run gen:api`.
- First screen: header with a LIVE / DEMO switch (sends `X-Tenant`), a clear "DEMO DATA" banner, `api.health` for the selected tenant, and a "Reset demo data" button (DEMO only) calling `/api/rpc/reset_demo_data`.
- Libraries planned: TanStack Query, Table, Virtual; React Hook Form; React Router; date-fns.
- Vite dev server proxies `/api` to `http://localhost:8000`. Add a `scripts/up.sh` that starts everything and prints the URLs.

After that: phase 1 (read functions behind the availability page), then phase 2 (rebuild the availability mockup in React). See `docs/build_plan.md`.

## The availability page (agreed in the mockup)

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
