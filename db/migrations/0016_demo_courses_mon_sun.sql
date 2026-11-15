-- migrate:up
--------------------------------------------------------------------------------
-- 0016: the DEMO sample courses run Monday (first night) to Sunday (departure),
-- the same as a week block on the availability grid and the Courses tab (D9),
-- so booking a course's weeks no longer warns about nights outside its dates.
-- Before, each course ended on a Saturday.
--
-- Replaces core.load_sample_data (0004) with only the course end dates changed
-- (days 6, 13, 27, 27 and 34 instead of 5, 12, 26, 26 and 33); the bookings take
-- the course dates. DEMO's data is reloaded here only if nobody has changed it
-- yet (no audit rows), e.g. a new install; otherwise "Reset demo data" or
-- scripts/db-seed.sh reloads it. LIVE never gets sample data (D25).
--------------------------------------------------------------------------------
set local role app_owner;

create or replace function core.load_sample_data(p_tenant_id integer)
returns void
language plpgsql
set search_path = pg_catalog, core
as $$
declare
  v_prev text := current_setting('app.tenant_id', true);
  w0     date := date_trunc('week', current_date - 14)::date;   -- day 0
  v_site integer;
  v_bldg integer;
begin
  perform set_config('app.tenant_id', p_tenant_id::text, true);

  ------------------------------ Estate ------------------------------
  insert into core.sites (tenant_id, code, name, sort_order)
  values (p_tenant_id, 'NC', 'North Camp', 1) returning site_id into v_site;

  insert into core.buildings (tenant_id, site_id, code, name, sort_order)
  values (p_tenant_id, v_site, 'HH', 'Hartley House', 1) returning building_id into v_bldg;

  insert into core.blocks (tenant_id, building_id, code, name, sort_order)
  values (p_tenant_id, v_bldg, 'A', 'Block A', 1),
         (p_tenant_id, v_bldg, 'B', 'Block B', 2);

  insert into core.floors (tenant_id, block_id, code, name, sort_order)
  select p_tenant_id, bl.block_id, v.code, v.name, v.so
  from (values ('A', '1', 'Floor 1', 1), ('A', '2', 'Floor 2', 2), ('A', '3', 'Floor 3', 3),
               ('B', '1', 'Floor 1', 1)) v(blk, code, name, so)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.building_id = v_bldg and bl.code = v.blk;

  insert into core.rooms (tenant_id, floor_id, code, name, sort_order)
  select p_tenant_id, f.floor_id, v.room, 'Room ' || v.room, v.so
  from (values ('A', '1', '101', 1), ('A', '1', '102', 2), ('A', '1', '103', 3), ('A', '1', '104', 4),
               ('A', '2', '201', 1), ('A', '2', '202', 2), ('A', '2', '203', 3), ('A', '2', '204', 4),
               ('A', '3', '301', 1), ('A', '3', '302', 2), ('A', '3', '303', 3),
               ('B', '1', 'B101', 1), ('B', '1', 'B102', 2)) v(blk, flr, room, so)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.building_id = v_bldg and bl.code = v.blk
  join core.floors f  on f.block_id = bl.block_id and f.code = v.flr;

  insert into core.beds (tenant_id, room_id, code)
  select p_tenant_id, r.room_id, chr(96 + n)                      -- a, b
  from (values ('101', 2), ('102', 2), ('103', 1), ('104', 2),
               ('201', 2), ('202', 2), ('203', 2), ('204', 1),
               ('301', 2), ('302', 2), ('303', 1),
               ('B101', 2), ('B102', 2)) v(room, beds)
  join core.rooms r on r.tenant_id = p_tenant_id and r.code = v.room
  cross join lateral generate_series(1, v.beds) n;

  ----------------------- Location attributes ------------------------
  -- Outages: one on a room, one on a whole floor.
  insert into core.location_attributes (tenant_id, attr_code, attr_value, valid_from, valid_to, comments, room_id)
  select p_tenant_id, 'OUT_OF_ACTION', 'Y', w0 + 10, w0 + 20, 'Heating failure', room_id
  from core.rooms where tenant_id = p_tenant_id and code = '203';

  insert into core.location_attributes (tenant_id, attr_code, attr_value, valid_from, valid_to, comments, floor_id)
  select p_tenant_id, 'OUT_OF_ACTION', 'Y', w0 + 21, w0 + 28, 'Fire alarm upgrade', f.floor_id
  from core.floors f join core.blocks bl on bl.block_id = f.block_id
  where bl.tenant_id = p_tenant_id and bl.code = 'B' and f.code = '1';

  -- Block A Floor 3 is intended for grade 5 and above; Floor 1 is step-free.
  insert into core.location_attributes (tenant_id, attr_code, attr_value, floor_id)
  select p_tenant_id, v.attr, v.val, f.floor_id
  from (values ('3', 'MIN_GRADE', '5'), ('1', 'STEP_FREE', 'Y')) v(flr, attr, val)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.code = 'A'
  join core.floors f  on f.block_id = bl.block_id and f.code = v.flr;

  ------------------------------ Courses -----------------------------
  insert into core.courses (tenant_id, code, name, site_id, start_date, end_date,
                            scheduled, loaded, loaded_at, status)
  select p_tenant_id, v.code, v.name, v_site, w0 + v.d1, w0 + v.d2,
         v.sched, v.loaded, now() - make_interval(days => v.ago), 'CONFIRMED'
  from (values
    ('LDR-01', 'Leadership Foundation',  0,  6,  6,  6, 16),   -- past, fully allocated
    ('SAF-14', 'Site Safety',            7, 13,  8,  7,  9),   -- past, 7 of 8 scheduled
    ('TEC-07', 'Technical Refresher',   14, 27, 10, 12,  2),   -- now; loaded above scheduled
    ('INT-22', 'Induction',             21, 27,  4,  3,  4),   -- next week
    ('FIN-03', 'Finance Essentials',    28, 34,  6,  2,  1)    -- in two weeks; nothing allocated
  ) v(code, name, d1, d2, sched, loaded, ago);

  insert into core.course_attributes (tenant_id, course_id, attr_code, attr_value)
  select p_tenant_id, c.course_id, v.attr, v.val
  from (values ('SAF-14', 'WORK_PATTERN', 'FT'), ('INT-22', 'WORK_PATTERN', 'FT'),
               ('TEC-07', 'GRADE', '6')) v(code, attr, val)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code;

  insert into core.course_individual_attributes (tenant_id, course_id, individual_no, attr_code, attr_value)
  select p_tenant_id, c.course_id, v.ind, v.attr, v.val
  from (values
    ('SAF-14', 3, 'STEP_FREE',    'Y'),    -- needs step-free; on Floor 2 -> warning
    ('SAF-14', 5, 'WORK_PATTERN', 'PT'),   -- part-time among full-time on Floor 2 -> info
    ('TEC-07', 1, 'GENDER', 'M'), ('TEC-07', 2, 'GENDER', 'F'),   -- share Room 301 -> warning
    ('TEC-07', 3, 'GENDER', 'M'), ('TEC-07', 4, 'GENDER', 'M'), ('TEC-07', 5, 'GENDER', 'F'),
    ('TEC-07', 4, 'GRADE', '4')            -- below Floor 3's minimum grade 5 -> warning
  ) v(code, ind, attr, val)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code;

  ---------------------------- Allocations ---------------------------
  -- Course allocations: (course, individual, room + bed). Nights = course dates.
  -- Courses run Monday (first night) to Sunday (departure), like a week block (D9, 0016).
  insert into core.allocations (tenant_id, course_id, individual_no, bed_id, start_date, end_date, status, source)
  select p_tenant_id, c.course_id, v.ind, b.bed_id, c.start_date, c.end_date, 'ALLOCATED', 'LOCAL'
  from (values
    ('LDR-01', 1, '101', 'a'), ('LDR-01', 2, '101', 'b'), ('LDR-01', 3, '102', 'a'),
    ('LDR-01', 4, '102', 'b'), ('LDR-01', 5, '103', 'a'), ('LDR-01', 6, '104', 'a'),
    ('SAF-14', 1, '201', 'a'), ('SAF-14', 2, '201', 'b'), ('SAF-14', 3, '202', 'a'),
    ('SAF-14', 4, '202', 'b'), ('SAF-14', 5, '204', 'a'), ('SAF-14', 6, '101', 'a'), ('SAF-14', 7, '101', 'b'),
    ('TEC-07', 1, '301', 'a'), ('TEC-07', 2, '301', 'b'), ('TEC-07', 3, '302', 'a'),
    ('TEC-07', 4, '302', 'b'), ('TEC-07', 5, '303', 'a'),
    ('INT-22', 1, '101', 'a'), ('INT-22', 2, '101', 'b'), ('INT-22', 3, '102', 'a'), ('INT-22', 4, '102', 'b')
  ) v(code, ind, room, bed)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code
  join core.rooms r   on r.tenant_id = p_tenant_id and r.code = v.room
  join core.beds b    on b.room_id = r.room_id and b.code = v.bed;

  -- External bookings (from the external booking system; no course).
  insert into core.allocations (tenant_id, bed_id, start_date, end_date, status, source, external_ref, external_name)
  select p_tenant_id, b.bed_id, w0 + v.d1, w0 + v.d2, 'BOOKED', 'EXTERNAL', v.ref, v.name
  from (values
    ('BK-4471', 'Visiting assessors', '104',  'b',  2,  9),
    ('BK-4519', 'Regional team',      'B101', 'a',  3, 10),
    ('BK-4502', 'Contractor',         '202',  'a', 16, 23),
    ('BK-4530', 'Regional team',      'B101', 'a', 22, 25)   -- clashes with the Block B floor outage
  ) v(ref, name, room, bed, d1, d2)
  join core.rooms r on r.tenant_id = p_tenant_id and r.code = v.room
  join core.beds b  on b.room_id = r.room_id and b.code = v.bed;

  -- Statuses from where each stay falls relative to today.
  update core.allocations set
    status = 'CHECKED_OUT', checked_in_at = start_date + time '15:00', checked_out_at = end_date + time '10:00'
  where tenant_id = p_tenant_id and end_date <= current_date;

  update core.allocations set
    status = 'CHECKED_IN', checked_in_at = start_date + time '15:00'
  where tenant_id = p_tenant_id and start_date <= current_date and end_date > current_date;

  -- One past no-show, for the check-in/out exceptions view.
  update core.allocations a set status = 'NO_SHOW', checked_in_at = null, checked_out_at = null
  from core.courses c
  where a.tenant_id = p_tenant_id and c.course_id = a.course_id
    and c.code = 'SAF-14' and a.individual_no = 6 and a.end_date <= current_date;

  perform set_config('app.tenant_id', coalesce(v_prev, ''), true);
end
$$;

-- Reload an untouched DEMO, as reset_demo_data does (dates relative to today).
do $$
declare
  v_demo integer;
begin
  select tenant_id into v_demo from core.tenants where code = 'DEMO' and is_demo = 'Y';
  if v_demo is not null then
    perform set_config('app.tenant_id', v_demo::text, true);
    if exists (select 1 from core.courses where tenant_id = v_demo)
       and not exists (select 1 from core.audit_log where tenant_id = v_demo) then
      perform api.reset_demo_data();
    end if;
    perform set_config('app.tenant_id', '', true);
  end if;
end
$$;

reset role;

-- migrate:down
-- Restores 0004's loader (courses ending on Saturday). Data already loaded is
-- left as it is; a demo reset reloads it with the old dates.
set local role app_owner;

create or replace function core.load_sample_data(p_tenant_id integer)
returns void
language plpgsql
set search_path = pg_catalog, core
as $$
declare
  v_prev text := current_setting('app.tenant_id', true);
  w0     date := date_trunc('week', current_date - 14)::date;   -- day 0
  v_site integer;
  v_bldg integer;
begin
  perform set_config('app.tenant_id', p_tenant_id::text, true);

  ------------------------------ Estate ------------------------------
  insert into core.sites (tenant_id, code, name, sort_order)
  values (p_tenant_id, 'NC', 'North Camp', 1) returning site_id into v_site;

  insert into core.buildings (tenant_id, site_id, code, name, sort_order)
  values (p_tenant_id, v_site, 'HH', 'Hartley House', 1) returning building_id into v_bldg;

  insert into core.blocks (tenant_id, building_id, code, name, sort_order)
  values (p_tenant_id, v_bldg, 'A', 'Block A', 1),
         (p_tenant_id, v_bldg, 'B', 'Block B', 2);

  insert into core.floors (tenant_id, block_id, code, name, sort_order)
  select p_tenant_id, bl.block_id, v.code, v.name, v.so
  from (values ('A', '1', 'Floor 1', 1), ('A', '2', 'Floor 2', 2), ('A', '3', 'Floor 3', 3),
               ('B', '1', 'Floor 1', 1)) v(blk, code, name, so)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.building_id = v_bldg and bl.code = v.blk;

  insert into core.rooms (tenant_id, floor_id, code, name, sort_order)
  select p_tenant_id, f.floor_id, v.room, 'Room ' || v.room, v.so
  from (values ('A', '1', '101', 1), ('A', '1', '102', 2), ('A', '1', '103', 3), ('A', '1', '104', 4),
               ('A', '2', '201', 1), ('A', '2', '202', 2), ('A', '2', '203', 3), ('A', '2', '204', 4),
               ('A', '3', '301', 1), ('A', '3', '302', 2), ('A', '3', '303', 3),
               ('B', '1', 'B101', 1), ('B', '1', 'B102', 2)) v(blk, flr, room, so)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.building_id = v_bldg and bl.code = v.blk
  join core.floors f  on f.block_id = bl.block_id and f.code = v.flr;

  insert into core.beds (tenant_id, room_id, code)
  select p_tenant_id, r.room_id, chr(96 + n)                      -- a, b
  from (values ('101', 2), ('102', 2), ('103', 1), ('104', 2),
               ('201', 2), ('202', 2), ('203', 2), ('204', 1),
               ('301', 2), ('302', 2), ('303', 1),
               ('B101', 2), ('B102', 2)) v(room, beds)
  join core.rooms r on r.tenant_id = p_tenant_id and r.code = v.room
  cross join lateral generate_series(1, v.beds) n;

  ----------------------- Location attributes ------------------------
  -- Outages: one on a room, one on a whole floor.
  insert into core.location_attributes (tenant_id, attr_code, attr_value, valid_from, valid_to, comments, room_id)
  select p_tenant_id, 'OUT_OF_ACTION', 'Y', w0 + 10, w0 + 20, 'Heating failure', room_id
  from core.rooms where tenant_id = p_tenant_id and code = '203';

  insert into core.location_attributes (tenant_id, attr_code, attr_value, valid_from, valid_to, comments, floor_id)
  select p_tenant_id, 'OUT_OF_ACTION', 'Y', w0 + 21, w0 + 28, 'Fire alarm upgrade', f.floor_id
  from core.floors f join core.blocks bl on bl.block_id = f.block_id
  where bl.tenant_id = p_tenant_id and bl.code = 'B' and f.code = '1';

  -- Block A Floor 3 is intended for grade 5 and above; Floor 1 is step-free.
  insert into core.location_attributes (tenant_id, attr_code, attr_value, floor_id)
  select p_tenant_id, v.attr, v.val, f.floor_id
  from (values ('3', 'MIN_GRADE', '5'), ('1', 'STEP_FREE', 'Y')) v(flr, attr, val)
  join core.blocks bl on bl.tenant_id = p_tenant_id and bl.code = 'A'
  join core.floors f  on f.block_id = bl.block_id and f.code = v.flr;

  ------------------------------ Courses -----------------------------
  insert into core.courses (tenant_id, code, name, site_id, start_date, end_date,
                            scheduled, loaded, loaded_at, status)
  select p_tenant_id, v.code, v.name, v_site, w0 + v.d1, w0 + v.d2,
         v.sched, v.loaded, now() - make_interval(days => v.ago), 'CONFIRMED'
  from (values
    ('LDR-01', 'Leadership Foundation',  0,  5,  6,  6, 16),   -- past, fully allocated
    ('SAF-14', 'Site Safety',            7, 12,  8,  7,  9),   -- past, 7 of 8 scheduled
    ('TEC-07', 'Technical Refresher',   14, 26, 10, 12,  2),   -- now; loaded above scheduled
    ('INT-22', 'Induction',             21, 26,  4,  3,  4),   -- next week
    ('FIN-03', 'Finance Essentials',    28, 33,  6,  2,  1)    -- in two weeks; nothing allocated
  ) v(code, name, d1, d2, sched, loaded, ago);

  insert into core.course_attributes (tenant_id, course_id, attr_code, attr_value)
  select p_tenant_id, c.course_id, v.attr, v.val
  from (values ('SAF-14', 'WORK_PATTERN', 'FT'), ('INT-22', 'WORK_PATTERN', 'FT'),
               ('TEC-07', 'GRADE', '6')) v(code, attr, val)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code;

  insert into core.course_individual_attributes (tenant_id, course_id, individual_no, attr_code, attr_value)
  select p_tenant_id, c.course_id, v.ind, v.attr, v.val
  from (values
    ('SAF-14', 3, 'STEP_FREE',    'Y'),    -- needs step-free; on Floor 2 -> warning
    ('SAF-14', 5, 'WORK_PATTERN', 'PT'),   -- part-time among full-time on Floor 2 -> info
    ('TEC-07', 1, 'GENDER', 'M'), ('TEC-07', 2, 'GENDER', 'F'),   -- share Room 301 -> warning
    ('TEC-07', 3, 'GENDER', 'M'), ('TEC-07', 4, 'GENDER', 'M'), ('TEC-07', 5, 'GENDER', 'F'),
    ('TEC-07', 4, 'GRADE', '4')            -- below Floor 3's minimum grade 5 -> warning
  ) v(code, ind, attr, val)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code;

  ---------------------------- Allocations ---------------------------
  -- Course allocations: (course, individual, room + bed). Nights = course dates.
  insert into core.allocations (tenant_id, course_id, individual_no, bed_id, start_date, end_date, status, source)
  select p_tenant_id, c.course_id, v.ind, b.bed_id, c.start_date, c.end_date, 'ALLOCATED', 'LOCAL'
  from (values
    ('LDR-01', 1, '101', 'a'), ('LDR-01', 2, '101', 'b'), ('LDR-01', 3, '102', 'a'),
    ('LDR-01', 4, '102', 'b'), ('LDR-01', 5, '103', 'a'), ('LDR-01', 6, '104', 'a'),
    ('SAF-14', 1, '201', 'a'), ('SAF-14', 2, '201', 'b'), ('SAF-14', 3, '202', 'a'),
    ('SAF-14', 4, '202', 'b'), ('SAF-14', 5, '204', 'a'), ('SAF-14', 6, '101', 'a'), ('SAF-14', 7, '101', 'b'),
    ('TEC-07', 1, '301', 'a'), ('TEC-07', 2, '301', 'b'), ('TEC-07', 3, '302', 'a'),
    ('TEC-07', 4, '302', 'b'), ('TEC-07', 5, '303', 'a'),
    ('INT-22', 1, '101', 'a'), ('INT-22', 2, '101', 'b'), ('INT-22', 3, '102', 'a'), ('INT-22', 4, '102', 'b')
  ) v(code, ind, room, bed)
  join core.courses c on c.tenant_id = p_tenant_id and c.code = v.code
  join core.rooms r   on r.tenant_id = p_tenant_id and r.code = v.room
  join core.beds b    on b.room_id = r.room_id and b.code = v.bed;

  -- External bookings (from the external booking system; no course).
  insert into core.allocations (tenant_id, bed_id, start_date, end_date, status, source, external_ref, external_name)
  select p_tenant_id, b.bed_id, w0 + v.d1, w0 + v.d2, 'BOOKED', 'EXTERNAL', v.ref, v.name
  from (values
    ('BK-4471', 'Visiting assessors', '104',  'b',  2,  9),
    ('BK-4519', 'Regional team',      'B101', 'a',  3, 10),
    ('BK-4502', 'Contractor',         '202',  'a', 16, 23),
    ('BK-4530', 'Regional team',      'B101', 'a', 22, 25)   -- clashes with the Block B floor outage
  ) v(ref, name, room, bed, d1, d2)
  join core.rooms r on r.tenant_id = p_tenant_id and r.code = v.room
  join core.beds b  on b.room_id = r.room_id and b.code = v.bed;

  -- Statuses from where each stay falls relative to today.
  update core.allocations set
    status = 'CHECKED_OUT', checked_in_at = start_date + time '15:00', checked_out_at = end_date + time '10:00'
  where tenant_id = p_tenant_id and end_date <= current_date;

  update core.allocations set
    status = 'CHECKED_IN', checked_in_at = start_date + time '15:00'
  where tenant_id = p_tenant_id and start_date <= current_date and end_date > current_date;

  -- One past no-show, for the check-in/out exceptions view.
  update core.allocations a set status = 'NO_SHOW', checked_in_at = null, checked_out_at = null
  from core.courses c
  where a.tenant_id = p_tenant_id and c.course_id = a.course_id
    and c.code = 'SAF-14' and a.individual_no = 6 and a.end_date <= current_date;

  perform set_config('app.tenant_id', coalesce(v_prev, ''), true);
end
$$;

reset role;
