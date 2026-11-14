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
-- Views in api run with their owner's rights (the migration owner), so a view
-- can read core tables on api_user's behalf. Functions that write will be
-- "security definer" for the same reason.
--------------------------------------------------------------------------------
create schema api;

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

-- Nothing in core or public for anyone but the owner.
revoke all on schema core from public;
revoke all on schema public from public;

-- api: usage, read every view, execute every function (now and future).
grant usage on schema api to api_access;
alter default privileges in schema api grant select on tables to api_access;
alter default privileges in schema api grant execute on functions to api_access;
-- Functions are executable by everyone by default; only api_access gets that.
alter default privileges revoke execute on functions from public;

-- Health check, used to prove the wiring end to end.
create view api.health as
select 'ok'::text            as status,
       now()                 as checked_at,
       (select count(*) from core.beds) as bed_count;

-- migrate:down
drop schema api cascade;
alter default privileges grant execute on functions to public;
grant usage on schema public to public;
drop role if exists api_user;
drop role if exists api_access;
