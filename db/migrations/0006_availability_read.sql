-- migrate:up
--------------------------------------------------------------------------------
-- 0006: read API for the availability page (phase 1; spec in
-- claude_availability_page_overview.md, decisions D9-D14, D28).
--
--   api.locations            the tree: site > building > block > floor > room > bed
--   api.course_figures       scheduled, loaded, allocated per course
--   api.fn_bed_bars          allocations, external bookings, outages per bed in a range
--   api.fn_week_summary      collapsed rows: counts by state on each week's busiest night
--   api.warnings             loaded > scheduled, bookings on outages, double bookings
--   api.fn_check_allocation  clashes for a proposed allocation, before saving
--
-- Helpers (not endpoints): core.v_bed_path, core.v_bed_outages.
-- Rule warnings (gender, grade, step-free, work pattern) come in a later migration.
--------------------------------------------------------------------------------
set local role app_owner;

-- ================================ Helpers ===============================

-- Every bed with its ancestors (one row per bed).
create view core.v_bed_path as
select b.tenant_id, b.bed_id, b.code as bed_code,
       r.room_id, r.code as room_code, r.name as room_name,
       f.floor_id, f.name as floor_name,
       bl.block_id, bl.name as block_name,
       bu.building_id, bu.name as building_name,
       s.site_id, s.name as site_name
from core.beds b
join core.rooms r      on r.room_id = b.room_id
join core.floors f     on f.floor_id = r.floor_id
join core.blocks bl    on bl.block_id = f.block_id
join core.buildings bu on bu.building_id = bl.building_id
join core.sites s      on s.site_id = bu.site_id;

comment on view core.v_bed_path is
  'Every bed with its room, floor, block, building and site.';

-- Outages that apply to each bed: OUT_OF_ACTION = Y set on the bed or any level
-- above it (outages inherit down; attribute type ANY).
create view core.v_bed_outages as
select bp.tenant_id, bp.bed_id, la.loc_attr_id as outage_id, la.valid_from, la.valid_to,
       la.comments as reason,
       case when la.bed_id is not null then 'Bed' when la.room_id is not null then 'Room'
            when la.floor_id is not null then 'Floor' when la.block_id is not null then 'Block'
            when la.building_id is not null then 'Building' else 'Site' end as set_on_level
from core.v_bed_path bp
join core.location_attributes la
  on la.tenant_id = bp.tenant_id
 and la.attr_code = 'OUT_OF_ACTION' and la.attr_value = 'Y'
 and (la.bed_id = bp.bed_id or la.room_id = bp.room_id or la.floor_id = bp.floor_id
      or la.block_id = bp.block_id or la.building_id = bp.building_id or la.site_id = bp.site_id);

comment on view core.v_bed_outages is
  'Out-of-action periods that apply to each bed, wherever they were set (valid_to exclusive).';

-- ============================== 1. The tree =============================

create view api.locations as
with bed_counts as (
  select site_id, building_id, block_id, floor_id, room_id, bed_id from core.v_bed_path
)
select 'site:' || s.site_id as key, null::text as parent_key, 'Site' as level, s.site_id as id,
       s.name::text as name, s.sort_order,
       (select count(*) from bed_counts c where c.site_id = s.site_id) as bed_count
from core.sites s
union all
select 'building:' || b.building_id, 'site:' || b.site_id, 'Building', b.building_id,
       b.name::text, b.sort_order,
       (select count(*) from bed_counts c where c.building_id = b.building_id)
from core.buildings b
union all
select 'block:' || b.block_id, 'building:' || b.building_id, 'Block', b.block_id,
       b.name::text, b.sort_order,
       (select count(*) from bed_counts c where c.block_id = b.block_id)
from core.blocks b
union all
select 'floor:' || f.floor_id, 'block:' || f.block_id, 'Floor', f.floor_id,
       f.name::text, f.sort_order,
       (select count(*) from bed_counts c where c.floor_id = f.floor_id)
from core.floors f
union all
select 'room:' || r.room_id, 'floor:' || r.floor_id, 'Room', r.room_id,
       r.name::text, r.sort_order,
       (select count(*) from bed_counts c where c.room_id = r.room_id)
from core.rooms r
union all
select 'bed:' || b.bed_id, 'room:' || b.room_id, 'Bed', b.bed_id,
       'Bed ' || upper(b.code), (row_number() over (partition by b.room_id order by b.code))::integer,
       1
from core.beds b;

comment on view api.locations is
  'The estate as a tree: one row per site, building, block, floor, room and bed. key is unique '
  '(e.g. "room:12"), parent_key points to the row above, sort_order orders siblings, '
  'bed_count is the number of beds at or below.';

-- ======================= 2. Course figures (D12, D13) ===================

create view api.course_figures as
select c.course_id, c.code::text as code, c.name::text as name, c.start_date, c.end_date,
       c.status::text as status, c.scheduled, c.loaded, c.loaded_at,
       count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') as allocated,
       c.loaded > c.scheduled as loaded_above_scheduled
from core.courses c
left join core.allocations a on a.course_id = c.course_id
group by c.course_id;

comment on view api.course_figures is
  'Per course: scheduled (planned), loaded (registered, as of loaded_at) and allocated '
  '(individuals with a bed, not cancelled). The UI colours courses by allocated against '
  'scheduled or loaded (D13).';

-- ========================== 3. Bars per bed =============================

create function api.fn_bed_bars(p_from date, p_to date)
returns table (bed_id integer, kind text, id integer, start_date date, end_date date,
               course_id integer, course_code text, individual_no integer,
               external_ref text, external_name text, status text,
               set_on_level text, reason text, on_outage boolean)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := core.current_tenant_id();
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;

  return query
  select a.bed_id,
         case when a.course_id is null then 'external' else 'allocation' end,
         a.allocation_id, greatest(a.start_date, p_from), least(a.end_date, p_to),
         a.course_id, c.code::text, a.individual_no, a.external_ref::text, a.external_name::text,
         a.status::text, null::text, null::text,
         exists (select 1 from core.v_bed_outages o
                  where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.tenant_id = v_tenant
    and a.status <> 'CANCELLED' and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'outage', o.outage_id, greatest(o.valid_from, p_from), least(o.valid_to, p_to),
         null, null, null, null, null, null, o.set_on_level, o.reason::text, null
  from core.v_bed_outages o
  where o.tenant_id = v_tenant
    and o.valid_from < p_to and p_from < o.valid_to
  order by 1, 4, 2;
end
$$;

comment on function api.fn_bed_bars(date, date) is
  'Bars for every bed between p_from and p_to (exclusive): kind allocation, external or '
  'outage, with dates clipped to the range. on_outage flags a booking that falls on an '
  'out-of-action bed.';

-- ===================== 4. Collapsed rows (D28) ==========================

create function api.fn_week_summary(p_from date, p_weeks integer,
                                    p_basis text default 'scheduled',
                                    p_green_at numeric default 100,
                                    p_red_below numeric default 80)
returns table (key text, week_start date, busiest_night date,
               free bigint, out_of_action bigint, green bigint, amber bigint, red bigint,
               external bigint)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := core.current_tenant_id();
begin
  if p_from is null then
    raise exception 'p_from is required' using errcode = 'P0001';
  end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 52 then
    raise exception 'p_weeks must be between 1 and 52' using errcode = 'P0001';
  end if;
  if p_basis is null or p_basis not in ('scheduled', 'loaded') then
    raise exception 'p_basis must be scheduled or loaded' using errcode = 'P0001';
  end if;
  if p_green_at is null or p_red_below is null or p_red_below > p_green_at then
    raise exception 'p_red_below must not be above p_green_at' using errcode = 'P0001';
  end if;

  return query
  with nights as (
    select (p_from + n)::date as night from generate_series(0, p_weeks * 7 - 1) n
  ), course_colour as (
    select x.course_id,
           case when x.basis = 0 or x.allocated * 100.0 / x.basis >= p_green_at then 'green'
                when x.allocated * 100.0 / x.basis < p_red_below then 'red'
                else 'amber' end as colour
    from (select cf.course_id, cf.allocated,
                 case when p_basis = 'loaded' then cf.loaded else cf.scheduled end as basis
          from api.course_figures cf) x
  ), bed_night as (
    select bp.*, n.night,
           case
             when exists (select 1 from core.v_bed_outages o
                           where o.bed_id = bp.bed_id and o.valid_from <= n.night and n.night < o.valid_to)
               then 'out'
             else coalesce((select case when a.course_id is null then 'external' else cc.colour end
                              from core.allocations a
                              left join course_colour cc on cc.course_id = a.course_id
                             where a.bed_id = bp.bed_id and a.status <> 'CANCELLED'
                               and a.start_date <= n.night and n.night < a.end_date
                             order by a.allocation_id limit 1), 'free')
           end as state
    from core.v_bed_path bp cross join nights n
    where bp.tenant_id = v_tenant
  ), per_location as (
    select k.key, bn.night, bn.state
    from bed_night bn
    cross join lateral (values ('site:' || bn.site_id), ('building:' || bn.building_id),
                               ('block:' || bn.block_id), ('floor:' || bn.floor_id),
                               ('room:' || bn.room_id)) k(key)
  ), counts as (
    select pl.key, pl.night, p_from + ((pl.night - p_from) / 7) * 7 as week_start,
           count(*) filter (where pl.state = 'free')     as free,
           count(*) filter (where pl.state = 'out')      as out_of_action,
           count(*) filter (where pl.state = 'green')    as green,
           count(*) filter (where pl.state = 'amber')    as amber,
           count(*) filter (where pl.state = 'red')      as red,
           count(*) filter (where pl.state = 'external') as external
    from per_location pl
    group by pl.key, pl.night
  )
  select distinct on (c.key, c.week_start)
         c.key, c.week_start, c.night, c.free, c.out_of_action, c.green, c.amber, c.red, c.external
  from counts c
  order by c.key, c.week_start, c.free, c.night;
end
$$;

comment on function api.fn_week_summary(date, integer, text, numeric, numeric) is
  'For each location above bed level (key as in api.locations) and each of p_weeks weeks '
  'from p_from: the busiest night (fewest free beds) and its beds by state. Courses are '
  'green at or above p_green_at % of p_basis (scheduled or loaded), red below p_red_below %, '
  'amber between: the user''s view settings (D28).';

-- ======================= 5. Warnings strip (D14) ========================
-- Always shown. Rule warnings (gender, grade, step-free, work pattern) will be
-- further branches. DOUBLE_BOOKING severity stays WARNING until D11 is decided.

create view api.warnings as
select 'LOADED_ABOVE_SCHEDULED'::text as kind, 'WARNING'::text as severity,
       cf.code || ': ' || cf.loaded || ' loaded vs ' || cf.scheduled || ' scheduled' as message,
       cf.course_id, null::integer as allocation_id, null::integer as bed_id,
       cf.start_date, cf.end_date
from api.course_figures cf
where cf.loaded_above_scheduled
union all
select 'OUT_OF_ACTION', r.severity::text,
       coalesce(c.code || ' #' || a.individual_no, a.external_ref) || ' is in an out-of-action bed ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
join core.rules r on r.rule_code = 'OUT_OF_ACTION' and r.active = 'Y'
where a.status <> 'CANCELLED'
  and exists (select 1 from core.v_bed_outages o
               where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
union all
select 'DOUBLE_BOOKING', 'WARNING',
       coalesce(c.code || ' #' || a.individual_no, a.external_ref) || ' is double-booked ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
where a.status <> 'CANCELLED'
  and exists (select 1 from core.allocations b
               where b.bed_id = a.bed_id and b.allocation_id <> a.allocation_id and b.status <> 'CANCELLED'
                 and b.start_date < a.end_date and a.start_date < b.end_date);

comment on view api.warnings is
  'Warnings for the warnings strip, whatever the colour basis: courses with loaded above '
  'scheduled (D14), bookings on out-of-action beds, and double bookings (one row per '
  'booking involved).';

-- ================ 6. Clashes for a new allocation (D11) =================

create function api.fn_check_allocation(p_bed_ids integer[], p_from date, p_to date)
returns table (bed_id integer, kind text, ref text, start_date date, end_date date, message text)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := core.current_tenant_id();
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;

  return query
  select a.bed_id, 'BOOKING'::text,
         coalesce(c.code || ' #' || a.individual_no, a.external_ref)::text,
         a.start_date, a.end_date, 'Already booked for some of these nights'::text
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.tenant_id = v_tenant
    and a.bed_id = any(p_bed_ids) and a.status <> 'CANCELLED'
    and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'OUT_OF_ACTION', o.reason::text, o.valid_from, o.valid_to,
         'Out of action (' || lower(o.set_on_level) || ') for some of these nights'
  from core.v_bed_outages o
  where o.tenant_id = v_tenant
    and o.bed_id = any(p_bed_ids) and o.valid_from < p_to and p_from < o.valid_to
  order by 1, 4;
end
$$;

comment on function api.fn_check_allocation(integer[], date, date) is
  'Clashes for allocating the given beds from p_from to p_to (exclusive), before anything is '
  'saved: existing bookings and outages on those beds. Clashes warn by default (D11).';

reset role;

-- migrate:down
drop function api.fn_check_allocation(integer[], date, date);
drop view api.warnings;
drop function api.fn_week_summary(date, integer, text, numeric, numeric);
drop function api.fn_bed_bars(date, date);
drop view api.course_figures;
drop view api.locations;
drop view core.v_bed_outages;
drop view core.v_bed_path;
