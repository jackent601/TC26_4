-- External bookings and outages (migration 0017, D38), on the DEMO sample data.
-- w0 is the Monday two weeks ago. INT-22 is in Room 101 and Room 102 (all four
-- beds) from w0+21 to w0+27; nothing is booked in Room 101 from w0+28 to w0+34.
begin;
create extension pgtap;
select plan(25);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'Phil', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select to_char(:'w0'::date + 21, 'DD/MM') as d21, to_char(:'w0'::date + 27, 'DD/MM') as d27,
       to_char(:'w0'::date + 28, 'DD/MM') as d28, to_char(:'w0'::date + 34, 'DD/MM') as d34 \gset
create temporary table bed_ids as
  select r.code || b.code as k, b.bed_id from core.beds b join core.rooms r using (room_id)
   where r.tenant_id = core.current_tenant_id();
select (select bed_id from bed_ids where k = '101a') as r101a, (select bed_id from bed_ids where k = '101b') as r101b \gset
select room_id as room101, f.floor_id as floor1 from core.rooms r join core.floors f using (floor_id)
 where r.tenant_id = core.current_tenant_id() and r.code = '101' \gset
select site_id as nc from core.sites where tenant_id = core.current_tenant_id() and code = 'NC' \gset

------------------------------ fn_book_external ------------------------------
select set_config('app.request_id', '22222222-2222-2222-2222-222222222222', true);
select results_eq(format($$ select bed_id, cardinality(warnings) from api.fn_book_external(' BK-9000 ', ' Auditors ', array[%s, %s], %L, %L)
                             order by bed_id $$, :r101a, :r101b, (:'w0'::date + 28), (:'w0'::date + 34)),
                  format($$ values (%s, 0), (%s, 0) $$, least(:r101a, :r101b), greatest(:r101a, :r101b)),
                  'an external booking on free beds: one allocation per bed, no warnings');
select results_eq(format($$ select external_ref::text, external_name::text, status::text, source::text, course_id, individual_no,
                                   start_date, end_date from core.allocations where external_ref = 'BK-9000' and bed_id = %s $$, :r101a),
                  format($$ values ('BK-9000', 'Auditors', 'BOOKED', 'EXTERNAL', null::integer, null::integer, %L::date, %L::date) $$,
                         (:'w0'::date + 28), (:'w0'::date + 34)),
                  'saved trimmed, BOOKED and EXTERNAL, with no course or individual');
select results_eq($$ select summary from api.audit where request_id = '22222222-2222-2222-2222-222222222222' order by audit_id $$,
                  format($$ values ('booked BK-9000 into Room 101 bed A, %s to %s'), ('booked BK-9000 into Room 101 bed B, %s to %s') $$,
                         :'d28', :'d34', :'d28', :'d34'),
                  'audited per bed, named by its reference');
select results_eq($$ select changed_by, summary, site_id from api.audit_requests
                     where request_key = '22222222-2222-2222-2222-222222222222' $$,
                  format($$ values ('Phil', 'booked 2 beds for BK-9000, %s to %s', %s) $$, :'d28', :'d34', :nc),
                  'and rolled into one line in audit_requests, at the beds'' site');
select is((select bool_and(kind = 'external' and external_ref = 'BK-9000')
             from api.fn_bed_bars(:'w0'::date + 28, :'w0'::date + 35) where bed_id in (:r101a, :r101b) and kind <> 'outage'),
          true, 'and shown as external bars');

-- Clashes warn (rule WARNING in the demo) ...
select allocation_id as clash, warnings as clash_warnings
  from api.fn_book_external('BK-9001', 'Overflow', array[:r101a], :'w0'::date + 21, :'w0'::date + 27) \gset
select is(:'clash_warnings'::text[],
          array[format('Room 101 bed A is already booked (INT-22, %s to %s)', :'d21', :'d27')],
          'a clash with a course booking warns');
select count(*) from api.fn_cancel_allocation(:clash);   -- out of the way of what follows
-- ... or refuse when the rule is BLOCK.
update core.rules set severity = 'BLOCK' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';
select throws_ok(format($$ select * from api.fn_book_external('BK-9002', 'Blocked', array[%s], %L, %L) $$, :r101a, (:'w0'::date + 21), (:'w0'::date + 27)),
                 'P0001', format('Not allowed: Room 101 bed A is already booked (INT-22, %s to %s)', :'d21', :'d27'),
                 'and is refused when DOUBLE_BOOKING is BLOCK');
update core.rules set severity = 'WARNING' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';

select throws_ok(format($$ select * from api.fn_book_external('  ', 'x', array[%s], %L, %L) $$, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Enter the booking reference', 'a reference is required');
select throws_ok(format($$ select * from api.fn_book_external('BK-1', null, array[%s], %L, %L) $$, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Enter who the booking is for', 'so is a name');
select throws_ok(format($$ select * from api.fn_book_external('BK-1', 'x', array[%s], %L, %L) $$, :r101a, :'w0', :'w0'),
                 'P0001', 'p_to must be after p_from', 'departure must be after the first night');
select throws_ok(format($$ select * from api.fn_book_external('BK-1', 'x', '{}', %L, %L) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Choose at least one bed', 'at least one bed');
select throws_ok(format($$ select * from api.fn_book_external('BK-1', 'x', array[%s, %s], %L, %L) $$, :r101a, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'A bed is listed more than once', 'no bed twice');

------------------------------- fn_add_outage -------------------------------
-- Room 101 during INT-22: saved, with a warning for each booking it lands on.
select set_config('app.request_id', '33333333-3333-3333-3333-333333333333', true);
select outage_id as o1, warnings as o1_warnings from api.fn_add_outage('room', :room101, :'w0'::date + 23, :'w0'::date + 25, ' Leak ') \gset
select is(:'o1_warnings'::text[],
          array[format('INT-22 in Room 101 bed A (%s to %s) is now in an out-of-action bed', :'d21', :'d27'),
                format('INT-22 in Room 101 bed B (%s to %s) is now in an out-of-action bed', :'d21', :'d27')],
          'an outage on booked beds is saved and warns about each booking');
select results_eq(format($$ select attr_code::text, attr_value::text, comments::text, room_id, site_id, bed_id, valid_from, valid_to
                             from core.location_attributes where loc_attr_id = %s $$, :o1),
                  format($$ values ('OUT_OF_ACTION', 'Y', 'Leak', %s, null::integer, null::integer, %L::date, %L::date) $$,
                         :room101, (:'w0'::date + 23), (:'w0'::date + 25)),
                  'stored on the room, trimmed');
select is((select count(*)::int from core.v_bed_outages where outage_id = :o1), 2, 'it applies to both beds in the room');
select is((select count(*)::int from api.warnings where kind = 'OUT_OF_ACTION' and message like 'INT-22 is in an out-of-action bed (Room 101 %'), 2,
          'and api.warnings now lists both bookings');
select results_eq($$ select summary, site_id from api.audit where request_id = '33333333-3333-3333-3333-333333333333' $$,
                  format($$ values ('put Room 101 out of action, %s to %s: Leak (2 warnings)', %s) $$,
                         to_char(:'w0'::date + 23, 'DD/MM'), to_char(:'w0'::date + 25, 'DD/MM'), :nc),
                  'audited as a sentence, at the room''s site');

-- A whole floor while nothing is booked there.
select is((select cardinality(warnings) from api.fn_add_outage('Floor', :floor1, :'w0'::date + 35, :'w0'::date + 40, 'Painting')), 0,
          'an outage on free beds has no warnings');
select is((select summary from api.audit where table_name = 'location_attributes' order by audit_id desc limit 1),
          format('put Block A Floor 1 out of action, %s to %s: Painting', to_char(:'w0'::date + 35, 'DD/MM'), to_char(:'w0'::date + 40, 'DD/MM')),
          'a floor is named with its block');

select throws_ok(format($$ select * from api.fn_add_outage('Wing', %s, %L, %L, 'x') $$, :room101, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown level: Wing (Site, Building, Block, Floor, Room or Bed)', 'the level must be one of the six');
select throws_ok(format($$ select * from api.fn_add_outage('Room', -1, %L, %L, 'x') $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown location', 'the location must exist');
select throws_ok(format($$ select * from api.fn_add_outage('Room', %s, %L, %L, '  ') $$, :room101, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Enter a reason', 'a reason is required');
select throws_ok(format($$ select * from api.fn_add_outage('Room', %s, %L, %L, 'x') $$, :room101, :'w0', :'w0'),
                 'P0001', 'p_to must be after p_from', 'the end must be after the start');

------------------------------ Tenant isolation ------------------------------
select api.use_tenant('LIVE');
select throws_ok(format($$ select * from api.fn_add_outage('Room', %s, %L, %L, 'x') $$, :room101, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown location', 'LIVE can''t put a DEMO room out of action');
select throws_ok(format($$ select * from api.fn_book_external('BK-1', 'x', array[%s], %L, %L) $$, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown bed', 'or book a DEMO bed');

select * from finish();
rollback;
