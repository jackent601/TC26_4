-- A new install comes with DEMO's sample data (migration 0012, D34). The test
-- database is built fresh from every migration, and each test file rolls back,
-- so this sees exactly what a new install starts with.
begin;
create extension pgtap;
select plan(5);

select api.use_tenant('DEMO');
select is((select bed_count::int from api.health), 23, 'DEMO has the 23 sample beds straight after install');
select is((select count(*)::int from api.course_figures), 5, 'and the 5 sample courses');
select is((select min(start_date) from api.course_figures), date_trunc('week', current_date - 14)::date,
          'dated relative to the day of install (the Monday two weeks ago)');
-- 0016: courses and their bookings run Monday (first night) to Sunday (departure).
select is((select count(*)::int from core.courses
            where tenant_id = core.current_tenant_id() and (extract(isodow from start_date) <> 1 or extract(isodow from end_date) <> 7)) +
          (select count(*)::int from core.allocations
            where tenant_id = core.current_tenant_id() and course_id is not null and (extract(isodow from start_date) <> 1 or extract(isodow from end_date) <> 7)),
          0, 'sample courses and their bookings run Monday to Sunday (0016)');

select api.use_tenant('LIVE');
select is((select bed_count::int from api.health), 0, 'LIVE gets no sample data');

select * from finish();
rollback;
