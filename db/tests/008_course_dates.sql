-- Warning for course bookings outside their course's dates (migration 0010):
-- strict, no allowance. On the DEMO sample data; w0 is the Monday two weeks ago.
-- TEC-07 runs w0+14 (first night) to w0+27 (departure, 0016).
begin;
create extension pgtap;
select plan(10);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();

select date_trunc('week', current_date - 14)::date as w0 \gset
select course_id as tec, to_char(start_date, 'DD/MM') as tec_from, to_char(end_date, 'DD/MM') as tec_to
  from core.courses where tenant_id = core.current_tenant_id() and code = 'TEC-07' \gset
select b.bed_id as r103a from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = '103' and b.code = 'a' \gset

select is((select count(*)::int from api.warnings where kind = 'OUTSIDE_COURSE_DATES'), 0,
          'the sample bookings all match their course dates');

-- Before saving: the check, given the course.
select results_eq(format($$ select bed_id, kind, ref, blocks from api.fn_check_allocation(array[%s], %L, %L, %s) $$,
                         :r103a, (:'w0'::date + 14), (:'w0'::date + 28), :tec),
                  $$ values (null::integer, 'COURSE_DATES', 'TEC-07', false) $$,
                  'fn_check_allocation flags nights after the course ends, given the course');
select is((select count(*)::int from api.fn_check_allocation(array[:r103a], :'w0'::date + 13, :'w0'::date + 26)), 0,
          'without a course there is no course-dates row');
select is((select count(*)::int from api.fn_check_allocation(array[:r103a], :'w0'::date + 14, :'w0'::date + 26, :tec)), 0,
          'nights within the course dates give no course-dates row');

-- Saving: the warning comes back, and api.warnings lists it.
select allocation_id as a, warnings as w
  from api.fn_allocate_course(:tec, array[:r103a], :'w0'::date + 14, :'w0'::date + 28) \gset
select is(:'w', format('{"Outside the course dates: TEC-07 runs %s to %s"}', :'tec_from', :'tec_to'),
          'fn_allocate_course returns the course-dates warning');
select is((select message from api.warnings where kind = 'OUTSIDE_COURSE_DATES' and allocation_id = :a),
          format('TEC-07 booking in Room 103 bed A is outside the course dates (%s to %s)', :'tec_from', :'tec_to'),
          'api.warnings lists it, naming the course and bed');

-- Moving inside the dates clears it; an early first night brings it back.
select is((select cardinality(warnings) from api.fn_move_allocation(:a, null, :'w0'::date + 14, :'w0'::date + 26)), 0,
          'moving within the course dates returns no warning');
select is((select count(*)::int from api.warnings where kind = 'OUTSIDE_COURSE_DATES'), 0,
          'and the warning is gone');
select is((select warnings from api.fn_move_allocation(:a, null, :'w0'::date + 13, :'w0'::date + 26)),
          array[format('Outside the course dates: TEC-07 runs %s to %s', :'tec_from', :'tec_to')],
          'arriving the night before the course warns (strict, no allowance)');

select api.fn_cancel_allocation(:a);
select is((select count(*)::int from api.warnings where kind = 'OUTSIDE_COURSE_DATES'), 0,
          'a cancelled booking gives no warning');

select * from finish();
rollback;
