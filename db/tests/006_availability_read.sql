-- Read API for the availability page (migrations 0006-0008), on the DEMO sample data.
-- Assertions run as the test superuser (pgTAP lives in public, which api_user
-- can't use). Row-level security still applies: api views run as their owner
-- and api functions are security definer, both app_owner. One check at the end
-- calls every endpoint as api_user, as PostgREST does.
-- Demo dates are relative to day 0 (w0), the Monday two weeks ago.
begin;
create extension pgtap;
select plan(36);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();

select date_trunc('week', current_date - 14)::date as w0 \gset
select b.bed_id as b101a from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = 'B101' and b.code = 'a' \gset
select b.bed_id as b101b from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = 'B101' and b.code = 'b' \gset
select b.bed_id as r101a from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = '101' and b.code = 'a' \gset
select f.floor_id as a3 from core.floors f join core.blocks bl using (block_id)
 where bl.tenant_id = core.current_tenant_id() and bl.code = 'A' and f.code = '3' \gset
select f.floor_id as b1 from core.floors f join core.blocks bl using (block_id)
 where bl.tenant_id = core.current_tenant_id() and bl.code = 'B' and f.code = '1' \gset
select site_id as site from core.sites where tenant_id = core.current_tenant_id() \gset
select course_id as tec from core.courses where tenant_id = core.current_tenant_id() and code = 'TEC-07' \gset
select course_id as saf from core.courses where tenant_id = core.current_tenant_id() and code = 'SAF-14' \gset

-- Helpers are not endpoints.
select hasnt_view('api', 'v_bed_path', 'v_bed_path is not in api');
select hasnt_view('api', 'v_bed_outages', 'v_bed_outages is not in api');

-------------------------------- locations ---------------------------------
select results_eq($$ select level, count(*)::int from api.locations group by level order by level $$,
                  $$ values ('Bed', 23), ('Block', 2), ('Building', 1), ('Floor', 4), ('Room', 13), ('Site', 1) $$,
                  'locations: 1 site, 1 building, 2 blocks, 4 floors, 13 rooms, 23 beds');
select is((select bed_count from api.locations where level = 'Site'), 23::bigint, 'the site counts all 23 beds');
select is((select count(*)::int from api.locations l where l.parent_key is not null
            and not exists (select 1 from api.locations p where p.key = l.parent_key)), 0,
          'every parent_key points to a location');
select results_eq($$ select name, sort_order from api.locations where level = 'Block' order by sort_order $$,
                  $$ values ('Block A', 1), ('Block B', 2) $$, 'locations carry sort_order');
select results_eq($$ select l.name, l.sort_order from api.locations l
                      join api.locations r on r.key = l.parent_key
                     where r.name = 'Room 101' order by l.sort_order $$,
                  $$ values ('Bed A', 1), ('Bed B', 2) $$, 'beds are numbered within their room');

------------------------------ course_figures ------------------------------
select results_eq($$ select code, scheduled, loaded, allocated::int, loaded_above_scheduled
                       from api.course_figures order by code $$,
                  $$ values ('FIN-03', 6, 2, 0, false), ('INT-22', 4, 3, 4, false),
                            ('LDR-01', 6, 6, 6, false), ('SAF-14', 8, 7, 7, false),
                            ('TEC-07', 10, 12, 5, true) $$,
                  'course figures match the mockup');
select results_eq($$ select code, pct_scheduled, pct_loaded from api.course_figures order by code $$,
                  $$ values ('FIN-03', 0.0, 0.0), ('INT-22', 100.0, 133.3), ('LDR-01', 100.0, 100.0),
                            ('SAF-14', 87.5, 100.0), ('TEC-07', 50.0, 41.7) $$,
                  'allocation percentages of scheduled and loaded (0007)');

------------------------------- fn_bed_bars --------------------------------
select results_eq(format($$ select kind, count(*)::int from api.fn_bed_bars(%L, %L) group by kind order by kind $$,
                         :'w0', (:'w0'::date + 35)),
                  $$ values ('allocation', 22), ('external', 5), ('outage', 6) $$,
                  'five weeks: 22 allocations, 5 external bookings, 6 outage bars');
select results_eq(format($$ select external_ref from api.fn_bed_bars(%L, %L) where on_outage $$,
                         :'w0', (:'w0'::date + 35)),
                  $$ values ('BK-4530') $$, 'only BK-4530 is on an outage');
select results_eq(format($$ select external_ref, start_date, end_date from api.fn_bed_bars(%L, %L)
                             where external_ref = 'BK-4471' $$,
                         (:'w0'::date + 7), (:'w0'::date + 14)),
                  format($$ values ('BK-4471', %L::date, %L::date) $$, (:'w0'::date + 2), (:'w0'::date + 9)),
                  'bars keep their full dates when they run past the range (0008)');
select results_eq(format($$ select set_on_level, reason from api.fn_bed_bars(%L, %L)
                             where kind = 'outage' and bed_id = %s $$,
                         :'w0', (:'w0'::date + 35), :b101a),
                  $$ values ('Floor', 'Fire alarm upgrade') $$, 'floor outages appear on each bed below');
select throws_ok(format($$ select * from api.fn_bed_bars(%L, %L) $$, :'w0', :'w0'),
                 'P0001', 'p_to must be after p_from', 'fn_bed_bars needs p_to after p_from');

---------------------- fn_week_summary (0007, D29) -------------------------
-- Facts only: beds by category on each week's busiest night, per course.
select hasnt_function('api', 'fn_week_summary', array['date', 'integer', 'text', 'numeric', 'numeric'],
                      'fn_week_summary no longer takes a basis or thresholds');
select results_eq(format($$ select category, course_id, beds::int from api.fn_week_summary(%L, 5)
                             where key = 'floor:%s' and week_start = %L $$,
                         :'w0', :b1, (:'w0'::date + 21)),
                  $$ values ('out_of_action', null::int, 4) $$,
                  'Block B Floor 1 is all out of action in the outage week');
select results_eq(format($$ select category, course_id, beds::int from api.fn_week_summary(%L, 5)
                             where key = 'floor:%s' and week_start = %L $$,
                         :'w0', :a3, (:'w0'::date + 14)),
                  format($$ values ('course', %s, 5) $$, :tec),
                  'Floor 3 has 5 TEC-07 beds while it runs');
select results_eq(format($$ select category, course_id, beds::int from api.fn_week_summary(%L, 5)
                             where key = 'site:%s' and week_start = %L order by category, course_id $$,
                         :'w0', :site, (:'w0'::date + 7)),
                  format($$ values ('course', %s, 7), ('external', null::int, 2), ('free', null::int, 14) $$, :saf),
                  'the site in week 2: 7 SAF-14 beds, 2 external, 14 free');
select is((select distinct busiest_night from api.fn_week_summary(:'w0', 5)
            where key = 'site:' || :site and week_start = :'w0'::date + 7),
          :'w0'::date + 7,
          'busiest night: fewest free beds, earliest on a tie (night 7: SAF-14 + BK-4471 + BK-4519; night 10: SAF-14 + Room 203 outage)');
select is((select count(*)::int from (select s.key, s.week_start, sum(s.beds) as beds
                                        from api.fn_week_summary(:'w0', 5) s group by s.key, s.week_start) x
            join api.locations l on l.key = x.key where x.beds <> l.bed_count), 0,
          'each location''s categories add up to its bed count');
select is((select count(*)::int from (select distinct key, week_start from api.fn_week_summary(:'w0', 5)) x), 21 * 5,
          'every location above bed level appears in every week');
select throws_ok(format($$ select * from api.fn_week_summary(%L, 0) $$, :'w0'),
                 'P0001', 'p_weeks must be between 1 and 52', 'fn_week_summary rejects 0 weeks');

--------------------------------- warnings ---------------------------------
-- One of each kind (0020 added the double booking and the early arrival).
select to_char(:'w0'::date + 21, 'DD/MM') as d21, to_char(:'w0'::date + 27, 'DD/MM') as d27 \gset
select results_eq($$ select kind, message from api.warnings order by kind collate "C", message collate "C" $$,
                  format($$ values ('DOUBLE_BOOKING', 'BK-4561 is double-booked (Room 302 bed B)'),
                                   ('DOUBLE_BOOKING', 'TEC-07 is double-booked (Room 302 bed B)'),
                                   ('LOADED_ABOVE_SCHEDULED', 'TEC-07: 12 loaded vs 10 scheduled'),
                                   ('OUTSIDE_COURSE_DATES', 'INT-22 booking in Room 102 bed B is outside the course dates (%s to %s)'),
                                   ('OUT_OF_ACTION', 'BK-4530 is in an out-of-action bed (Room B101 bed A)') $$, :'d21', :'d27'),
                  'warnings on the sample data: one of each kind');

---------------------------- fn_check_allocation ---------------------------
select results_eq(format($$ select kind, ref from api.fn_check_allocation(array[%s, %s], %L, %L)
                             order by kind, bed_id $$,
                         :b101a, :b101b, (:'w0'::date + 21), (:'w0'::date + 28)),
                  $$ values ('BOOKING', 'BK-4530'), ('OUT_OF_ACTION', 'Fire alarm upgrade'),
                            ('OUT_OF_ACTION', 'Fire alarm upgrade') $$,
                  'clash check for Room B101 in the outage week');
select is((select count(*)::int from api.fn_check_allocation(array[:r101a], :'w0'::date + 14, :'w0'::date + 21)), 0,
          'no clashes on a free bed');
select throws_ok(format($$ select * from api.fn_check_allocation(array[%s], %L, %L) $$,
                        :r101a, :'w0', (:'w0'::date - 1)),
                 'P0001', 'p_to must be after p_from', 'fn_check_allocation needs p_to after p_from');

-------------------------------- as api_user -------------------------------
set local role api_user;
select (select count(*) from api.locations) || '/' || (select count(*) from api.course_figures) || '/'
    || (select count(*) from api.warnings) || '/'
    || (select count(*) from api.fn_bed_bars(:'w0', :'w0'::date + 35)) || '/'
    || (select count(*) from (select distinct key, week_start from api.fn_week_summary(:'w0', 5)) s) || '/'
    || (select count(*) from api.fn_check_allocation(array[:b101a], :'w0'::date + 21, :'w0'::date + 28))
    as as_api_user \gset
reset role;
select is(:'as_api_user'::text, '44/5/5/33/105/2'::text,
          'api_user can read every endpoint (locations/figures/warnings/bars/summary/clashes)');

------------------------------- double booking -----------------------------
insert into core.allocations (course_id, individual_no, bed_id, start_date, end_date)
select course_id, 9, :r101a, :'w0'::date + 22, :'w0'::date + 24 from core.courses
 where tenant_id = core.current_tenant_id() and code = 'TEC-07';
select results_eq($$ select message from api.warnings where kind = 'DOUBLE_BOOKING' and message like '%Room 101%' order by message $$,
                  $$ values ('INT-22 is double-booked (Room 101 bed A)'),
                            ('TEC-07 is double-booked (Room 101 bed A)') $$,
                  'a double booking warns on both bookings');
select is((select count(*)::int from api.fn_check_allocation(array[:r101a], :'w0'::date + 21, :'w0'::date + 28)), 2,
          'the clash check lists both bookings on a double-booked bed');

------------------------- percentages with no basis ------------------------
insert into core.courses (code, name, start_date, end_date, scheduled, loaded)
values ('ZERO-01', 'Nothing planned yet', :'w0'::date + 28, :'w0'::date + 30, 0, 0);
select results_eq($$ select pct_scheduled, pct_loaded from api.course_figures where code = 'ZERO-01' $$,
                  $$ values (null::numeric, null::numeric) $$,
                  'percentages are null when scheduled or loaded is 0');

---------------------------- tenant isolation ------------------------------
select api.use_tenant('LIVE');
select is((select count(*)::int from api.locations), 0, 'LIVE sees no locations');
select is((select count(*)::int from api.course_figures), 0, 'LIVE sees no course figures');
select is((select count(*)::int from api.fn_bed_bars(:'w0', :'w0'::date + 35)), 0, 'LIVE sees no bars');
select is((select count(*)::int from api.fn_week_summary(:'w0', 5)), 0, 'LIVE sees no week summary');
select is((select count(*)::int from api.warnings), 0, 'LIVE sees no warnings');
select is((select count(*)::int from api.fn_check_allocation(array[:b101a], :'w0'::date + 21, :'w0'::date + 28)), 0,
          'LIVE sees no clashes on DEMO beds');

select * from finish();
rollback;
