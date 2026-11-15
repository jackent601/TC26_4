-- Write API for course bookings (migration 0009; D30-D32), on the DEMO sample data.
-- Assertions run as the test superuser (pgTAP is in public); the api functions
-- are security definer, so row-level security still applies. One check calls a
-- write as api_user. Demo dates are relative to day 0 (w0), the Monday two weeks ago.
begin;
create extension pgtap;
select plan(43);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'tester', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select course_id as fin from core.courses where tenant_id = core.current_tenant_id() and code = 'FIN-03' \gset
select course_id as ldr from core.courses where tenant_id = core.current_tenant_id() and code = 'LDR-01' \gset
create temporary table bed_ids as
  select r.code || b.code as k, b.bed_id from core.beds b join core.rooms r using (room_id)
   where r.tenant_id = core.current_tenant_id();
select (select bed_id from bed_ids where k = '101a') as r101a, (select bed_id from bed_ids where k = '101b') as r101b,
       (select bed_id from bed_ids where k = '102a') as r102a, (select bed_id from bed_ids where k = '102b') as r102b,
       (select bed_id from bed_ids where k = '103a') as r103a, (select bed_id from bed_ids where k = '104a') as r104a,
       (select bed_id from bed_ids where k = '104b') as r104b, (select bed_id from bed_ids where k = '201a') as r201a,
       (select bed_id from bed_ids where k = 'B101b') as b101b, (select bed_id from bed_ids where k = 'B102a') as b102a \gset

------------------------------ clash rules (D30) ----------------------------
select results_eq($$ select t.code::text, r.rule_type::text, r.severity::text from core.rules r
                      join core.tenants t using (tenant_id) where r.rule_code = 'DOUBLE_BOOKING' order by 1 $$,
                  $$ values ('DEMO', 'BED_CLASH', 'WARNING'), ('LIVE', 'BED_CLASH', 'WARNING') $$,
                  'every tenant has a DOUBLE_BOOKING rule, WARNING by default');
select throws_ok($$ insert into core.rules (tenant_id, rule_code, name, rule_type, location_attr, severity, message)
                    select tenant_id, 'BAD', 'x', 'BED_CLASH', 'OUT_OF_ACTION', 'WARNING', 'x'
                    from core.tenants where code = 'LIVE' $$,
                 '23514', null, 'a BED_CLASH rule takes no attributes');

---------------------------- fn_allocate_course -----------------------------
-- FIN-03 runs w0+28 to w0+34 (0016) and has nothing allocated; Room 101 is free then.
select results_eq(format($$ select bed_id, cardinality(warnings) from api.fn_allocate_course(%s, array[%s, %s], %L, %L) $$,
                         :fin, :r101a, :r101b, (:'w0'::date + 28), (:'w0'::date + 33)),
                  format($$ values (%s, 0), (%s, 0) $$, :r101a, :r101b),
                  'allocates a course into two free beds, no warnings');
select results_eq(format($$ select individual_no, status::text, start_date, end_date from core.allocations
                             where course_id = %s order by individual_no $$, :fin),
                  format($$ values (1, 'ALLOCATED', %L::date, %L::date), (2, 'ALLOCATED', %L::date, %L::date) $$,
                         (:'w0'::date + 28), (:'w0'::date + 33), (:'w0'::date + 28), (:'w0'::date + 33)),
                  'one allocation per bed, individuals 1 and 2, status ALLOCATED');
select is((select count(*)::int from core.audit_log where course_id = :fin and action = 'INSERT' and changed_by = 'tester'),
          2, 'each new allocation is audited with the user from app.user');

select results_eq(format($$ select cardinality(warnings), warnings[1] like 'Room 101 bed A is already booked (FIN-03, %%'
                             from api.fn_allocate_course(%s, array[%s], %L, %L) $$,
                         :fin, :r101a, (:'w0'::date + 28), (:'w0'::date + 33)),
                  $$ values (1, true) $$,
                  'a double booking saves with a warning by default (D11, D30)');
select is((select max(individual_no) from core.allocations where course_id = :fin), 3,
          'the next allocation gets the next free individual');

select is((select count(*)::int from api.fn_allocate_course(:fin, array[:r102a, :r102b, :r103a, :r104a, :r104b],
                                                             :'w0'::date + 28, :'w0'::date + 33)), 5,
          'a course can be allocated beyond scheduled and loaded (D31)');
select results_eq(format($$ select max(individual_no), (select allocated::int from api.course_figures where course_id = %s)
                             from core.allocations where course_id = %s $$, :fin, :fin),
                  $$ values (8, 8) $$, 'FIN-03 (6 scheduled, 2 loaded) now has 8 individuals allocated');

-- Out of action: Block B Floor 1 w0+21 to w0+28.
select results_eq(format($$ select warnings[1] like 'Room B101 bed B is out of action (Fire alarm upgrade, set on the floor, %%'
                             from api.fn_allocate_course(%s, array[%s], %L, %L) $$,
                         :fin, :b101b, (:'w0'::date + 22), (:'w0'::date + 25)),
                  $$ values (true) $$, 'allocating into an out-of-action bed saves with a warning by default');

-- BLOCK refuses, and nothing of the request is saved.
update core.rules set severity = 'BLOCK' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';
select count(*) as before_block from core.allocations where course_id = :fin \gset
select throws_like(format($$ select * from api.fn_allocate_course(%s, array[%s, %s], %L, %L) $$,
                          :fin, :r201a, :r101a, (:'w0'::date + 28), (:'w0'::date + 33)),
                   'Not allowed: Room 101 bed A is already booked%',
                   'with DOUBLE_BOOKING set to BLOCK a double booking is refused');
select is((select count(*) from core.allocations where course_id = :fin), :'before_block'::bigint,
          'a refused request saves nothing, not even its free beds');
select is((select bool_and(blocks) from api.fn_check_allocation(array[:r101a], :'w0'::date + 28, :'w0'::date + 33)
            where kind = 'BOOKING'), true, 'fn_check_allocation says the booking clash blocks');
update core.rules set severity = 'WARNING' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';

update core.rules set severity = 'BLOCK' where tenant_id = core.current_tenant_id() and rule_code = 'OUT_OF_ACTION';
select throws_like(format($$ select * from api.fn_allocate_course(%s, array[%s], %L, %L) $$,
                          :fin, :b102a, (:'w0'::date + 22), (:'w0'::date + 25)),
                   'Not allowed: Room B102 bed A is out of action%',
                   'with OUT_OF_ACTION set to BLOCK an out-of-action bed is refused');
update core.rules set severity = 'WARNING' where tenant_id = core.current_tenant_id() and rule_code = 'OUT_OF_ACTION';

update core.rules set active = 'N' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';
select is((select cardinality(warnings) from api.fn_allocate_course(:fin, array[:r101a], :'w0'::date + 28, :'w0'::date + 33)),
          0, 'an inactive clash rule is not checked');
select is((select count(*)::int from api.warnings where kind = 'DOUBLE_BOOKING'), 0,
          'an inactive DOUBLE_BOOKING rule hides its warnings too');
update core.rules set active = 'Y' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';
select is((select count(*)::int from api.warnings where kind = 'DOUBLE_BOOKING' and message like '%#%'), 0,
          'warnings name the course, not the individual (D31)');

select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[%s], %L, %L) $$, :fin, :r101a, :'w0', :'w0'),
                 'P0001', 'p_to must be after p_from', 'fn_allocate_course needs p_to after p_from');
select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[]::integer[], %L, %L) $$, :fin, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Choose at least one bed', 'fn_allocate_course needs a bed');
select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[%s, %s], %L, %L) $$, :fin, :r101a, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'A bed is listed more than once', 'fn_allocate_course rejects a repeated bed');
select throws_ok(format($$ select * from api.fn_allocate_course(-1, array[%s], %L, %L) $$, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown course', 'fn_allocate_course rejects an unknown course');
select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[-1], %L, %L) $$, :fin, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown bed', 'fn_allocate_course rejects an unknown bed');
update core.courses set status = 'CANCELLED' where course_id = :ldr;
select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[%s], %L, %L) $$, :ldr, :r201a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'The course is cancelled', 'fn_allocate_course rejects a cancelled course');
update core.courses set status = 'CONFIRMED' where course_id = :ldr;

--------------------------- fn_cancel_allocation ----------------------------
-- Individual 1 has two allocations by now (numbers are free per set of nights): take the first.
select min(allocation_id) as a1 from core.allocations where course_id = :fin and individual_no = 1 \gset
select results_eq(format($$ select allocation_id, status from api.fn_cancel_allocation(%s) $$, :a1),
                  format($$ values (%s, 'CANCELLED') $$, :a1), 'fn_cancel_allocation cancels');
select is((select status::text from core.allocations where allocation_id = :a1), 'CANCELLED', 'the allocation is kept, as CANCELLED');
select is((select detail from core.audit_log where record_id = :a1 and action = 'CANCEL'), '{"from_status": "ALLOCATED"}',
          'cancelling is audited with the previous status');
select throws_ok(format($$ select * from api.fn_cancel_allocation(%s) $$, :a1),
                 'P0001', 'The allocation is already cancelled', 'cancelling twice is refused');
-- (Read back in a second statement: one statement can't see rows its own function call inserted.)
select allocation_id as again from api.fn_allocate_course(:fin, array[:r201a], :'w0'::date + 28, :'w0'::date + 33) \gset
select is((select individual_no from core.allocations where allocation_id = :again), 1,
          'a cancelled individual''s number is free again');

---------------------------- fn_move_allocation -----------------------------
select min(allocation_id) as a2 from core.allocations where course_id = :fin and individual_no = 2 \gset
select results_eq(format($$ select bed_id, cardinality(warnings) from api.fn_move_allocation(%s, %s) $$, :a2, :b102a),
                  format($$ values (%s, 0) $$, :b102a), 'fn_move_allocation moves to another bed');
select is((select action from core.audit_log where record_id = :a2 order by audit_id desc limit 1), 'MOVE', 'a move is audited');
select results_eq(format($$ select start_date, warnings[1] like 'Room B102 bed A is out of action%%'
                             from api.fn_move_allocation(%s, null, %L, %L) $$, :a2, (:'w0'::date + 26), (:'w0'::date + 33)),
                  format($$ values (%L::date, true) $$, (:'w0'::date + 26)),
                  'moving the dates into an outage saves with a warning');
select throws_ok(format($$ select * from api.fn_move_allocation(%s) $$, :a2),
                 'P0001', 'Nothing to change', 'a move that changes nothing is refused');
select throws_ok(format($$ select * from api.fn_move_allocation(%s) $$, :a1),
                 'P0001', 'A cancelled allocation can''t be moved', 'a cancelled allocation can''t be moved');

------------------------------- fn_set_status -------------------------------
select results_eq(format($$ select status, checked_in_at is not null, checked_out_at is null from api.fn_set_status(%s, 'CHECKED_IN') $$, :a2),
                  $$ values ('CHECKED_IN', true, true) $$, 'checking in sets the check-in time');
select results_eq(format($$ select status, checked_in_at is not null, checked_out_at is not null from api.fn_set_status(%s, 'CHECKED_OUT') $$, :a2),
                  $$ values ('CHECKED_OUT', true, true) $$, 'checking out sets the check-out time too');
select results_eq(format($$ select status, checked_in_at is null, checked_out_at is null from api.fn_set_status(%s, 'BOOKED') $$, :a2),
                  $$ values ('BOOKED', true, true) $$, 'any change is allowed for now, and clears the times (D31)');
select is((select count(*)::int from core.audit_log where record_id = :a2 and action = 'STATUS'), 3, 'each status change is audited');
select throws_ok(format($$ select * from api.fn_set_status(%s, 'ARRIVED') $$, :a2),
                 'P0001', 'Unknown status: ARRIVED', 'an unknown status is refused');

------------------------------ tenants and roles ----------------------------
select api.use_tenant('LIVE');
select throws_ok(format($$ select * from api.fn_cancel_allocation(%s) $$, :a2),
                 'P0001', 'Unknown allocation', 'LIVE can''t touch a DEMO allocation');
select throws_ok(format($$ select * from api.fn_allocate_course(%s, array[%s], %L, %L) $$, :fin, :r101a, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown course', 'LIVE can''t allocate a DEMO course');
select set_config('app.tenant_id', '', true);
select throws_ok(format($$ select * from api.fn_set_status(%s, 'BOOKED') $$, :a2),
                 'P0001', 'No tenant selected', 'writes need a tenant');

select is(has_function_privilege('api_user', 'api_internal.audit(text, integer, integer, integer, text, jsonb)', 'execute'),
          false, 'api_user can''t write the audit log directly');
set local role api_user;
select api.use_tenant('DEMO');
select set_config('app.user', 'api tester', true);
select status as as_api_user from api.fn_set_status(:a2, 'CHECKED_IN') \gset
reset role;
select is(:'as_api_user'::text || '/' || (select changed_by from core.audit_log where record_id = :a2 order by audit_id desc limit 1),
          'CHECKED_IN/api tester', 'api_user can call the write functions, audited as the X-User');

select * from finish();
rollback;
