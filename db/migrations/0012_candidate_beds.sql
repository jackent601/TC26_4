-- migrate:up
--------------------------------------------------------------------------------
-- 0012: course-first booking (D34).
--
--   api.fn_candidate_beds(p_course_id, p_from, p_to, p_beds)
--       Every bed a course could be booked into for some nights, with whether
--       it is free, the clashes the active rules would raise, and a ranked
--       suggestion of p_beds beds. The booking itself still goes through
--       api.fn_allocate_course, so the suggestion only advises (D18, D26).
--   api_internal.candidate_bed_facts   the per-bed facts behind it (not an endpoint)
--
-- Candidates are every bed on the course's site (every bed when the course
-- has no site). A bed is free when no booking (not cancelled) and no outage
-- overlap the nights, whatever the clash rules say; warnings lists the clashes
-- the active rules would raise, worded as the write path words them, and
-- blocks says whether one of them has severity BLOCK.
--
-- Suggestion (greedy and deterministic; an optimiser may replace it behind the
-- same function later, D18): free beds only. Rooms are visited with those
-- where the course already has a bed on these nights first, then the most free
-- beds, then estate order. A room is taken whole while its free beds fit in
-- what is still needed. If something is still needed after that, the smallest
-- room that can hold it is split. Suggested beds carry their rank; the rest
-- have none. The facts are worked out per call, more than once; fine at this
-- scale (see the note on fn_week_summary in the availability spec).
--------------------------------------------------------------------------------
set local role app_owner;

create function api_internal.candidate_bed_facts(p_course_id integer, p_from date, p_to date)
returns table (bed_id integer, bed_code text, room_id integer, room_name text, floor_name text,
               block_name text, building_name text, site_name text, sort_key integer[],
               free boolean, course_in_room boolean, warnings text[], blocks boolean)
language sql stable
set search_path = pg_catalog, core
as $$
  with course as (
    select c.site_id from core.courses c
    where c.course_id = p_course_id and c.tenant_id = core.current_tenant_id()
  ), sev as (
    select (select ru.severity from core.rules ru
             where ru.tenant_id = core.current_tenant_id() and ru.rule_code = 'DOUBLE_BOOKING' and ru.active = 'Y') as double_sev,
           (select ru.severity from core.rules ru
             where ru.tenant_id = core.current_tenant_id() and ru.rule_code = 'OUT_OF_ACTION' and ru.active = 'Y') as out_sev
  ), beds as (
    select bp.bed_id, bp.bed_code::text as bed_code, bp.room_id, bp.room_name::text as room_name,
           bp.floor_name::text as floor_name, bp.block_name::text as block_name,
           bp.building_name::text as building_name, bp.site_name::text as site_name,
           array[s.sort_order, s.site_id, bu.sort_order, bu.building_id, bl.sort_order, bl.block_id,
                 f.sort_order, f.floor_id, r.sort_order, r.room_id] as sort_key
    from core.v_bed_path bp
    join core.sites s      on s.site_id = bp.site_id
    join core.buildings bu on bu.building_id = bp.building_id
    join core.blocks bl    on bl.block_id = bp.block_id
    join core.floors f     on f.floor_id = bp.floor_id
    join core.rooms r      on r.room_id = bp.room_id
    cross join course c
    where bp.tenant_id = core.current_tenant_id()
      and (c.site_id is null or bp.site_id = c.site_id)
  ), bookings as (
    select a.bed_id, a.start_date, a.end_date, a.course_id, coalesce(c.code, a.external_ref)::text as ref
    from core.allocations a
    left join core.courses c on c.course_id = a.course_id
    where a.tenant_id = core.current_tenant_id()
      and a.status <> 'CANCELLED' and a.start_date < p_to and p_from < a.end_date
  ), outages as (
    select o.bed_id, o.valid_from, o.valid_to, o.reason, o.set_on_level
    from core.v_bed_outages o
    where o.tenant_id = core.current_tenant_id()
      and o.valid_from < p_to and p_from < o.valid_to
  ), clash as (
    -- One row per clash an active rule would raise, with its severity.
    select b.bed_id, x.msg, x.d, x.blocks
    from beds b
    join lateral (
      select format('Already booked (%s, %s to %s)', k.ref,
                    to_char(k.start_date, 'DD/MM'), to_char(k.end_date, 'DD/MM')) as msg,
             k.start_date as d, sev.double_sev = 'BLOCK' as blocks
      from bookings k, sev
      where k.bed_id = b.bed_id and sev.double_sev is not null
      union all
      select format('Out of action (%s, set on the %s, %s to %s)', coalesce(o.reason, 'no reason given'),
                    lower(o.set_on_level), to_char(o.valid_from, 'DD/MM'), to_char(o.valid_to, 'DD/MM')),
             o.valid_from, sev.out_sev = 'BLOCK'
      from outages o, sev
      where o.bed_id = b.bed_id and sev.out_sev is not null
    ) x on true
  )
  select b.bed_id, b.bed_code, b.room_id, b.room_name, b.floor_name, b.block_name, b.building_name, b.site_name,
         b.sort_key,
         not exists (select 1 from bookings k where k.bed_id = b.bed_id)
           and not exists (select 1 from outages o where o.bed_id = b.bed_id) as free,
         exists (select 1 from bookings k
                 join core.v_bed_path kp on kp.bed_id = k.bed_id
                 where kp.room_id = b.room_id and k.course_id = p_course_id) as course_in_room,
         coalesce((select array_agg(cl.msg order by cl.d, cl.msg) from clash cl where cl.bed_id = b.bed_id),
                  '{}'::text[]) as warnings,
         coalesce((select bool_or(cl.blocks) from clash cl where cl.bed_id = b.bed_id), false) as blocks
  from beds b
$$;

create function api.fn_candidate_beds(p_course_id integer, p_from date, p_to date, p_beds integer default null)
returns table (bed_id integer, bed_name text, room_id integer, room_name text, floor_name text,
               block_name text, building_name text, site_name text,
               free boolean, course_in_room boolean, warnings text[], blocks boolean,
               rank integer, suggested boolean)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant    integer := core.current_tenant_id();
  v_remaining integer := coalesce(p_beds, 0);
  v_rooms     integer[] := '{}';   -- rooms to suggest from, in order
  v_takes     integer[] := '{}';   -- how many beds from each
  v_split     integer;
  rm          record;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if p_beds is not null and p_beds < 0 then
    raise exception 'p_beds must not be negative' using errcode = 'P0001';
  end if;
  if not exists (select 1 from core.courses c where c.course_id = p_course_id and c.tenant_id = v_tenant) then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;

  -- Greedy choice of rooms (see the header).
  if v_remaining > 0 then
    for rm in
      select f.room_id, (count(*) filter (where f.free))::integer as free_beds
      from api_internal.candidate_bed_facts(p_course_id, p_from, p_to) f
      group by f.room_id
      having count(*) filter (where f.free) > 0
      order by bool_or(f.course_in_room) desc, count(*) filter (where f.free) desc, min(f.sort_key)
    loop
      exit when v_remaining = 0;
      if rm.free_beds <= v_remaining then
        v_rooms := v_rooms || rm.room_id;
        v_takes := v_takes || rm.free_beds;
        v_remaining := v_remaining - rm.free_beds;
      end if;
    end loop;

    if v_remaining > 0 then
      -- No whole room fits what is left: split the smallest room that can hold it.
      select x.room_id into v_split
      from (select f.room_id, count(*) filter (where f.free) as free_beds, min(f.sort_key) as sort_key
            from api_internal.candidate_bed_facts(p_course_id, p_from, p_to) f
            group by f.room_id) x
      where x.room_id <> all(v_rooms) and x.free_beds > v_remaining
      order by x.free_beds, x.sort_key
      limit 1;
      if v_split is not null then
        v_rooms := v_rooms || v_split;
        v_takes := v_takes || v_remaining;
        v_remaining := 0;
      end if;
    end if;
  end if;

  return query
  select f.bed_id, 'Bed ' || upper(f.bed_code), f.room_id, f.room_name, f.floor_name, f.block_name,
         f.building_name, f.site_name, f.free, f.course_in_room, f.warnings, f.blocks,
         s.rnk::integer, s.rnk is not null
  from api_internal.candidate_bed_facts(p_course_id, p_from, p_to) f
  left join (
    select g.bed_id, row_number() over (order by array_position(v_rooms, g.room_id), g.bed_code) as rnk
    from (select x.bed_id, x.room_id, x.bed_code,
                 row_number() over (partition by x.room_id order by x.bed_code) as n
          from api_internal.candidate_bed_facts(p_course_id, p_from, p_to) x
          where x.free and x.room_id = any(v_rooms)) g
    where g.n <= v_takes[array_position(v_rooms, g.room_id)]
  ) s on s.bed_id = f.bed_id
  order by f.sort_key, f.bed_code;
end
$$;

comment on function api.fn_candidate_beds(integer, date, date, integer) is
  'Beds a course could be booked into from p_from (first night) to p_to (departure day): every bed on '
  'the course''s site (all beds when it has none), in estate order. free: no booking or outage on those '
  'nights. warnings: the clashes the active rules would raise; blocks: one of them is BLOCK, so '
  'fn_allocate_course would refuse. course_in_room: the course already has a bed in that room on those '
  'nights. Given p_beds, that many free beds are suggested (suggested, rank), keeping the course together '
  'and filling rooms (D34); fewer when not enough are free. Book them with fn_allocate_course.';

reset role;

-- migrate:down
set local role app_owner;
drop function api.fn_candidate_beds(integer, date, date, integer);
drop function api_internal.candidate_bed_facts(integer, date, date);
reset role;
