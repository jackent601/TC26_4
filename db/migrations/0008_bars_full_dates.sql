-- migrate:up
--------------------------------------------------------------------------------
-- 0008: api.fn_bed_bars returns each bar's full dates (D29: facts, not
-- presentation). It still returns only bars that overlap p_from..p_to; fitting
-- them to the weeks shown is the UI's job. Popups need the real dates.
--------------------------------------------------------------------------------
set local role app_owner;

create or replace function api.fn_bed_bars(p_from date, p_to date)
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
         a.allocation_id, a.start_date, a.end_date,
         a.course_id, c.code::text, a.individual_no, a.external_ref::text, a.external_name::text,
         a.status::text, null::text, null::text,
         exists (select 1 from core.v_bed_outages o
                  where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.tenant_id = v_tenant
    and a.status <> 'CANCELLED' and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'outage', o.outage_id, o.valid_from, o.valid_to,
         null, null, null, null, null, null, o.set_on_level, o.reason::text, null
  from core.v_bed_outages o
  where o.tenant_id = v_tenant
    and o.valid_from < p_to and p_from < o.valid_to
  order by 1, 4, 2;
end
$$;

comment on function api.fn_bed_bars(date, date) is
  'Bars for every bed that overlap p_from to p_to (exclusive): kind allocation, external or '
  'outage, with their full dates (end exclusive). on_outage flags a booking that falls on an '
  'out-of-action bed.';

reset role;

-- migrate:down
set local role app_owner;

create or replace function api.fn_bed_bars(p_from date, p_to date)
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

reset role;
