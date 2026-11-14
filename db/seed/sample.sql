--------------------------------------------------------------------------------
-- Load (or reset) the DEMO tenant's sample data. Dev and demos only; it never
-- touches any other tenant. The data itself lives in core.load_sample_data
-- (migration 0004), so the UI's "Reset demo data" does exactly the same.
-- Run with:  scripts/db-seed.sh   (or: docker compose --profile seed run --rm db-seed)
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on
begin;
select api.use_tenant('DEMO') as tenant \gset
select * from api.reset_demo_data();
commit;
