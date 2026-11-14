-- migrate:up
--------------------------------------------------------------------------------
-- 0005: what PostgREST needs from the database (decision D27).
--
-- PostgREST connects as api_user and, for each request, switches to the
-- api_access role and exposes the api schema. Before each request it calls
-- api_internal.pre_request(), which reads the request headers:
--   X-Tenant  tenant code (e.g. LIVE, DEMO) -> api.use_tenant
--   X-User    who is acting, until logins exist -> app.user (audit log)
-- Everything stays in SQL: PostgREST itself holds no logic.
--
-- api_internal is a separate schema so these helpers are not API endpoints.
-- Comments on api objects become the descriptions in the OpenAPI document.
--------------------------------------------------------------------------------
create schema api_internal authorization app_owner;
set local role app_owner;

grant usage on schema api_internal to api_access;

create function api_internal.pre_request()
returns void
language plpgsql security definer
set search_path = pg_catalog, core
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_tenant  text := nullif(v_headers ->> 'x-tenant', '');
  v_user    text := coalesce(nullif(v_headers ->> 'x-user', ''), 'anonymous');
begin
  perform set_config('app.user', v_user, true);
  if v_tenant is not null then
    perform api.use_tenant(v_tenant);       -- raises 'Unknown tenant: ...' if not found
  end if;
end
$$;
grant execute on function api_internal.pre_request() to api_access;

comment on view api.health is
  'Health check: status, time, the selected tenant and its bed count.';
comment on view api.tenants is
  'Tenants that can be selected with the X-Tenant header.';
comment on function api.use_tenant(text, boolean) is
  'Select a tenant for the current transaction. Normally done for you from the X-Tenant header.';
comment on function api.reset_demo_data() is
  'Wipe and reload the current tenant''s reference and sample data. Demo tenants only.';

reset role;

-- migrate:down
drop schema api_internal cascade;
comment on view api.health is null;
comment on view api.tenants is null;
comment on function api.use_tenant(text, boolean) is null;
comment on function api.reset_demo_data() is null;
