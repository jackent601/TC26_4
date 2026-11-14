-- PostgREST request hook (migration 0005, decision D27).
begin;
create extension pgtap;
select plan(8);

select has_function('api_internal', 'pre_request', 'pre-request hook exists');
select hasnt_function('api', 'pre_request', 'the hook is not an API endpoint');
select ok(has_function_privilege('api_access', 'api_internal.pre_request()', 'execute'),
          'api_access may run the hook');

-- Simulate what PostgREST does: headers in request.headers, then the hook.
select set_config('request.headers', '{"x-tenant": "DEMO", "x-user": "jason"}', true);
select api_internal.pre_request();
select is(current_setting('app.user'), 'jason', 'X-User becomes app.user');
select is((select tenant from api.health), 'DEMO', 'X-Tenant selects the tenant');

select set_config('request.headers', '{}', true);
select set_config('app.tenant_id', '', true);
select api_internal.pre_request();
select is(current_setting('app.user'), 'anonymous', 'no X-User: anonymous');
select is((select tenant from api.health), null, 'no X-Tenant: no tenant selected');

select set_config('request.headers', '{"x-tenant": "NOPE"}', true);
select throws_ok($$ select api_internal.pre_request() $$, 'P0001', 'Unknown tenant: NOPE',
                 'an unknown X-Tenant is rejected');

select * from finish();
rollback;
