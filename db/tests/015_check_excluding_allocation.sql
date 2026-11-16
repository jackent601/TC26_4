-- api.fn_check_allocation leaving out the booking being moved (migration 0018),
-- on the DEMO sample data. w0 is the Monday two weeks ago. INT-22 is in Room 101
-- bed A from w0+21 to w0+27.
begin;
create extension pgtap;
select plan(4);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();

select date_trunc('week', current_date - 14)::date as w0 \gset
select b.bed_id as r101a from core.beds b join core.rooms r using (room_id)
 where r.tenant_id = core.current_tenant_id() and r.code = '101' and b.code = 'a' \gset
select a.allocation_id as int1 from core.allocations a join core.courses c using (course_id)
 where c.code = 'INT-22' and a.bed_id = :r101a \gset

-- Sliding INT-22's booking two days later on the same bed.
select is((select count(*)::int from api.fn_check_allocation(array[:r101a], :'w0'::date + 23, :'w0'::date + 29)
            where kind = 'BOOKING' and ref = 'INT-22'), 1,
          'without p_exclude_allocation the booking clashes with itself');
select is((select count(*)::int from api.fn_check_allocation(array[:r101a], :'w0'::date + 23, :'w0'::date + 29,
                                                             p_exclude_allocation => :int1)), 0,
          'with it, the move has no clashes');

-- Another booking on the bed still shows.
select count(*) from api.fn_book_external('BK-7000', 'Visitor', array[:r101a], :'w0'::date + 28, :'w0'::date + 30);
select is((select array_agg(ref order by start_date) from api.fn_check_allocation(array[:r101a], :'w0'::date + 23, :'w0'::date + 29,
                                                                                  p_exclude_allocation => :int1)),
          array['BK-7000'], 'only the moved booking is left out');
select course_id as int22 from core.courses where tenant_id = core.current_tenant_id() and code = 'INT-22' \gset
select is((select count(*)::int from api.fn_check_allocation(array[:r101a], :'w0'::date + 23, :'w0'::date + 29, :int22, :int1)
            where kind = 'COURSE_DATES'), 1, 'and with the course given, it still says the move goes past the course''s end');

select * from finish();
rollback;
