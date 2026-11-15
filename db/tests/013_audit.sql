-- The audit trail as users see it (migration 0015, D37): api.audit summaries,
-- api.audit_requests roll-ups and the request id from the pre-request hook. On
-- the DEMO sample data; w0 is the Monday two weeks ago. FIN-03 runs w0+28 to
-- w0+33 with nothing booked; INT-22 has 4 bookings.
begin;
create extension pgtap;
select plan(17);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'Phil', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select to_char(:'w0'::date + 28, 'DD/MM') as d28, to_char(:'w0'::date + 29, 'DD/MM') as d29,
       to_char(:'w0'::date + 33, 'DD/MM') as d33, to_char(:'w0'::date + 35, 'DD/MM') as d35,
       to_char(:'w0'::date + 40, 'DD/MM') as d40 \gset
select course_id as fin from core.courses where tenant_id = core.current_tenant_id() and code = 'FIN-03' \gset
select course_id as int from core.courses where tenant_id = core.current_tenant_id() and code = 'INT-22' \gset
create temporary table bed_ids as
  select r.code || b.code as k, b.bed_id from core.beds b join core.rooms r using (room_id)
   where r.tenant_id = core.current_tenant_id();
select (select bed_id from bed_ids where k = '101a') as r101a, (select bed_id from bed_ids where k = '101b') as r101b,
       (select bed_id from bed_ids where k = '102a') as r102a, (select bed_id from bed_ids where k = 'B101b') as b101b \gset

------------------------------ bookings ------------------------------
-- One request books two beds.
select set_config('app.request_id', '11111111-1111-1111-1111-111111111111', true);
select min(allocation_id) as a1 from api.fn_allocate_course(:fin, array[:r101a, :r101b], :'w0'::date + 28, :'w0'::date + 33) \gset
select results_eq($$ select summary from api.audit where request_id = '11111111-1111-1111-1111-111111111111' order by audit_id $$,
                  format($$ values ('booked FIN-03 into Room 101 bed A, %s to %s'), ('booked FIN-03 into Room 101 bed B, %s to %s') $$,
                         :'d28', :'d33', :'d28', :'d33'),
                  'each booking reads as a sentence naming the course, bed and nights');
select results_eq($$ select changed_by, changes, summary from api.audit_requests where request_key = '11111111-1111-1111-1111-111111111111' $$,
                  format($$ values ('Phil', 2, 'booked 2 beds for FIN-03, %s to %s') $$, :'d28', :'d33'),
                  'the rows of one request roll up into one line');

select set_config('app.request_id', '22222222-2222-2222-2222-222222222222', true);
select count(*) from api.fn_move_allocation(:a1, :r102a);
select is((select summary from api.audit where allocation_id = :a1 and action = 'MOVE' order by audit_id desc limit 1),
          'moved FIN-03 from Room 101 bed A to Room 102 bed A', 'a move to another bed names both beds');
select count(*) from api.fn_move_allocation(:a1, null, :'w0'::date + 29, :'w0'::date + 33);
select is((select summary from api.audit where allocation_id = :a1 and action = 'MOVE' order by audit_id desc limit 1),
          format('changed FIN-03''s dates in Room 102 bed A to %s to %s', :'d29', :'d33'), 'a change of dates says the new dates');
select count(*) from api.fn_set_status(:a1, 'CHECKED_IN');
select is((select summary from api.audit where allocation_id = :a1 and action = 'STATUS'),
          'set FIN-03''s booking in Room 102 bed A to Checked in', 'a status change reads in plain words');
select count(*) from api.fn_cancel_allocation(:a1);
select is((select summary from api.audit where allocation_id = :a1 and action = 'CANCEL'),
          'cancelled FIN-03''s booking in Room 102 bed A', 'a cancellation names the bed it was in');
select is((select count(*)::int from api.audit where allocation_id = :a1), 5,
          'a booking''s history is every row about it');

-- Saved with warnings (Block B floor out of action, and outside FIN-03's dates).
select count(*) from api.fn_allocate_course(:fin, array[:b101b], :'w0'::date + 22, :'w0'::date + 25);
select results_eq(format($$ select cardinality(warnings), summary like '%%(2 warnings)'
                             from api.audit where bed_id = %s and action = 'INSERT' $$, :b101b),
                  $$ values (2, true) $$, 'warnings the change was saved with are listed and counted in the summary');

------------------------------ courses ------------------------------
select course_id as new from api.fn_create_course('NEW-01', 'New course', :'w0'::date + 35, :'w0'::date + 40, 8) \gset
select is((select summary from api.audit where course_id = :new and action = 'INSERT'),
          format('added course NEW-01: New course, %s to %s, 8 scheduled', :'d35', :'d40'), 'adding a course reads as a sentence');
select count(*) from api.fn_update_course(:new, p_name => 'Renamed', p_scheduled => 9);
select is((select summary from api.audit where course_id = :new and action = 'UPDATE'),
          'changed NEW-01: name to Renamed, scheduled to 9', 'a course change lists what changed');
select count(*) from api.fn_update_loaded(:new, 3);
select is((select summary from api.audit where course_id = :new and action = 'LOADED'),
          'set NEW-01 loaded to 3 (was 0)', 'updating loaded says the old and new figures');

select set_config('app.request_id', '33333333-3333-3333-3333-333333333333', true);
select count(*) from api.fn_cancel_course(:int);
select results_eq($$ select changes, summary from api.audit_requests where request_key = '33333333-3333-3333-3333-333333333333' $$,
                  $$ values (5, 'cancelled course INT-22 and 4 bookings') $$,
                  'cancelling a course rolls its bookings into the course''s line');

select is((select count(*)::int from api.audit where course_id = :fin), 7,
          'a course''s history includes its bookings'' rows');

------------------------------ request id and roles ------------------------------
select set_config('request.headers', '{"x-tenant": "DEMO", "x-user": "Hook"}', true);
select api_internal.pre_request();
select is(length(current_setting('app.request_id', true)), 36, 'the pre-request hook gives each request an id');
select is(has_table_privilege('api_user', 'api.audit', 'select') and has_table_privilege('api_user', 'api.audit_requests', 'select'),
          true, 'api_user can read the audit trail');
-- As the API role: the views' wording functions must be executable too. (pgTAP
-- lives in public, which api_user can't use, so read first and assert after.)
set local role api_user;
select api.use_tenant('DEMO');
select count(*) as rows_as_api_user from api.audit \gset
select count(*) as requests_as_api_user from api.audit_requests \gset
reset role;
select is(:rows_as_api_user > 0 and :requests_as_api_user > 0, true,
          'the audit views work for the API role, wording helpers included');

select api.use_tenant('LIVE');
select is((select count(*)::int from api.audit), 0, 'LIVE sees none of DEMO''s history');

select * from finish();
rollback;
