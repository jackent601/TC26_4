-- migrate:up
--------------------------------------------------------------------------------
-- 0010: warn when a course booking has nights outside its course's dates.
-- Strict, with no allowance: a first night before the course's start or a
-- departure after its end warns (allowance parked; README "Known
-- limitations"). Fixed at WARNING, like "loaded above scheduled": not a rule.
--
--   api_internal.course_dates_warning  the check, used by everything below
--   api.warnings                       + OUTSIDE_COURSE_DATES
--   api.fn_allocate_course             + the warning in what it returns
--   api.fn_move_allocation             + the warning in what it returns
--   api.fn_check_allocation            + optional p_course_id: a COURSE_DATES
--                                        row before saving
--------------------------------------------------------------------------------
set local role app_owner;

-- The warning text when p_from..p_to (departure exclusive) goes outside the
-- course's dates; null when it doesn't.
create function api_internal.course_dates_warning(p_course_id integer, p_from date, p_to date)
returns text
language sql stable
set search_path = pg_catalog, core
as $$
  select format('Outside the course dates: %s runs %s to %s', c.code,
                to_char(c.start_date, 'DD/MM'), to_char(c.end_date, 'DD/MM'))
  from core.courses c
  where c.course_id = p_course_id and c.tenant_id = core.current_tenant_id()
    and (p_from < c.start_date or p_to > c.end_date)
$$;

create or replace function api.fn_allocate_course(p_course_id integer, p_bed_ids integer[], p_from date, p_to date)
returns table (allocation_id integer, bed_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_status text;
  v_bed integer;
  v_ind integer;
  v_id integer;
  v_warn text[];
  v_dates text;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if p_bed_ids is null or cardinality(p_bed_ids) = 0 then
    raise exception 'Choose at least one bed' using errcode = 'P0001';
  end if;
  if (select count(distinct b) from unnest(p_bed_ids) b) <> cardinality(p_bed_ids) then
    raise exception 'A bed is listed more than once' using errcode = 'P0001';
  end if;

  select c.status into v_status from core.courses c
   where c.course_id = p_course_id and c.tenant_id = v_tenant;
  if not found then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;
  if v_status = 'CANCELLED' then
    raise exception 'The course is cancelled' using errcode = 'P0001';
  end if;

  -- Nights outside the course dates warn, strictly (0010; no allowance yet).
  v_dates := api_internal.course_dates_warning(p_course_id, p_from, p_to);

  -- Lock the beds, in a fixed order, so two users can't book the same bed at once.
  perform 1 from core.beds b
   where b.tenant_id = v_tenant and b.bed_id = any(p_bed_ids)
   order by b.bed_id for update;
  if (select count(*) from core.beds b where b.tenant_id = v_tenant and b.bed_id = any(p_bed_ids))
     <> cardinality(p_bed_ids) then
    raise exception 'Unknown bed' using errcode = 'P0001';
  end if;

  foreach v_bed in array p_bed_ids loop
    v_warn := api_internal.bed_clashes(v_bed, p_from, p_to);
    if v_dates is not null then
      v_warn := v_warn || v_dates;
    end if;

    -- The course's lowest individual number not already in a bed on these
    -- nights. No upper limit (D31): extra individuals take the course defaults.
    select min(n) into v_ind
      from generate_series(1, (select coalesce(max(x.individual_no), 0) + 1 from core.allocations x
                                where x.tenant_id = v_tenant and x.course_id = p_course_id)) n
     where not exists (select 1 from core.allocations x
                        where x.tenant_id = v_tenant and x.course_id = p_course_id and x.individual_no = n
                          and x.status <> 'CANCELLED' and x.start_date < p_to and p_from < x.end_date);

    insert into core.allocations (course_id, individual_no, bed_id, start_date, end_date, status, source)
    values (p_course_id, v_ind, v_bed, p_from, p_to, 'ALLOCATED', 'LOCAL')
    returning core.allocations.allocation_id into v_id;

    perform api_internal.audit('allocations', v_id, p_course_id, v_ind, 'INSERT',
      jsonb_build_object('bed_id', v_bed, 'start_date', p_from, 'end_date', p_to, 'warnings', v_warn));

    allocation_id := v_id;
    bed_id := v_bed;
    warnings := v_warn;
    return next;
  end loop;
end
$$;

comment on function api.fn_allocate_course(integer, integer[], date, date) is
  'Allocate a course into the given beds from p_from (first night) to p_to (departure day). '
  'One allocation per bed, status ALLOCATED, each given the course''s next free individual '
  '(no upper limit, D31). Clashes warn unless their rule is BLOCK, which refuses the whole '
  'request (D30). Nights outside the course dates warn (0010). Audited. Returns each new allocation with its warnings.';

create or replace function api.fn_move_allocation(p_allocation_id integer, p_bed_id integer default null,
                                       p_from date default null, p_to date default null)
returns table (allocation_id integer, bed_id integer, start_date date, end_date date, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_a core.allocations%rowtype;
  v_bed integer;
  v_from date;
  v_to date;
  v_warn text[];
  v_dates text;
begin
  select * into v_a from core.allocations a
   where a.allocation_id = p_allocation_id and a.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown allocation' using errcode = 'P0001';
  end if;
  if v_a.status = 'CANCELLED' then
    raise exception 'A cancelled allocation can''t be moved' using errcode = 'P0001';
  end if;

  v_bed := coalesce(p_bed_id, v_a.bed_id);
  v_from := coalesce(p_from, v_a.start_date);
  v_to := coalesce(p_to, v_a.end_date);
  if v_to <= v_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if v_bed = v_a.bed_id and v_from = v_a.start_date and v_to = v_a.end_date then
    raise exception 'Nothing to change' using errcode = 'P0001';
  end if;

  perform 1 from core.beds b where b.tenant_id = v_tenant and b.bed_id = v_bed for update;
  if not found then
    raise exception 'Unknown bed' using errcode = 'P0001';
  end if;

  v_warn := api_internal.bed_clashes(v_bed, v_from, v_to, p_allocation_id);
  if v_a.course_id is not null then
    -- Nights outside the course dates warn, strictly (0010).
    v_dates := api_internal.course_dates_warning(v_a.course_id, v_from, v_to);
    if v_dates is not null then
      v_warn := v_warn || v_dates;
    end if;
  end if;

  update core.allocations a
     set bed_id = v_bed, start_date = v_from, end_date = v_to
   where a.allocation_id = p_allocation_id;

  perform api_internal.audit('allocations', p_allocation_id, v_a.course_id, v_a.individual_no, 'MOVE',
    jsonb_build_object('from', jsonb_build_object('bed_id', v_a.bed_id, 'start_date', v_a.start_date, 'end_date', v_a.end_date),
                       'to', jsonb_build_object('bed_id', v_bed, 'start_date', v_from, 'end_date', v_to),
                       'warnings', v_warn));

  allocation_id := p_allocation_id;
  bed_id := v_bed;
  start_date := v_from;
  end_date := v_to;
  warnings := v_warn;
  return next;
end
$$;

comment on function api.fn_move_allocation(integer, integer, date, date) is
  'Move an allocation to another bed and/or other dates (any argument left null stays as it '
  'is). Clashes warn unless their rule is BLOCK (D30); nights outside the course dates warn (0010). Audited. Returns the allocation with its '
  'warnings.';

create or replace view api.warnings as
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

-- New parameter (p_course_id), so the function is replaced, not altered.
drop function api.fn_check_allocation(integer[], date, date);

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

-- migrate:down
-- Back to 0009's versions.
set local role app_owner;

drop function api.fn_check_allocation(integer[], date, date, integer);
create function api.fn_check_allocation(p_bed_ids integer[], p_from date, p_to date)
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
  order by 1, 4;
end
$$;

comment on function api.fn_check_allocation(integer[], date, date) is
  'Clashes for allocating the given beds from p_from to p_to (exclusive), before anything is '
  'saved: existing bookings and outages on those beds. blocks is true when the clash''s rule is '
  'BLOCK, so saving would be refused (D30); otherwise it saves with a warning.';

create or replace view api.warnings as
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
                 and b.start_date < a.end_date and a.start_date < b.end_date);

comment on view api.warnings is
  'Warnings for the warnings strip, whatever the colour basis: courses with loaded above '
  'scheduled (D14), bookings on out-of-action beds, and double bookings (one row per booking '
  'involved). Clash severities come from their rules (D30).';

create or replace function api.fn_allocate_course(p_course_id integer, p_bed_ids integer[], p_from date, p_to date)
returns table (allocation_id integer, bed_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_status text;
  v_bed integer;
  v_ind integer;
  v_id integer;
  v_warn text[];
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if p_bed_ids is null or cardinality(p_bed_ids) = 0 then
    raise exception 'Choose at least one bed' using errcode = 'P0001';
  end if;
  if (select count(distinct b) from unnest(p_bed_ids) b) <> cardinality(p_bed_ids) then
    raise exception 'A bed is listed more than once' using errcode = 'P0001';
  end if;

  select c.status into v_status from core.courses c
   where c.course_id = p_course_id and c.tenant_id = v_tenant;
  if not found then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;
  if v_status = 'CANCELLED' then
    raise exception 'The course is cancelled' using errcode = 'P0001';
  end if;

  -- Lock the beds, in a fixed order, so two users can't book the same bed at once.
  perform 1 from core.beds b
   where b.tenant_id = v_tenant and b.bed_id = any(p_bed_ids)
   order by b.bed_id for update;
  if (select count(*) from core.beds b where b.tenant_id = v_tenant and b.bed_id = any(p_bed_ids))
     <> cardinality(p_bed_ids) then
    raise exception 'Unknown bed' using errcode = 'P0001';
  end if;

  foreach v_bed in array p_bed_ids loop
    v_warn := api_internal.bed_clashes(v_bed, p_from, p_to);

    -- The course's lowest individual number not already in a bed on these
    -- nights. No upper limit (D31): extra individuals take the course defaults.
    select min(n) into v_ind
      from generate_series(1, (select coalesce(max(x.individual_no), 0) + 1 from core.allocations x
                                where x.tenant_id = v_tenant and x.course_id = p_course_id)) n
     where not exists (select 1 from core.allocations x
                        where x.tenant_id = v_tenant and x.course_id = p_course_id and x.individual_no = n
                          and x.status <> 'CANCELLED' and x.start_date < p_to and p_from < x.end_date);

    insert into core.allocations (course_id, individual_no, bed_id, start_date, end_date, status, source)
    values (p_course_id, v_ind, v_bed, p_from, p_to, 'ALLOCATED', 'LOCAL')
    returning core.allocations.allocation_id into v_id;

    perform api_internal.audit('allocations', v_id, p_course_id, v_ind, 'INSERT',
      jsonb_build_object('bed_id', v_bed, 'start_date', p_from, 'end_date', p_to, 'warnings', v_warn));

    allocation_id := v_id;
    bed_id := v_bed;
    warnings := v_warn;
    return next;
  end loop;
end
$$;

comment on function api.fn_allocate_course(integer, integer[], date, date) is
  'Allocate a course into the given beds from p_from (first night) to p_to (departure day). '
  'One allocation per bed, status ALLOCATED, each given the course''s next free individual '
  '(no upper limit, D31). Clashes warn unless their rule is BLOCK, which refuses the whole '
  'request (D30). Audited. Returns each new allocation with its warnings.';

create or replace function api.fn_move_allocation(p_allocation_id integer, p_bed_id integer default null,
                                       p_from date default null, p_to date default null)
returns table (allocation_id integer, bed_id integer, start_date date, end_date date, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_a core.allocations%rowtype;
  v_bed integer;
  v_from date;
  v_to date;
  v_warn text[];
begin
  select * into v_a from core.allocations a
   where a.allocation_id = p_allocation_id and a.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown allocation' using errcode = 'P0001';
  end if;
  if v_a.status = 'CANCELLED' then
    raise exception 'A cancelled allocation can''t be moved' using errcode = 'P0001';
  end if;

  v_bed := coalesce(p_bed_id, v_a.bed_id);
  v_from := coalesce(p_from, v_a.start_date);
  v_to := coalesce(p_to, v_a.end_date);
  if v_to <= v_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if v_bed = v_a.bed_id and v_from = v_a.start_date and v_to = v_a.end_date then
    raise exception 'Nothing to change' using errcode = 'P0001';
  end if;

  perform 1 from core.beds b where b.tenant_id = v_tenant and b.bed_id = v_bed for update;
  if not found then
    raise exception 'Unknown bed' using errcode = 'P0001';
  end if;

  v_warn := api_internal.bed_clashes(v_bed, v_from, v_to, p_allocation_id);

  update core.allocations a
     set bed_id = v_bed, start_date = v_from, end_date = v_to
   where a.allocation_id = p_allocation_id;

  perform api_internal.audit('allocations', p_allocation_id, v_a.course_id, v_a.individual_no, 'MOVE',
    jsonb_build_object('from', jsonb_build_object('bed_id', v_a.bed_id, 'start_date', v_a.start_date, 'end_date', v_a.end_date),
                       'to', jsonb_build_object('bed_id', v_bed, 'start_date', v_from, 'end_date', v_to),
                       'warnings', v_warn));

  allocation_id := p_allocation_id;
  bed_id := v_bed;
  start_date := v_from;
  end_date := v_to;
  warnings := v_warn;
  return next;
end
$$;

comment on function api.fn_move_allocation(integer, integer, date, date) is
  'Move an allocation to another bed and/or other dates (any argument left null stays as it '
  'is). Clashes warn unless their rule is BLOCK (D30). Audited. Returns the allocation with its '
  'warnings.';

drop function api_internal.course_dates_warning(integer, date, date);

reset role;
