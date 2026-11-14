-- migrate:up
--------------------------------------------------------------------------------
-- 0002: the "api" schema and the roles that may use it.
--
-- The api schema is the contract (decisions D17, D22): the API service can
-- only read its views and execute its functions. It cannot see core tables.
--   api_access  group role (no login) holding the grants on the api schema
--   api_user    login role the API service connects as; member of api_access
-- api_user's password is set outside migrations, from .env, by
-- db/setup/roles.sql (run by the db-roles service after every migration run).
--
-- Views and functions in api are owned by app_owner (see 0001), so they read
-- and write core tables on api_user's behalf, always filtered to the current
-- tenant by row-level security. The API selects the tenant per request with
-- api.use_tenant(code).
--------------------------------------------------------------------------------
do $$
begin
  if not exists (select from pg_roles where rolname = 'api_access') then
    create role api_access nologin;
  end if;
  if not exists (select from pg_roles where rolname = 'api_user') then
    create role api_user login;
  end if;
end
$$;
grant api_access to api_user;

-- Nothing in public for anyone but the database owner.
revoke all on schema public from public;

create schema api authorization app_owner;
set local role app_owner;

revoke all on schema core from public;

-- api: usage, read every view, execute every function (now and future).
grant usage on schema api to api_access;
alter default privileges in schema api grant select on tables to api_access;
alter default privileges in schema api grant execute on functions to api_access;
-- Functions are executable by everyone by default; only api_access gets that.
alter default privileges revoke execute on functions from public;

-- Select the tenant for this transaction (or the session, if p_local is false).
-- Returns the tenant code. Raises if the code is unknown.
create function api.use_tenant(p_code text, p_local boolean default true)
returns text
language plpgsql security definer
set search_path = pg_catalog, core
as $$
declare
  v_id integer;
begin
  select tenant_id into v_id from core.tenants where code = p_code;
  if v_id is null then
    raise exception 'Unknown tenant: %', p_code using errcode = 'P0001';
  end if;
  perform set_config('app.tenant_id', v_id::text, p_local);
  return p_code;
end
$$;

-- Tenants the UI can switch between.
create view api.tenants as
select code, name, is_demo
from core.tenants;

-- Health check, used to prove the wiring end to end. Counts the current
-- tenant's beds only (row-level security).
create view api.health as
select 'ok'::text                                   as status,
       now()                                        as checked_at,
       (select code from core.tenants
         where tenant_id = core.current_tenant_id()) as tenant,
       (select count(*) from core.beds)             as bed_count;

reset role;

-- migrate:down
drop schema api cascade;
alter default privileges for role app_owner grant execute on functions to public;
grant usage on schema public to public;
drop role if exists api_user;
drop role if exists api_access;
