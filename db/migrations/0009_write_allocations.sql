-- migrate:up
--------------------------------------------------------------------------------
-- 0009: write API for course bookings (D4, D30-D32).
--
--   core.rules            new rule type BED_CLASH; a DOUBLE_BOOKING rule per
--                         tenant (WARNING by default; BLOCK refuses, D30)
--   api.fn_allocate_course   a course into some beds for some nights
--   api.fn_cancel_allocation cancel one allocation
--   api.fn_move_allocation   another bed and/or other dates
--   api.fn_set_status        any status for now; transitions deferred (D31)
--   api.warnings             double-booking severity from its rule; no
--                            individual numbers in messages (D31)
--   api.fn_check_allocation  + blocks (the clash's rule is BLOCK); no
--                            individual numbers in refs (D31)
--
-- Every write checks the clash rules (refusing if one is BLOCK), writes
-- core.audit_log with the user from X-User (app.user), and returns the
-- warnings for what it wrote. Individual numbers are internal (D31): a course
-- may be allocated beyond scheduled or loaded.
--------------------------------------------------------------------------------
set local role app_owner;

-- ============================ Clash rules (D30) ===========================

alter table core.rules drop constraint rules_type_ck;
alter table core.rules add constraint rules_type_ck
  check (rule_type in ('COMPARE', 'REQUIRES', 'MATCH_WITHIN', 'SOLE_USE', 'LOCATION_BLOCKS', 'BED_CLASH'));
alter table core.rules drop constraint rules_attrs_ck;
alter table core.rules add constraint rules_attrs_ck check (
     (rule_type = 'LOCATION_BLOCKS' and individual_attr is null and location_attr is not null)
  or (rule_type in ('COMPARE', 'REQUIRES') and individual_attr is not null and location_attr is not null)
  or (rule_type in ('MATCH_WITHIN', 'SOLE_USE') and individual_attr is not null)
  or (rule_type = 'BED_CLASH' and individual_attr is null and location_attr is null));

-- New tenants and the demo reset get the rule too: wrap the 0003 loader.
alter function core.load_reference_data(integer) rename to load_reference_data_0003;

create function core.load_reference_data(p_tenant_id integer)
returns void
language plpgsql
set search_path = pg_catalog, core
as $$
declare
  v_prev text := current_setting('app.tenant_id', true);
begin
  perform core.load_reference_data_0003(p_tenant_id);
  perform set_config('app.tenant_id', p_tenant_id::text, true);
  insert into core.rules (tenant_id, rule_code, name, rule_type, severity, active, message)
  values (p_tenant_id, 'DOUBLE_BOOKING', 'Bed already booked', 'BED_CLASH', 'WARNING', 'Y',
          'This bed is already booked for some of these nights.');
  perform set_config('app.tenant_id', coalesce(v_prev, ''), true);
end
$$;

-- Existing tenants (row-level security accepts one tenant at a time).
do $$
declare
  t integer;
begin
  for t in select tenant_id from core.tenants loop
    perform set_config('app.tenant_id', t::text, true);
    insert into core.rules (tenant_id, rule_code, name, rule_type, severity, active, message)
    values (t, 'DOUBLE_BOOKING', 'Bed already booked', 'BED_CLASH', 'WARNING', 'Y',
            'This bed is already booked for some of these nights.');
  end loop;
  perform set_config('app.tenant_id', '', true);
end
$$;

-- ============================ Internal helpers ============================

-- Clashes for one bed over some nights: existing bookings (DOUBLE_BOOKING) and
-- outages (OUT_OF_ACTION). Raises if a clash's rule is BLOCK; otherwise returns
-- one warning message per clash. An inactive rule is not checked.
create function api_internal.bed_clashes(p_bed_id integer, p_from date, p_to date,
                                         p_exclude_allocation integer default null)
returns text[]
language plpgsql stable
set search_path = pg_catalog, core
as $$
declare
  v_tenant integer := core.current_tenant_id();
  v_double text;
  v_out text;
  v_bed text;
  v_msgs text[] := '{}';
  r record;
begin
  select severity into v_double from core.rules
   where tenant_id = v_tenant and rule_code = 'DOUBLE_BOOKING' and active = 'Y';
  select severity into v_out from core.rules
   where tenant_id = v_tenant and rule_code = 'OUT_OF_ACTION' and active = 'Y';
  select bp.room_name || ' bed ' || upper(bp.bed_code) into v_bed
    from core.v_bed_path bp where bp.bed_id = p_bed_id;

  if v_double is not null then
    for r in
      select coalesce(c.code, a.external_ref)::text as ref, a.start_date, a.end_date
      from core.allocations a
      left join core.courses c on c.course_id = a.course_id
      where a.tenant_id = v_tenant and a.bed_id = p_bed_id and a.status <> 'CANCELLED'
        and a.allocation_id is distinct from p_exclude_allocation
        and a.start_date < p_to and p_from < a.end_date
      order by a.start_date
    loop
      if v_double = 'BLOCK' then
        raise exception 'Not allowed: % is already booked (%, % to %)', v_bed, r.ref,
          to_char(r.start_date, 'DD/MM'), to_char(r.end_date, 'DD/MM') using errcode = 'P0001';
      end if;
      v_msgs := v_msgs || format('%s is already booked (%s, %s to %s)', v_bed, r.ref,
                                 to_char(r.start_date, 'DD/MM'), to_char(r.end_date, 'DD/MM'));
    end loop;
  end if;

  if v_out is not null then
    for r in
      select o.reason::text as reason, o.set_on_level, o.valid_from, o.valid_to
      from core.v_bed_outages o
      where o.tenant_id = v_tenant and o.bed_id = p_bed_id
        and o.valid_from < p_to and p_from < o.valid_to
      order by o.valid_from
    loop
      if v_out = 'BLOCK' then
        raise exception 'Not allowed: % is out of action (%, % to %)', v_bed, coalesce(r.reason, 'no reason given'),
          to_char(r.valid_from, 'DD/MM'), to_char(r.valid_to, 'DD/MM') using errcode = 'P0001';
      end if;
      v_msgs := v_msgs || format('%s is out of action (%s, set on the %s, %s to %s)', v_bed,
                                 coalesce(r.reason, 'no reason given'), lower(r.set_on_level),
                                 to_char(r.valid_from, 'DD/MM'), to_char(r.valid_to, 'DD/MM'));
    end loop;
  end if;

  return v_msgs;
end
$$;

-- One audit row; the user comes from the X-User header (app.user, set by the
-- pre-request hook).
create function api_internal.audit(p_table text, p_record integer, p_course integer,
                                   p_individual integer, p_action text, p_detail jsonb)
returns void
language sql
set search_path = pg_catalog, core
as $$
  insert into core.audit_log (table_name, record_id, course_id, individual_no, action, detail, changed_by)
  values (p_table, p_record, p_course, p_individual, p_action, p_detail::text,
          coalesce(nullif(current_setting('app.user', true), ''), 'anonymous'));
$$;

-- Raise unless a tenant is selected; returns it.
create function api_internal.require_tenant()
returns integer
language plpgsql stable
set search_path = pg_catalog, core
as $$
declare
  v integer := core.current_tenant_id();
begin
  if v is null then
    raise exception 'No tenant selected' using errcode = 'P0001';
  end if;
  return v;
end
$$;

-- ============================ Write functions =============================

create function api.fn_allocate_course(p_course_id integer, p_bed_ids integer[], p_from date, p_to date)
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

create function api.fn_cancel_allocation(p_allocation_id integer)
returns table (allocation_id integer, status text)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_a core.allocations%rowtype;
begin
  select * into v_a from core.allocations a
   where a.allocation_id = p_allocation_id and a.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown allocation' using errcode = 'P0001';
  end if;
  if v_a.status = 'CANCELLED' then
    raise exception 'The allocation is already cancelled' using errcode = 'P0001';
  end if;

  update core.allocations a
     set status = 'CANCELLED', checked_in_at = null, checked_out_at = null
   where a.allocation_id = p_allocation_id;

  perform api_internal.audit('allocations', p_allocation_id, v_a.course_id, v_a.individual_no, 'CANCEL',
    jsonb_build_object('from_status', v_a.status));

  allocation_id := p_allocation_id;
  status := 'CANCELLED';
  return next;
end
$$;

comment on function api.fn_cancel_allocation(integer) is
  'Cancel one allocation (kept, with status CANCELLED, so it stays in the audit history). Audited.';

create function api.fn_move_allocation(p_allocation_id integer, p_bed_id integer default null,
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

create function api.fn_set_status(p_allocation_id integer, p_status text)
returns table (allocation_id integer, status text, checked_in_at timestamp, checked_out_at timestamp)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_a core.allocations%rowtype;
  v_in timestamp;
  v_out timestamp;
begin
  if p_status is null or p_status not in ('ALLOCATED', 'BOOKED', 'CHECKED_IN', 'CHECKED_OUT', 'NO_SHOW', 'CANCELLED') then
    raise exception 'Unknown status: %', p_status using errcode = 'P0001';
  end if;

  select * into v_a from core.allocations a
   where a.allocation_id = p_allocation_id and a.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown allocation' using errcode = 'P0001';
  end if;

  if v_a.status <> p_status then
    -- Check-in and check-out times only once the status has got there.
    v_in := case when p_status in ('CHECKED_IN', 'CHECKED_OUT') then coalesce(v_a.checked_in_at, localtimestamp) end;
    v_out := case when p_status = 'CHECKED_OUT' then coalesce(v_a.checked_out_at, localtimestamp) end;

    update core.allocations a
       set status = p_status, checked_in_at = v_in, checked_out_at = v_out
     where a.allocation_id = p_allocation_id;

    perform api_internal.audit('allocations', p_allocation_id, v_a.course_id, v_a.individual_no, 'STATUS',
      jsonb_build_object('from_status', v_a.status, 'to_status', p_status));
  else
    v_in := v_a.checked_in_at;
    v_out := v_a.checked_out_at;
  end if;

  allocation_id := p_allocation_id;
  status := p_status;
  checked_in_at := v_in;
  checked_out_at := v_out;
  return next;
end
$$;

comment on function api.fn_set_status(integer, text) is
  'Set an allocation''s status: ALLOCATED, BOOKED, CHECKED_IN, CHECKED_OUT, NO_SHOW or CANCELLED. '
  'Any change is allowed for now (transitions deferred, D31). Sets or clears the check-in and '
  'check-out times to match. Audited when the status changes.';

-- ====================== Read API changes (D30, D31) =======================

-- Same columns as 0007; double-booking severity now comes from its rule, and
-- messages name the course, not the individual.
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

-- New column (blocks), so the function is replaced, not altered.
drop function api.fn_check_allocation(integer[], date, date);

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

reset role;

-- migrate:down
set local role app_owner;

drop function api.fn_check_allocation(integer[], date, date);
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

create or replace view api.warnings as
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

drop function api.fn_set_status(integer, text);
drop function api.fn_move_allocation(integer, integer, date, date);
drop function api.fn_cancel_allocation(integer);
drop function api.fn_allocate_course(integer, integer[], date, date);
drop function api_internal.require_tenant();
drop function api_internal.audit(text, integer, integer, integer, text, jsonb);
drop function api_internal.bed_clashes(integer, date, date, integer);

drop function core.load_reference_data(integer);
alter function core.load_reference_data_0003(integer) rename to load_reference_data;

reset role;

-- Rows of the new rule type go before its constraint does. Runs as the
-- migration login, which bypasses row-level security.
delete from core.rules where rule_type = 'BED_CLASH';

set local role app_owner;
alter table core.rules drop constraint rules_attrs_ck;
alter table core.rules add constraint rules_attrs_ck check (
     (rule_type = 'LOCATION_BLOCKS' and individual_attr is null and location_attr is not null)
  or (rule_type in ('COMPARE', 'REQUIRES') and individual_attr is not null and location_attr is not null)
  or (rule_type in ('MATCH_WITHIN', 'SOLE_USE') and individual_attr is not null));
alter table core.rules drop constraint rules_type_ck;
alter table core.rules add constraint rules_type_ck
  check (rule_type in ('COMPARE', 'REQUIRES', 'MATCH_WITHIN', 'SOLE_USE', 'LOCATION_BLOCKS'));
reset role;
