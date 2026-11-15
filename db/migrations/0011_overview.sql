-- migrate:up
--------------------------------------------------------------------------------
-- 0011: the Overview page.
--
--   api.course_figures   + site_id (the course's site)
--   api.warnings         + site_id (the bed's site, or the course's for
--                        course-level warnings), so warnings filter by site
--   api.fn_weekly_overview(p_from, p_weeks, p_site_ids)
--                        per week: beds in service, and on the week's busiest
--                        night (fewest free beds) how many are allocated to
--                        courses, externally booked or free; plus scheduled and
--                        loaded places of the courses running that week
--------------------------------------------------------------------------------
set local role app_owner;

-- New columns go last, so the views are replaced in place.
create or replace view api.course_figures as
select c.course_id, c.code::text as code, c.name::text as name, c.start_date, c.end_date,
       c.status::text as status, c.scheduled, c.loaded, c.loaded_at,
       count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') as allocated,
       c.loaded > c.scheduled as loaded_above_scheduled,
       round(count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') * 100.0
             / nullif(c.scheduled, 0), 1) as pct_scheduled,
       round(count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') * 100.0
             / nullif(c.loaded, 0), 1) as pct_loaded,
       c.site_id
from core.courses c
left join core.allocations a on a.course_id = c.course_id
group by c.course_id;

comment on view api.course_figures is
  'Per course: scheduled (planned), loaded (registered, as of loaded_at) and allocated '
  '(individuals with a bed, not cancelled). pct_scheduled and pct_loaded are allocated as a '
  'percentage of each, to 1 decimal place, null when that figure is 0. Colour bands are '
  'applied by the UI from the user''s thresholds (D29). site_id is the course''s site (0011).';

create or replace view api.warnings as
select 'LOADED_ABOVE_SCHEDULED'::text as kind, 'WARNING'::text as severity,
       cf.code || ': ' || cf.loaded || ' loaded vs ' || cf.scheduled || ' scheduled' as message,
       cf.course_id, null::integer as allocation_id, null::integer as bed_id,
       cf.start_date, cf.end_date, cf.site_id
from api.course_figures cf
where cf.loaded_above_scheduled
union all
select 'OUT_OF_ACTION', r.severity::text,
       coalesce(c.code, a.external_ref) || ' is in an out-of-action bed ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date, bp.site_id
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
join core.rules r on r.rule_code = 'OUT_OF_ACTION' and r.active = 'Y'
where a.status <> 'CANCELLED'
  and exists (select 1 from core.v_bed_outages o
               where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
union all
select 'DOUBLE_BOOKING', r.severity::text,
       coalesce(c.code, a.external_ref) || ' is double-booked ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date, bp.site_id
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
join core.rules r on r.rule_code = 'DOUBLE_BOOKING' and r.active = 'Y'
where a.status <> 'CANCELLED'
  and exists (select 1 from core.allocations b
               where b.bed_id = a.bed_id and b.allocation_id <> a.allocation_id and b.status <> 'CANCELLED'
                 and b.start_date < a.end_date and a.start_date < b.end_date)
union all
select 'OUTSIDE_COURSE_DATES', 'WARNING',
       c.code || ' booking in ' || bp.room_name || ' bed ' || upper(bp.bed_code)
         || ' is outside the course dates (' || to_char(c.start_date, 'DD/MM') || ' to '
         || to_char(c.end_date, 'DD/MM') || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date, bp.site_id
from core.allocations a
join core.courses c on c.course_id = a.course_id
join core.v_bed_path bp on bp.bed_id = a.bed_id
where a.status <> 'CANCELLED'
  and (a.start_date < c.start_date or a.end_date > c.end_date);

comment on view api.warnings is
  'Warnings for the warnings strip, whatever the colour basis: courses with loaded above '
  'scheduled (D14), bookings on out-of-action beds, double bookings (one row per booking '
  'involved), and course bookings with nights outside their course''s dates (strict, 0010). '
  'Clash severities come from their rules (D30). site_id is the bed''s site, or the course''s for course-level warnings (0011).';

create function api.fn_weekly_overview(p_from date, p_weeks integer, p_site_ids integer[] default null)
returns table (week_start date, busiest_night date, beds_available bigint, allocated bigint,
               external bigint, free bigint, scheduled bigint, loaded bigint, courses bigint)
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
  ), beds as (
    select bp.bed_id from core.v_bed_path bp
    where bp.tenant_id = v_tenant and (p_site_ids is null or bp.site_id = any(p_site_ids))
  ), bed_night as (
    -- Each bed on each night: out of action, or its first booking, or free.
    select n.night,
           exists (select 1 from core.v_bed_outages o
                    where o.bed_id = b.bed_id and o.valid_from <= n.night and n.night < o.valid_to) as is_out,
           a.allocation_id, a.course_id
    from beds b
    cross join nights n
    left join lateral (
      select x.allocation_id, x.course_id from core.allocations x
       where x.tenant_id = v_tenant and x.bed_id = b.bed_id and x.status <> 'CANCELLED'
         and x.start_date <= n.night and n.night < x.end_date
       order by x.allocation_id limit 1) a on true
  ), per_night as (
    -- Bookings on out-of-action beds count as out of action, not as booked.
    select bn.night, p_from + ((bn.night - p_from) / 7) * 7 as week_start,
           count(*) filter (where not bn.is_out) as available,
           count(*) filter (where not bn.is_out and bn.allocation_id is not null and bn.course_id is not null) as allocated,
           count(*) filter (where not bn.is_out and bn.allocation_id is not null and bn.course_id is null) as external,
           count(*) filter (where not bn.is_out and bn.allocation_id is null) as free
    from bed_night bn
    group by bn.night
  ), busiest as (
    select distinct on (pn.week_start) pn.*
    from per_night pn
    order by pn.week_start, pn.free, pn.night
  ), demand as (
    -- Courses running on at least one night of the week (not cancelled).
    select p_from + w * 7 as week_start,
           coalesce(sum(c.scheduled), 0)::bigint as scheduled,
           coalesce(sum(c.loaded), 0)::bigint as loaded,
           count(c.course_id) as courses
    from generate_series(0, p_weeks - 1) w
    left join core.courses c
      on c.tenant_id = v_tenant and c.status <> 'CANCELLED'
     and c.start_date < p_from + w * 7 + 7 and p_from + w * 7 < c.end_date
     and (p_site_ids is null or c.site_id = any(p_site_ids))
    group by w
  )
  select d.week_start, b.night, coalesce(b.available, 0), coalesce(b.allocated, 0),
         coalesce(b.external, 0), coalesce(b.free, 0), d.scheduled, d.loaded, d.courses
  from demand d
  left join busiest b on b.week_start = d.week_start
  order by d.week_start;
end
$$;

comment on function api.fn_weekly_overview(date, integer, integer[]) is
  'One row per week from p_from (p_weeks weeks), for beds in the given sites (all when '
  'p_site_ids is null). beds_available: beds not out of action on the week''s busiest night '
  '(fewest free beds, earliest on a tie), split into allocated (course bookings), external and '
  'free. scheduled and loaded: totals for courses running on at least one night of the week.';

reset role;

-- migrate:down
-- Back to 0010: views without site_id (api.warnings depends on
-- api.course_figures, so both are recreated).
set local role app_owner;

drop function api.fn_weekly_overview(date, integer, integer[]);
drop view api.warnings;
drop view api.course_figures;

create view api.course_figures as
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

create view api.warnings as
select 'LOADED_ABOVE_SCHEDULED'::text as kind, 'WARNING'::text as severity,
       cf.code || ': ' || cf.loaded || ' loaded vs ' || cf.scheduled || ' scheduled' as message,
       cf.course_id, null::integer as allocation_id, null::integer as bed_id,
       cf.start_date, cf.end_date
from api.course_figures cf
where cf.loaded_above_scheduled
union all
select 'OUT_OF_ACTION', r.severity::text,
       coalesce(c.code, a.external_ref) || ' is in an out-of-action bed ('
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
select 'DOUBLE_BOOKING', r.severity::text,
       coalesce(c.code, a.external_ref) || ' is double-booked ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
join core.rules r on r.rule_code = 'DOUBLE_BOOKING' and r.active = 'Y'
where a.status <> 'CANCELLED'
  and exists (select 1 from core.allocations b
               where b.bed_id = a.bed_id and b.allocation_id <> a.allocation_id and b.status <> 'CANCELLED'
                 and b.start_date < a.end_date and a.start_date < b.end_date)
union all
select 'OUTSIDE_COURSE_DATES', 'WARNING',
       c.code || ' booking in ' || bp.room_name || ' bed ' || upper(bp.bed_code)
         || ' is outside the course dates (' || to_char(c.start_date, 'DD/MM') || ' to '
         || to_char(c.end_date, 'DD/MM') || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.courses c on c.course_id = a.course_id
join core.v_bed_path bp on bp.bed_id = a.bed_id
where a.status <> 'CANCELLED'
  and (a.start_date < c.start_date or a.end_date > c.end_date);

comment on view api.warnings is
  'Warnings for the warnings strip, whatever the colour basis: courses with loaded above '
  'scheduled (D14), bookings on out-of-action beds, double bookings (one row per booking '
  'involved), and course bookings with nights outside their course''s dates (strict, 0010). '
  'Clash severities come from their rules (D30).';

reset role;
