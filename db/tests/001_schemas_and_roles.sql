-- Schemas, roles and what api_user may and may not reach (decisions D17, I3).
begin;
create extension pgtap;
select plan(15);

select has_schema('core');
select has_schema('api');
select has_role('app_owner');
select has_role('api_access');
select has_role('api_user');

select is((select rolsuper or rolbypassrls from pg_roles where rolname = 'app_owner'), false,
          'app_owner is not a superuser and cannot bypass row-level security');
select is((select rolcanlogin from pg_roles where rolname = 'api_user'), true, 'api_user can log in');
select ok(pg_has_role('api_user', 'api_access', 'member'), 'api_user is a member of api_access');

select is((select count(*)::int from pg_tables where schemaname = 'core' and tableowner <> 'app_owner'), 0,
          'every core table is owned by app_owner');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'api' and pg_get_userbyid(c.relowner) <> 'app_owner'), 0,
          'every api view is owned by app_owner');

select throws_ok($$ set local role api_user; select count(*) from core.beds $$,
                 '42501', null, 'api_user cannot read core tables');
select throws_ok($$ set local role api_user; insert into core.tenants (code, name) values ('X', 'X') $$,
                 '42501', null, 'api_user cannot write core tables');
select throws_ok($$ set local role api_user; create table api.x (id int) $$,
                 '42501', null, 'api_user cannot create objects in api');
select throws_ok($$ set local role api_user; select * from public.schema_migrations $$,
                 '42501', null, 'api_user cannot read the public schema');

set local role api_user;
select status as health_status from api.health \gset
reset role;
select is(:'health_status'::text, 'ok'::text, 'api_user can read api.health');

select * from finish();
rollback;
