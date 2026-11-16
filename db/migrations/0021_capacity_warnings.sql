-- migrate:up
--------------------------------------------------------------------------------
-- 0021: warnings when a site's demand exceeds its beds in service (D40).
--
--   core.v_site_nights  per site and night on which a course runs there:
--                       scheduled and loaded places of the courses running,
--                       external bookings, and beds in service (not out of
--                       action)
--   api.warnings        + SCHEDULED_OVER_CAPACITY: scheduled places + external
--                         bookings > beds in service (expected demand)
--                       + LOADED_OVER_CAPACITY: loaded places + external
--                         bookings > beds in service (demand)
--
-- One warning per site and run of consecutive nights, with the worst night's
-- figures. Courses with no site are left out (no site's beds to compare with).
-- Fixed at WARNING, like "loaded above scheduled": demand never blocks saving.
-- More beds booked than in service needs a booking on an out-of-action bed or a
-- double booking, which already warn per booking, so it has no warning here.
--------------------------------------------------------------------------------
set local role app_owner;

create view core.v_site_nights as
with nights as (
  -- Every night some (not cancelled) course with a site runs there.
  select distinct c.tenant_id, c.site_id, d::date as night
  from core.courses c
  cross join lateral generate_series(c.start_date::timestamp, (c.end_date - 1)::timestamp, interval '1 day') d
  where c.site_id is not null and c.status <> 'CANCELLED'
)
select n.tenant_id, n.site_id, n.night,
       (select coalesce(sum(c.scheduled), 0) from core.courses c
         where c.tenant_id = n.tenant_id and c.site_id = n.site_id and c.status <> 'CANCELLED'
           and c.start_date <= n.night and n.night < c.end_date)::integer as scheduled,
       (select coalesce(sum(c.loaded), 0) from core.courses c
         where c.tenant_id = n.tenant_id and c.site_id = n.site_id and c.status <> 'CANCELLED'
           and c.start_date <= n.night and n.night < c.end_date)::integer as loaded,
       (select count(*) from core.allocations a join core.v_bed_path bp on bp.bed_id = a.bed_id
         where a.tenant_id = n.tenant_id and bp.site_id = n.site_id and a.course_id is null
           and a.status <> 'CANCELLED' and a.start_date <= n.night and n.night < a.end_date)::integer as external,
       (select count(*) from core.v_bed_path bp
         where bp.tenant_id = n.tenant_id and bp.site_id = n.site_id
           and not exists (select 1 from core.v_bed_outages o
                            where o.bed_id = bp.bed_id and o.valid_from <= n.night and n.night < o.valid_to))::integer as in_service
from nights n;

comment on view core.v_site_nights is
  'Per site and night on which a course with that site runs (0021): scheduled and loaded places of the '
  'courses running, external bookings at the site, and beds in service (not out of action).';

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
  and (a.start_date < c.start_date or a.end_date > c.end_date)
union all
-- Demand above beds in service (0021, D40): one row per site, kind and run of nights.
select g.kind, 'WARNING',
       format('%s: %s and external bookings exceed beds in service on %s %s from %s (up to %s for %s beds)',
              s.name, g.what, g.nights, case when g.nights = 1 then 'night' else 'nights' end,
              to_char(g.first_night, 'DD/MM'), g.peak_demand, g.peak_beds),
       null::integer, null::integer, null::integer, g.first_night, g.last_night + 1, g.site_id
from (
  with over as (
    select sn.tenant_id, sn.site_id, sn.night, sn.in_service, k.kind, k.what, k.demand
    from core.v_site_nights sn
    cross join lateral (values ('SCHEDULED_OVER_CAPACITY', 'scheduled places', sn.scheduled + sn.external),
                               ('LOADED_OVER_CAPACITY', 'loaded places', sn.loaded + sn.external)) k(kind, what, demand)
    where k.demand > sn.in_service
  ), runs as (
    -- Consecutive nights share night minus their position.
    select o.*, o.night - (row_number() over (partition by o.tenant_id, o.site_id, o.kind order by o.night))::integer as run
    from over o
  )
  select r.site_id, r.kind, r.what, min(r.night) as first_night, max(r.night) as last_night, count(*) as nights,
         (array_agg(r.demand order by r.demand - r.in_service desc, r.night))[1] as peak_demand,
         (array_agg(r.in_service order by r.demand - r.in_service desc, r.night))[1] as peak_beds
  from runs r
  group by r.tenant_id, r.site_id, r.kind, r.what, r.run
) g
join core.sites s on s.site_id = g.site_id;

comment on view api.warnings is
  'Warnings for the warnings strip, whatever the colour basis: courses with loaded above '
  'scheduled (D14), bookings on out-of-action beds, double bookings (one row per booking '
  'involved), course bookings with nights outside their course''s dates (strict, 0010), and '
  'sites whose scheduled or loaded places plus external bookings exceed their beds in service '
  '(SCHEDULED_OVER_CAPACITY, LOADED_OVER_CAPACITY: one row per run of nights, end_date the day after '
  'the last; 0021, D40). Clash severities come from their rules (D30). site_id is the bed''s site, '
  'or the course''s for course-level warnings (0011), or the site''s.';

reset role;

-- migrate:down
set local role app_owner;

-- 0011's view.
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

drop view core.v_site_nights;

reset role;
