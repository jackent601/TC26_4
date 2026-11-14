-- Tenant isolation (decision D24).
begin;
create extension pgtap;
select plan(10);

select results_eq($$ select code::text, is_demo::text from core.tenants order by code $$,
                  $$ values ('DEMO', 'Y'), ('LIVE', 'N') $$,
                  'LIVE and DEMO tenants exist');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'core' and c.relkind = 'r' and c.relname <> 'tenants'
              and not (c.relrowsecurity and c.relforcerowsecurity)), 0,
          'row-level security is enabled and forced on every tenant table');
select is((select count(*)::int from information_schema.columns c
             join information_schema.tables t using (table_schema, table_name)
            where c.table_schema = 'core' and c.column_name = 'tenant_id' and c.table_name <> 'tenants'
              and t.table_type = 'BASE TABLE'), 14,
          'every table except tenants has tenant_id');

-- Give DEMO some data.
select api.use_tenant('DEMO');
select * from api.reset_demo_data();

-- What api_user sees per tenant.
set local role api_user;
select api.use_tenant('DEMO');
select bed_count as demo_beds from api.health \gset
select api.use_tenant('LIVE');
select bed_count as live_beds from api.health \gset
select set_config('app.tenant_id', '', true);
select bed_count as none_beds from api.health \gset
reset role;

select is(:demo_beds::int, 23, 'DEMO sees its 23 beds');
select is(:live_beds::int, 0, 'LIVE sees none of DEMO''s beds');
select is(:none_beds::int, 0, 'with no tenant selected nothing is visible');

select throws_ok($$ select api.use_tenant('NOPE') $$, 'P0001', 'Unknown tenant: NOPE',
                 'an unknown tenant is rejected');

-- Run as the superuser (which bypasses row-level security), so this tests the composite foreign key.
select throws_ok($$ insert into core.buildings (tenant_id, site_id, code, name)
                    select (select tenant_id from core.tenants where code = 'LIVE'), site_id, 'X', 'X'
                    from core.sites limit 1 $$,
                 '23503', null, 'a LIVE row cannot reference a DEMO row');

select throws_ok($$ set local role app_owner;
                    select api.use_tenant('LIVE');
                    insert into core.sites (tenant_id, code, name)
                    values ((select tenant_id from core.tenants where code = 'DEMO'), 'X', 'X') $$,
                 '42501', null, 'a row cannot be written for another tenant');

-- Insert as app_owner without naming the tenant (an error here fails the file).
set local role app_owner;
select api.use_tenant('LIVE');
insert into core.sites (code, name) values ('T1', 'Test site');
reset role;
select is((select t.code::text from core.sites s join core.tenants t using (tenant_id) where s.code = 'T1'), 'LIVE',
          'tenant_id defaults to the current tenant');

select * from finish();
rollback;
