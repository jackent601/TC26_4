-- migrate:up
--------------------------------------------------------------------------------
-- 0018: api.fn_check_allocation can leave out one booking (p_exclude_allocation),
-- so moving a booking can be checked before it is saved without the booking
-- clashing with itself. Used when a booking is dragged on the availability
-- grid; api.fn_move_allocation already leaves it out when saving.
--------------------------------------------------------------------------------
set local role app_owner;

-- New parameter, so the function is replaced, not altered.
drop function api.fn_check_allocation(integer[], date, date, integer);

create function api.fn_check_allocation(p_bed_ids integer[], p_from date, p_to date,
                                         p_course_id integer default null, p_exclude_allocation integer default null)
returns table (bed_id integer, kind text, ref text, start_date date, end_date date, message text, blocks boolean)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := core.current_tenant_id();
  v_double text;
  v_out text;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  select r.severity into v_double from core.rules r
   where r.tenant_id = v_tenant and r.rule_code = 'DOUBLE_BOOKING' and r.active = 'Y';
  select r.severity into v_out from core.rules r
   where r.tenant_id = v_tenant and r.rule_code = 'OUT_OF_ACTION' and r.active = 'Y';

  return query
  select a.bed_id, 'BOOKING'::text,
         coalesce(c.code, a.external_ref)::text,
         a.start_date, a.end_date, 'Already booked for some of these nights'::text,
         coalesce(v_double = 'BLOCK', false)
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.tenant_id = v_tenant
    and a.bed_id = any(p_bed_ids) and a.status <> 'CANCELLED'
    and a.allocation_id is distinct from p_exclude_allocation   -- the booking being moved (0018)
    and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'OUT_OF_ACTION', o.reason::text, o.valid_from, o.valid_to,
         'Out of action (' || lower(o.set_on_level) || ') for some of these nights',
         coalesce(v_out = 'BLOCK', false)
  from core.v_bed_outages o
  where o.tenant_id = v_tenant
    and o.bed_id = any(p_bed_ids) and o.valid_from < p_to and p_from < o.valid_to
  union all
  -- With a course: whether these nights go outside its dates (strict, 0010).
  select null::integer, 'COURSE_DATES', c.code::text, c.start_date, c.end_date,
         'Outside the course dates (' || to_char(c.start_date, 'DD/MM') || ' to '
           || to_char(c.end_date, 'DD/MM') || ')',
         false
  from core.courses c
  where p_course_id is not null and c.course_id = p_course_id and c.tenant_id = v_tenant
    and (p_from < c.start_date or p_to > c.end_date)
  order by 1, 4;
end
$$;

comment on function api.fn_check_allocation(integer[], date, date, integer, integer) is
  'Clashes for allocating the given beds from p_from to p_to (exclusive), before anything is '
  'saved: existing bookings and outages on those beds. blocks is true when the clash''s rule is '
  'BLOCK, so saving would be refused (D30); otherwise it saves with a warning. Given '
  'p_course_id, also a COURSE_DATES row (bed_id null) when the nights go outside that '
  'course''s dates (0010). Given p_exclude_allocation, that booking is left out, so a move can be '
  'checked before it is made (0018: dragging a booking on the availability grid).';

reset role;

-- migrate:down
set local role app_owner;

drop function api.fn_check_allocation(integer[], date, date, integer, integer);

create function api.fn_check_allocation(p_bed_ids integer[], p_from date, p_to date,
                                         p_course_id integer default null)
returns table (bed_id integer, kind text, ref text, start_date date, end_date date, message text, blocks boolean)
language plpgsql stable security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := core.current_tenant_id();
  v_double text;
  v_out text;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  select r.severity into v_double from core.rules r
   where r.tenant_id = v_tenant and r.rule_code = 'DOUBLE_BOOKING' and r.active = 'Y';
  select r.severity into v_out from core.rules r
   where r.tenant_id = v_tenant and r.rule_code = 'OUT_OF_ACTION' and r.active = 'Y';

  return query
  select a.bed_id, 'BOOKING'::text,
         coalesce(c.code, a.external_ref)::text,
         a.start_date, a.end_date, 'Already booked for some of these nights'::text,
         coalesce(v_double = 'BLOCK', false)
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.tenant_id = v_tenant
    and a.bed_id = any(p_bed_ids) and a.status <> 'CANCELLED'
    and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'OUT_OF_ACTION', o.reason::text, o.valid_from, o.valid_to,
         'Out of action (' || lower(o.set_on_level) || ') for some of these nights',
         coalesce(v_out = 'BLOCK', false)
  from core.v_bed_outages o
  where o.tenant_id = v_tenant
    and o.bed_id = any(p_bed_ids) and o.valid_from < p_to and p_from < o.valid_to
  union all
  -- With a course: whether these nights go outside its dates (strict, 0010).
  select null::integer, 'COURSE_DATES', c.code::text, c.start_date, c.end_date,
         'Outside the course dates (' || to_char(c.start_date, 'DD/MM') || ' to '
           || to_char(c.end_date, 'DD/MM') || ')',
         false
  from core.courses c
  where p_course_id is not null and c.course_id = p_course_id and c.tenant_id = v_tenant
    and (p_from < c.start_date or p_to > c.end_date)
  order by 1, 4;
end
$$;

comment on function api.fn_check_allocation(integer[], date, date, integer) is
  'Clashes for allocating the given beds from p_from to p_to (exclusive), before anything is '
  'saved: existing bookings and outages on those beds. blocks is true when the clash''s rule is '
  'BLOCK, so saving would be refused (D30); otherwise it saves with a warning. Given '
  'p_course_id, also a COURSE_DATES row (bed_id null) when the nights go outside that '
  'course''s dates (0010).';

reset role;
