-- Course management (migration 0013, D35), on the DEMO sample data. w0 is the
-- Monday two weeks ago. SAF-14 runs w0+7 to w0+12 with 7 bookings on those
-- dates; TEC-07 (w0+14 to w0+26, 10 scheduled, 12 loaded) has 5; INT-22 has 4.
begin;
create extension pgtap;
select plan(25);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'tester', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select site_id as nc from core.sites where tenant_id = core.current_tenant_id() and code = 'NC' \gset
select course_id as saf from core.courses where tenant_id = core.current_tenant_id() and code = 'SAF-14' \gset
select course_id as tec from core.courses where tenant_id = core.current_tenant_id() and code = 'TEC-07' \gset
select course_id as int from core.courses where tenant_id = core.current_tenant_id() and code = 'INT-22' \gset

------------------------------ fn_create_course ------------------------------
select course_id as new from api.fn_create_course('  NEW-01 ', 'New course', :'w0'::date + 35, :'w0'::date + 40, 8, 0, :nc) \gset
select results_eq(format($$ select code, name, start_date, end_date, scheduled, loaded, loaded_at, status, site_id, allocated::int
                             from api.course_figures where course_id = %s $$, :new),
                  format($$ values ('NEW-01', 'New course', %L::date, %L::date, 8, 0, null::timestamp, 'REQUESTED', %s, 0) $$,
                         (:'w0'::date + 35), (:'w0'::date + 40), :nc),
                  'a new course appears in course_figures, trimmed, REQUESTED, with no loaded_at while loaded is 0');
select is((select changed_by from core.audit_log where table_name = 'courses' and record_id = :new and action = 'INSERT'),
          'tester', 'creating a course is audited with the user');
-- (Read back in a second statement: one statement can't see rows its own function call inserted.)
select course_id as new2 from api.fn_create_course('NEW-02', 'Loaded course', :'w0', :'w0'::date + 1, 4, 3) \gset
select is((select loaded_at is not null from core.courses where course_id = :new2),
          true, 'loaded_at is set when the course is created with a loaded figure');

select throws_ok(format($$ select * from api.fn_create_course('new-01', 'Again', %L, %L) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'A course with code NEW-01 already exists', 'a duplicate code is refused, whatever the case');
select throws_ok(format($$ select * from api.fn_create_course('NEW-03', 'Bad dates', %L, %L) $$, :'w0', :'w0'),
                 'P0001', 'The end date must be after the start date', 'the end must be after the start');
select throws_ok(format($$ select * from api.fn_create_course('NEW-03', 'Negative', %L, %L, -1) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'scheduled and loaded must not be negative', 'negative figures are refused');
select throws_ok(format($$ select * from api.fn_create_course('NEW-03', 'No site', %L, %L, 1, 0, -1) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown site', 'an unknown site is refused');
select throws_ok(format($$ select * from api.fn_create_course('NEW-03', '  ', %L, %L) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'A course name is needed', 'a blank name is refused');
select throws_ok(format($$ select * from api.fn_create_course('NEW-03', 'Cancelled', %L, %L, 0, 0, null, 'CANCELLED') $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Status must be REQUESTED or CONFIRMED (cancel with fn_cancel_course)', 'a course can''t be created cancelled');

------------------------------ fn_update_course ------------------------------
select results_eq(format($$ select course_id, warnings from api.fn_update_course(%s, p_name => 'Technical Refresher 2') $$, :tec),
                  format($$ values (%s, '{}'::text[]) $$, :tec), 'renaming returns no warnings');
select is((select name::text from core.courses where course_id = :tec), 'Technical Refresher 2', 'the name is changed');
select is((select detail::jsonb -> 'to' ->> 'name' from core.audit_log
            where table_name = 'courses' and record_id = :tec and action = 'UPDATE' order by audit_id desc limit 1),
          'Technical Refresher 2', 'an update is audited with the old and new values');
select throws_ok(format($$ select * from api.fn_update_course(%s) $$, :tec),
                 'P0001', 'Nothing to change', 'an update that changes nothing is refused');

insert into core.sites (code, name, sort_order) values ('XX', 'Other site', 9) returning site_id as xsite \gset
select is((select warnings from api.fn_update_course(:tec, p_site_id => :xsite)),
          array['5 bookings are on another site'], 'moving a course to another site warns about its bookings');
select results_eq(format($$ select course_id, warnings from api.fn_update_course(%s, p_clear_site => true) $$, :tec),
                  format($$ values (%s, '{}'::text[]) $$, :tec), 'p_clear_site removes the site without warnings');
select is((select site_id from core.courses where course_id = :tec), null, 'the course has no site');

select is((select warnings from api.fn_update_course(:saf, p_end_date => :'w0'::date + 10)),
          array['7 bookings are now outside the course dates'], 'shortening a course warns about the bookings left outside');
select is((select count(*)::int from api.warnings where kind = 'OUTSIDE_COURSE_DATES' and course_id = :saf), 7,
          'and api.warnings lists them');

------------------------------ fn_update_loaded ------------------------------
select results_eq(format($$ select loaded, loaded_at is not null, loaded_above_scheduled from api.fn_update_loaded(%s, 15) $$, :tec),
                  $$ values (15, true, true) $$, 'updating loaded stamps the time and compares with scheduled');
select throws_ok(format($$ select * from api.fn_update_loaded(%s, -1) $$, :tec),
                 'P0001', 'loaded must not be negative', 'a negative loaded figure is refused');

------------------------------ fn_cancel_course ------------------------------
select results_eq(format($$ select allocations_cancelled from api.fn_cancel_course(%s) $$, :int),
                  $$ values (4) $$, 'cancelling a course cancels its live allocations');
select is((select status::text || '/' || (select count(*) filter (where a.status <> 'CANCELLED') from core.allocations a where a.course_id = :int)::text
             || '/' || (select count(*) from core.audit_log l where l.table_name = 'allocations' and l.course_id = :int
                         and l.action = 'CANCEL' and l.detail like '%course cancelled%')::text
            from core.courses where course_id = :int),
          'CANCELLED/0/4', 'the course and its allocations are CANCELLED, each allocation audited');
select throws_ok(format($$ select * from api.fn_update_course(%s, p_name => 'x') $$, :int),
                 'P0001', 'The course is cancelled', 'a cancelled course can''t be edited');
select count(*) from api.fn_update_course(:int, p_status => 'CONFIRMED');
select results_eq(format($$ select status::text, allocated::int from api.course_figures where course_id = %s $$, :int),
                  $$ values ('CONFIRMED', 0) $$, 'reinstating a course restores the course, not its bookings');

------------------------------ tenants ------------------------------
select api.use_tenant('LIVE');
select throws_ok(format($$ select * from api.fn_update_course(%s, p_name => 'x') $$, :tec),
                 'P0001', 'Unknown course', 'LIVE can''t change a DEMO course');

select * from finish();
rollback;
