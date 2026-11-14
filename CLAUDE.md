# CLAUDE.md

Guidance for Claude working in this repository. For the state of work in progress, see `claude_handover.md`.

## What this is

A proof of concept for an accommodation allocation tool, replacing a team's spreadsheet: courses request beds, individuals (anonymous, numbered per course) are allocated to beds for date ranges, and rules raise warnings. Requirements: `docs/Accommodation System Requirements.xlsx` (summarised in the README).

## Principles (read before changing anything)

- **The data model and SQL functions are the core product** (D22). Validation, rules, warnings, availability, suggestions and audit live in PostgreSQL, in the `api` schema's views and functions.
- **Allocation management needs nothing else** (D26). The UI only makes API calls; it never decides what is allowed. Decision engines (e.g. an optimiser) are separate apps that read `api` views and write through `api` functions.
- **The API has no application code** (D27). It is the official PostgREST image serving the `api` schema. If something can't be a SQL view or function, it belongs in a separate app, not in the API layer.
- **Multi-tenant** (D24). Every table has `tenant_id`; row-level security filters to the current tenant, chosen per request with the `X-Tenant` header. DEMO holds sample data and can be reset (D25); LIVE never gets sample data.
- **Minimal custom images.** Only the UI (and the test-only database image) is custom; everything else is an official image, configured.

Decisions are in `docs/decisions.md` (D = design, I = implementation). The build plan and phases are in `docs/build_plan.md`.

## Architecture

| Service | Image | Role |
|---|---|---|
| `db` | `postgres:16` | Data; `core` schema (tables), `api` schema (the contract) |
| `migrate` | dbmate | Applies `db/migrations`, then exits |
| `db-roles` | `postgres:16` | Sets role passwords from `.env`, tells PostgREST to reload, then exits |
| `api` | `postgrest/postgrest` | Serves `api` as `GET /<view>`, `POST /rpc/<function>` |
| `ui` | built from `ui/Dockerfile` (official `node`, then `caddy:2-alpine`) | React + TypeScript (Vite), served by Caddy; `/api/*` proxied to `api` |
| `ui-dev` | `node:22-alpine`, dev profile only | Vite dev server with live reload; also runs npm (`scripts/ui-npm.sh`) |
| `db-test` | custom, test only | Throwaway database: all migrations, pgTAP tests, rollback check |
| `api-docs` | swagger-ui, dev only | Browsable API docs |

Roles: `app_owner` owns every object (not a superuser, so row-level security always applies); `api_user` is the login PostgREST uses; `api_access` holds the grants on `api` only. Nothing but the migration login touches `core` directly.

## Running and testing (Git Bash on Windows)

```
cp .env.example .env            # first time; set the passwords
scripts/db-up.sh                # db, migrations, role passwords; prints pass/fail
scripts/db-seed.sh              # load/reset the DEMO tenant's sample data
scripts/db-reset.sh             # wipe the local volume and rebuild everything (asks first)
docker compose up -d api api-docs
scripts/db-test.sh              # pgTAP tests in a throwaway database; must end ALL PASSED
scripts/api-contract.sh --check # has the API contract changed?
scripts/up.sh                   # everything, UI rebuilt; checks each answers
docker compose --profile dev up ui-dev   # Vite dev server, live reload
scripts/ui-npm.sh run gen:api   # regenerate the typed client after api changes
scripts/ui-npm.sh run build     # type-check and build the UI
```

Dev ports (localhost only): database 5432, API 8000, API docs 8081, Vite dev 5173. UI 8080. There is no Node on the user's machine: run npm through `scripts/ui-npm.sh` (official node image; `node_modules` lives in a volume).

## Conventions

**Migrations** (`db/migrations/NNNN_name.sql`, dbmate):
- `-- migrate:up` and `-- migrate:down` sections; every migration must roll back cleanly (the test run checks this).
- Create objects after `set local role app_owner;` and end the up section with `reset role;`. Create schemas with `authorization app_owner`.
- Schema-qualify every name (`core.beds`, `api.health`); don't rely on `search_path` in migrations.
- New tables: `tenant_id integer default core.current_tenant_id() not null`, composite foreign keys including `tenant_id`, and the tenant row-level security policy (see 0001).
- API functions: `security definer`, `set search_path = pg_catalog, core`, explicit tenant filters as well as row-level security. Raise rule failures with `raise exception '...' using errcode = 'P0001'` (PostgREST returns 400 with the message).
- Add `comment on` for every `api` view and function; it becomes the API documentation.
- Helpers that must not be endpoints go in `api_internal` (or `core`), not `api`.
- Nothing is deployed yet, but prefer a new migration over editing an applied one.

**Tests:** every new `api` function or view gets pgTAP tests in `db/tests/` (rules, warnings, tenant isolation, audit). Run `scripts/db-test.sh` before saying something works. When testing behaviour as `api_user`, connect over the network (host `db`), not `localhost` inside the db container, which skips password checks.

**API contract:** after changing the `api` schema, run `scripts/api-contract.sh` and commit `db/api-contract.txt` with the change, then `scripts/ui-npm.sh run gen:api` and commit `ui/src/api/schema.d.ts`.

**UI:** keep TypeScript on 5.x (`openapi-typescript` needs its JavaScript API; TypeScript 7 has none). Function results and view column nullability aren't in PostgREST's OpenAPI: type them by hand next to the call. Every request sends `X-Tenant` (`tenantHeaders`), and query keys include the tenant.

**Docs:** keep the README, `docs/build_plan.md` and `docs/erd.md` in line with changes. If the data model changes, update `docs/erd.dot` and run `sh docs/build_erd.sh`. Log decisions in `docs/decisions.md`: short entries, design (D) vs implementation (I); supersede old entries rather than rewriting them.

**Scripts:** bash, LF line endings (`.gitattributes`), start with `cd "$(dirname "$0")/.."`, print a clear pass/fail and exit non-zero on failure. Avoid newer Docker Compose features (e.g. `ps --format` templates, `run --build`): the user's version lacks some.

## Working with the user

- Work step by step and verify each step; give the exact commands to run and what they should print.
- Ask before large or hard-to-reverse changes, and before data model changes.
- Keep decision entries and docs concise; the user sometimes wants to see wording before it's saved.
- Prefer files and scripts the user runs over browser automation (token cost).
- Git commits: the user commits; suggest commands rather than committing unasked.
