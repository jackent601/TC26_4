-- migrate:up
--------------------------------------------------------------------------------
-- 0007: the database returns facts, the UI applies display bands (D29).
--
--   api.course_figures   + pct_scheduled, pct_loaded (allocated as a % of each
--                        basis; null when that basis is 0)
--   api.fn_week_summary  now (p_from, p_weeks): no basis or thresholds. One row
--                        per location, week and category of the busiest night,
--                        with beds per course, so the UI can band courses itself.
--
-- The busiest night (fewest free beds) depends only on free beds, so it is the
-- same whatever the basis or thresholds.
--------------------------------------------------------------------------------
set local role app_owner;

-- New columns go last, so the view can be replaced in place (api.warnings
-- depends on it).
create or replace view api.course_figures as
select c.course_id, c.code::text as code, c.name::text as name, c.start_date, c.end_date,
       c.status::text as status, c.scheduled, c.loaded, c.loaded_at,
       count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') as allocated,
       c.loaded > c.scheduled as loaded_above_scheduled,
       round(count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') * 100.0
             / nullif(c.scheduled, 0), 1) as pct_scheduled,
       round(count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') * 100.0
             / nullif(c.loaded, 0), 1) as pct_loaded
from core.courses c
left join core.allocations a on a.course_id = c.course_id
group by c.course_id;

comment on view api.course_figures is
  'Per course: scheduled (planned), loaded (registered, as of loaded_at) and allocated '
  '(individuals with a bed, not cancelled). pct_scheduled and pct_loaded are allocated as a '
  'percentage of each, to 1 decimal place, null when that figure is 0. Colour bands are '
  'applied by the UI from the user''s thresholds (D29).';

drop function api.fn_week_summary(date, integer, text, numeric, numeric);

create function api.fn_week_summary(p_from date, p_weeks integer)
returns table (key text, week_start date, busiest_night date,
               category text, course_id integer, beds bigint)
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

  return query
  with nights as (
    select (p_from + n)::date as night from generate_series(0, p_weeks * 7 - 1) n
  ), bed_night as (
    -- Each bed on each night: out of action, or its first booking, or free.
    select bp.site_id, bp.building_id, bp.block_id, bp.floor_id, bp.room_id, n.night,
           exists (select 1 from core.v_bed_outages o
                    where o.bed_id = bp.bed_id and o.valid_from <= n.night and n.night < o.valid_to) as is_out,
           a.allocation_id, a.course_id
    from core.v_bed_path bp
    cross join nights n
    left join lateral (
      select x.allocation_id, x.course_id from core.allocations x
       where x.tenant_id = v_tenant and x.bed_id = bp.bed_id and x.status <> 'CANCELLED'
         and x.start_date <= n.night and n.night < x.end_date
       order by x.allocation_id limit 1) a on true
    where bp.tenant_id = v_tenant
  ), per_location as (
    select k.key, bn.night,
           case when bn.is_out then 'out_of_action' when bn.allocation_id is null then 'free'
                when bn.course_id is null then 'external' else 'course' end as category,
           case when not bn.is_out then bn.course_id end as course_id
    from bed_night bn
    cross join lateral (values ('site:' || bn.site_id), ('building:' || bn.building_id),
                               ('block:' || bn.block_id), ('floor:' || bn.floor_id),
                               ('room:' || bn.room_id)) k(key)
  ), busiest as (
    select distinct on (f.key, f.week_start) f.key, f.week_start, f.night
    from (select pl.key, pl.night, p_from + ((pl.night - p_from) / 7) * 7 as week_start,
                 count(*) filter (where pl.category = 'free') as free
          from per_location pl
          group by pl.key, pl.night) f
    order by f.key, f.week_start, f.free, f.night
  )
  select b.key, b.week_start, b.night, pl.category, pl.course_id, count(*)
  from busiest b
  join per_location pl on pl.key = b.key and pl.night = b.night
  group by b.key, b.week_start, b.night, pl.category, pl.course_id
  order by 1, 2, 4, 5;
end
$$;

comment on function api.fn_week_summary(date, integer) is
  'For each location above bed level (key as in api.locations) and each of p_weeks weeks '
  'from p_from: the busiest night (fewest free beds, earliest on a tie) and its beds by '
  'category: free, out_of_action, external, or course (one row per course_id). Categories '
  'with no beds are left out. The UI bands courses by colour from api.course_figures (D29).';

reset role;

-- migrate:down
-- Back to 0006: course_figures without the percentages (api.warnings depends on
-- it, so both are recreated), and fn_week_summary with basis and thresholds.
set local role app_owner;

drop function api.fn_week_summary(date, integer);
drop view api.warnings;
drop view api.course_figures;

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

reset role;
