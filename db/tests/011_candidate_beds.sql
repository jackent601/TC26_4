-- Course-first booking: api.fn_candidate_beds (migration 0013, D35), on the DEMO
-- sample data. w0 is the Monday two weeks ago. FIN-03 runs w0+28 to w0+33 with
-- nothing booked then; INT-22 runs w0+21 to w0+26 alongside TEC-07, BK-4502,
-- BK-4530 and the Block B Floor 1 outage (w0+21 to w0+28).
-- Estate order: Block A floors 1-3 (101 102 103 104 / 201 202 203 204 /
-- 301 302 303), Block B floor 1 (B101 B102); 103, 204 and 303 have one bed.
begin;
create extension pgtap;
select plan(22);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'tester', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select course_id as fin from core.courses where tenant_id = core.current_tenant_id() and code = 'FIN-03' \gset
select course_id as int from core.courses where tenant_id = core.current_tenant_id() and code = 'INT-22' \gset
create temporary table bed_ids as
  select r.code || b.code as k, b.bed_id from core.beds b join core.rooms r using (room_id)
   where r.tenant_id = core.current_tenant_id();
select (select bed_id from bed_ids where k = '201a') as r201a, (select bed_id from bed_ids where k = 'B101a') as b101a,
       (select bed_id from bed_ids where k = 'B102a') as b102a \gset

-- Nothing is booked in FIN-03's week: every bed is free.
select is((select count(*)::text || ' beds, all free: ' || bool_and(free)::text
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 6)),
          '23 beds, all free: true', 'every bed on the course''s site is a candidate');
select is((select array_agg(room_name || ' ' || bed_name order by rank)
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 6) where suggested),
          array['Room 101 Bed A', 'Room 101 Bed B', 'Room 102 Bed A', 'Room 102 Bed B', 'Room 104 Bed A', 'Room 104 Bed B'],
          'six beds: three whole two-bed rooms in estate order');
select is((select array_agg(rank order by rank)
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 6) where suggested),
          array[1, 2, 3, 4, 5, 6], 'suggested beds are ranked 1 to p_beds');
select is((select array_agg(room_name || ' ' || bed_name order by rank)
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 3) where suggested),
          array['Room 101 Bed A', 'Room 101 Bed B', 'Room 103 Bed A'],
          'three beds: one whole room, then the one-bed room that fits what is left');
select is((select array_agg(room_name || ' ' || bed_name order by rank)
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 1) where suggested),
          array['Room 103 Bed A'], 'one bed: the first room that fits is a one-bed room');

-- Once the course has a bed in Room 201, that room comes first.
select count(*) from api.fn_allocate_course(:fin, array[:r201a], :'w0'::date + 28, :'w0'::date + 33);
select is((select array_agg(room_name || ' ' || bed_name order by rank)
             from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33, 2) where suggested),
          array['Room 201 Bed B', 'Room 103 Bed A'], 'a room the course is already in is filled first');
select results_eq(format($$ select free, course_in_room, warnings[1] like 'Already booked (FIN-03, %%'
                             from api.fn_candidate_beds(%s, %L, %L, 2) where bed_id = %s $$,
                         :fin, (:'w0'::date + 28), (:'w0'::date + 33), :r201a),
                  $$ values (false, true, true) $$, 'the course''s own bed is not free, and names the course');

-- INT-22's week: TEC-07, INT-22, BK-4502, BK-4530 and the Block B outage.
select is((select count(*)::int from api.fn_candidate_beds(:int, :'w0'::date + 21, :'w0'::date + 26) where free), 9,
          'beds with a booking or an outage on any of the nights are not free');
select results_eq(format($$ select cardinality(warnings), warnings[1] like 'Out of action (Fire alarm upgrade, set on the floor, %%',
                                   warnings[2] like 'Already booked (BK-4530, %%'
                             from api.fn_candidate_beds(%s, %L, %L) where bed_id = %s $$,
                         :int, (:'w0'::date + 21), (:'w0'::date + 26), :b101a),
                  $$ values (2, true, true) $$, 'every clash is listed, earliest first, worded like the write path');
select is((select count(*)::int from api.fn_candidate_beds(:int, :'w0'::date + 21, :'w0'::date + 26) where course_in_room), 4,
          'course_in_room marks the beds of rooms the course already uses');
select is((select bool_or(blocks) from api.fn_candidate_beds(:int, :'w0'::date + 21, :'w0'::date + 26)), false,
          'nothing blocks while the clash rules are WARNING');
update core.rules set severity = 'BLOCK' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';
select results_eq(format($$ select bed_id, blocks from api.fn_candidate_beds(%s, %L, %L) where bed_id in (%s, %s)
                             order by bed_id = %s desc $$,
                         :int, (:'w0'::date + 21), (:'w0'::date + 26), :b101a, :b102a, :b101a),
                  format($$ values (%s, true), (%s, false) $$, :b101a, :b102a),
                  'blocks follows the clash rule: a booked bed blocks, an outage alone does not');
update core.rules set severity = 'WARNING' where tenant_id = core.current_tenant_id() and rule_code = 'DOUBLE_BOOKING';

-- How many are suggested.
select is((select count(*)::int from api.fn_candidate_beds(:int, :'w0'::date + 21, :'w0'::date + 26, 20) where suggested), 9,
          'asking for more beds than are free suggests every free bed');
select is((select (count(*) filter (where suggested))::text || '/' || count(rank)::text
             from api.fn_candidate_beds(:int, :'w0'::date + 21, :'w0'::date + 26)),
          '0/0', 'without p_beds nothing is suggested and no bed has a rank');

-- Only the course's site; every site when the course has none.
insert into core.sites (code, name, sort_order) values ('XX', 'Other site', 9) returning site_id as xsite \gset
insert into core.buildings (site_id, code, name) values (:xsite, 'X', 'X House') returning building_id as xbldg \gset
insert into core.blocks (building_id, code, name) values (:xbldg, 'X', 'Block X') returning block_id as xblock \gset
insert into core.floors (block_id, code, name) values (:xblock, '1', 'Floor 1') returning floor_id as xfloor \gset
insert into core.rooms (floor_id, code, name) values (:xfloor, 'X1', 'Room X1') returning room_id as xroom \gset
insert into core.beds (room_id, code) values (:xroom, 'a');
select is((select count(*)::int from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33)), 23,
          'beds on other sites are not candidates for a course with a site');
update core.courses set site_id = null where course_id = :fin;
select is((select count(*)::int from api.fn_candidate_beds(:fin, :'w0'::date + 28, :'w0'::date + 33)), 24,
          'a course without a site can use any bed');

-- Checks.
select throws_ok(format($$ select * from api.fn_candidate_beds(%s, %L, %L) $$, :fin, :'w0', :'w0'),
                 'P0001', 'p_to must be after p_from', 'fn_candidate_beds needs p_to after p_from');
select throws_ok(format($$ select * from api.fn_candidate_beds(-1, %L, %L) $$, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown course', 'fn_candidate_beds rejects an unknown course');
select throws_ok(format($$ select * from api.fn_candidate_beds(%s, %L, %L, -1) $$, :fin, :'w0', (:'w0'::date + 1)),
                 'P0001', 'p_beds must not be negative', 'fn_candidate_beds rejects a negative p_beds');

-- Tenants and roles.
select api.use_tenant('LIVE');
select throws_ok(format($$ select * from api.fn_candidate_beds(%s, %L, %L) $$, :fin, :'w0', (:'w0'::date + 1)),
                 'P0001', 'Unknown course', 'LIVE can''t see a DEMO course''s candidates');
select is(has_function_privilege('api_user', 'api.fn_candidate_beds(integer, date, date, integer)', 'execute'),
          true, 'api_user can call fn_candidate_beds');
select is(has_function_privilege('api_user', 'api_internal.candidate_bed_facts(integer, date, date)', 'execute'),
          false, 'the facts helper is not an endpoint');

select * from finish();
rollback;
