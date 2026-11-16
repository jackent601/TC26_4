-- Demand above beds in service (migration 0021, D40), on the DEMO sample data.
-- w0 is the Monday two weeks ago. North Camp has 23 beds; nothing is booked or
-- out of action from w0+35, so a new course there shows each case on its own.
begin;
create extension pgtap;
select plan(10);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'tester', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select site_id as nc from core.sites where tenant_id = core.current_tenant_id() and code = 'NC' \gset
select room_id as room101 from core.rooms where tenant_id = core.current_tenant_id() and code = '101' \gset
select b.bed_id as r102a from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = '102' and b.code = 'a' \gset
select to_char(:'w0'::date + 35, 'DD/MM') as d35, to_char(:'w0'::date + 37, 'DD/MM') as d37 \gset

select is((select count(*)::int from api.warnings where kind like '%OVER_CAPACITY'), 0,
          'the sample data never has more demand than beds');

-- A course for 25 at North Camp, w0+35 to w0+41 (6 nights), nothing loaded yet.
select course_id as big from api.fn_create_course('BIG-01', 'Big course', :'w0'::date + 35, :'w0'::date + 41, 25, 0, :nc) \gset
select results_eq($$ select kind, severity, message, start_date, end_date, site_id, course_id, allocation_id
                     from api.warnings where kind like '%OVER_CAPACITY' $$,
                  format($$ values ('SCHEDULED_OVER_CAPACITY', 'WARNING',
                                    'North Camp: scheduled places and external bookings exceed beds in service on 6 nights from %s (up to 25 for 23 beds)',
                                    %L::date, %L::date, %s, null::integer, null::integer) $$,
                         :'d35', (:'w0'::date + 35), (:'w0'::date + 41), :nc),
                  'scheduled places above beds in service: one warning for the run of nights, at the site');

select count(*) from api.fn_update_loaded(:big, 24);
select is((select message from api.warnings where kind = 'LOADED_OVER_CAPACITY'),
          format('North Camp: loaded places and external bookings exceed beds in service on 6 nights from %s (up to 24 for 23 beds)', :'d35'),
          'loaded places above beds in service warn separately');

-- Room 101 out of action (2 beds) w0+37 to w0+39, an external booking w0+38 to w0+40.
select count(*) from api.fn_add_outage('Room', :room101, :'w0'::date + 37, :'w0'::date + 39, 'Leak');
select count(*) from api.fn_book_external('BK-9100', 'Visitor', array[:r102a], :'w0'::date + 38, :'w0'::date + 40);
select is((select message from api.warnings where kind = 'SCHEDULED_OVER_CAPACITY'),
          format('North Camp: scheduled places and external bookings exceed beds in service on 6 nights from %s (up to 26 for 21 beds)', :'d35'),
          'outages lower the beds in service and external bookings add to demand; the worst night is reported');

-- Loaded 22: above the beds in service only on w0+37 and w0+38.
select count(*) from api.fn_update_loaded(:big, 22);
select results_eq($$ select message, start_date, end_date from api.warnings where kind = 'LOADED_OVER_CAPACITY' $$,
                  format($$ values ('North Camp: loaded places and external bookings exceed beds in service on 2 nights from %s (up to 23 for 21 beds)',
                                    %L::date, %L::date) $$, :'d37', (:'w0'::date + 37), (:'w0'::date + 39)),
                  'only the nights over count; end_date is the day after the last');

-- Two separate runs give two warnings.
select count(*) from api.fn_add_outage('Room', :room101, :'w0'::date + 40, :'w0'::date + 41, 'Leak again');
select is((select count(*)::int from api.warnings where kind = 'LOADED_OVER_CAPACITY'), 2, 'separate runs of nights warn separately');

-- A course with no site isn't compared with any site's beds.
select count(*) from api.fn_create_course('ANY-01', 'Anywhere', :'w0'::date + 42, :'w0'::date + 48, 50, 50);
select is((select count(*)::int from api.warnings where kind like '%OVER_CAPACITY' and start_date >= :'w0'::date + 42), 0,
          'a course with no site gives no capacity warning');

-- A cancelled course no longer counts.
select count(*) from api.fn_cancel_course(:big);
select is((select count(*)::int from api.warnings where kind like '%OVER_CAPACITY'), 0, 'a cancelled course no longer counts');

-- The api_user role can read them (the view's helper is not an endpoint).
select count(*) from api.fn_update_course(:big, p_status => 'CONFIRMED');
set local role api_user;
select count(*)::int as as_api from api.warnings where kind = 'SCHEDULED_OVER_CAPACITY' \gset
reset role;
select is(:as_api, 1, 'api_user reads them through api.warnings');

select api.use_tenant('LIVE');
select is((select count(*)::int from api.warnings where kind like '%OVER_CAPACITY'), 0, 'LIVE sees none of DEMO''s');

select * from finish();
rollback;
