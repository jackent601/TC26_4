-- The Overview page's read API (migration 0011), on the DEMO sample data.
-- w0 is the Monday two weeks ago; weeks are w0, w0+7, ... Expected figures:
--   week 2 (w0+7):  busiest night w0+7 (SAF-14 + BK-4471 + BK-4519)
--   week 3 (w0+14): busiest night w0+16 (Room 203 out; TEC-07; BK-4502 starts)
--   week 4 (w0+21): busiest night w0+21 (Block B Floor 1 out; TEC-07 + INT-22; BK-4502)
--   week 5 (w0+28): FIN-03 runs with nothing allocated
begin;
create extension pgtap;
select plan(10);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select date_trunc('week', current_date - 14)::date as w0 \gset
select site_id as site from core.sites where tenant_id = core.current_tenant_id() \gset

select results_eq(format($$ select week_start, busiest_night, beds_available::int, allocated::int, external::int,
                                   free::int, scheduled::int, loaded::int, courses::int
                              from api.fn_weekly_overview(%L, 5) where week_start > %L order by 1 $$, :'w0', :'w0'),
                  format($$ values (%L::date, %L::date, 23, 7, 2, 14, 8, 7, 1),
                                   (%L::date, %L::date, 21, 5, 1, 15, 10, 12, 1),
                                   (%L::date, %L::date, 19, 9, 1, 9, 14, 15, 2),
                                   (%L::date, %L::date, 23, 0, 0, 23, 6, 2, 1) $$,
                         (:'w0'::date + 7), (:'w0'::date + 7), (:'w0'::date + 14), (:'w0'::date + 16),
                         (:'w0'::date + 21), (:'w0'::date + 21), (:'w0'::date + 28), (:'w0'::date + 28)),
                  'weekly overview on the sample data (weeks 2-5)');
select is((select count(*)::int from api.fn_weekly_overview(:'w0', 5)), 5, 'one row per week');
select is((select bool_and(beds_available = allocated + external + free) from api.fn_weekly_overview(:'w0', 5)), true,
          'beds in service split exactly into allocated, external and free');
select is((select array_agg(beds_available order by week_start) from api.fn_weekly_overview(:'w0', 5, array[:site])),
          (select array_agg(beds_available order by week_start) from api.fn_weekly_overview(:'w0', 5)),
          'filtering by the only site gives the same figures');
select results_eq(format($$ select sum(beds_available)::int, sum(scheduled)::int, sum(courses)::int, count(busiest_night)::int
                              from api.fn_weekly_overview(%L, 5, array[-1]) $$, :'w0'),
                  $$ values (0, 0, 0, 0) $$, 'a site with nothing gives empty weeks, still one row each');
select throws_ok(format($$ select * from api.fn_weekly_overview(%L, 0) $$, :'w0'),
                 'P0001', 'p_weeks must be between 1 and 52', 'fn_weekly_overview rejects 0 weeks');

select is((select count(*)::int from api.course_figures where site_id is distinct from :site), 0,
          'course_figures has each course''s site');
select is((select count(*)::int from api.warnings where site_id is distinct from :site), 0,
          'every warning has a site (the bed''s, or the course''s)');
select is((select count(*)::int from api.warnings where kind = 'LOADED_ABOVE_SCHEDULED' and site_id = :site), 1,
          'course-level warnings take the course''s site');

select api.use_tenant('LIVE');
select is((select sum(beds_available + scheduled)::int from api.fn_weekly_overview(:'w0', 5)), 0,
          'LIVE sees nothing of DEMO');

select * from finish();
rollback;
