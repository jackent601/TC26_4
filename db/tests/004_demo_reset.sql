-- Demo data and api.reset_demo_data (decision D25, migration 0004).
begin;
create extension pgtap;
select plan(9);

select throws_ok($$ select * from api.reset_demo_data() $$,
                 'P0001', 'No tenant selected: call api.use_tenant first', 'reset needs a tenant');
select throws_ok($$ select api.use_tenant('LIVE'); select * from api.reset_demo_data() $$,
                 'P0001', 'Reset is only allowed for a demo tenant', 'reset refuses a live tenant');

select api.use_tenant('DEMO');
select results_eq($$ select beds, courses, allocations, outages from api.reset_demo_data() $$,
                  $$ values (23::bigint, 5::bigint, 26::bigint, 2::bigint) $$,
                  'reset loads the sample data');
select results_eq($$ select beds, courses, allocations, outages from api.reset_demo_data() $$,
                  $$ values (23::bigint, 5::bigint, 26::bigint, 2::bigint) $$,
                  'reset can be repeated');

select is((select count(*)::int from core.attribute_types a join core.tenants t using (tenant_id)
            where t.code = 'LIVE'), 6, 'a demo reset leaves LIVE untouched');

select is((select count(*)::int from core.allocations a join core.tenants t using (tenant_id)
            where t.code = 'DEMO' and a.end_date <= current_date
              and a.status not in ('CHECKED_OUT', 'NO_SHOW')), 0,
          'past demo stays are checked out (or no-show)');
select is((select count(*)::int from core.allocations a join core.tenants t using (tenant_id)
            where t.code = 'DEMO' and a.start_date > current_date
              and a.status not in ('ALLOCATED', 'BOOKED')), 0,
          'future demo stays are not checked in yet');
select is((select min(start_date) from core.courses c join core.tenants t using (tenant_id) where t.code = 'DEMO'),
          date_trunc('week', current_date - 14)::date,
          'demo data starts on the Monday two weeks ago');

set local role api_user;
select api.use_tenant('DEMO');
select allocations as api_allocs from api.reset_demo_data() \gset
reset role;
select is(:api_allocs::int, 26, 'api_user can reset the demo tenant');

select * from finish();
rollback;
