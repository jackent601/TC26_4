-- migrate:up
--------------------------------------------------------------------------------
-- 0013: course management (D35).
--
--   api.fn_create_course   a new course for the current tenant
--   api.fn_update_course   code, name, site, dates, scheduled, status, notes;
--                          anything left null stays as it is
--   api.fn_update_loaded   the registered headcount, stamped with the time
--   api.fn_cancel_course   cancels the course and every live allocation on it
--   api_internal.check_course   the checks they share (not an endpoint)
--
-- Every write validates, is audited to core.audit_log (user from X-User) and
-- returns what it changed. Updating returns warnings for what the change
-- leaves behind: bookings now outside the course dates, or on another site.
-- Cancelling keeps the course and its allocations as CANCELLED. A cancelled
-- course can be reinstated by setting its status again, but its bookings stay
-- cancelled: book it afresh.
--------------------------------------------------------------------------------
set local role app_owner;

-- The checks shared by create and update, on the values about to be saved.
-- p_course_id is the course being updated (null when creating), so its own
-- code doesn't count as a duplicate.
create function api_internal.check_course(p_tenant integer, p_course_id integer, p_code text, p_name text,
                                          p_start date, p_end date, p_scheduled integer, p_loaded integer,
                                          p_site_id integer, p_status text)
returns void
language plpgsql stable
set search_path = pg_catalog, core
as $$
begin
  if p_code is null or p_code = '' then
    raise exception 'A course code is needed' using errcode = 'P0001';
  end if;
  if length(p_code) > 30 then
    raise exception 'The course code is too long (30 characters at most)' using errcode = 'P0001';
  end if;
  if p_name is null or p_name = '' then
    raise exception 'A course name is needed' using errcode = 'P0001';
  end if;
  if length(p_name) > 200 then
    raise exception 'The course name is too long (200 characters at most)' using errcode = 'P0001';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'The end date must be after the start date' using errcode = 'P0001';
  end if;
  if p_scheduled is null or p_scheduled < 0 or p_loaded is null or p_loaded < 0 then
    raise exception 'scheduled and loaded must not be negative' using errcode = 'P0001';
  end if;
  if p_status is null or p_status not in ('REQUESTED', 'CONFIRMED') then
    raise exception 'Status must be REQUESTED or CONFIRMED (cancel with fn_cancel_course)' using errcode = 'P0001';
  end if;
  if p_site_id is not null
     and not exists (select 1 from core.sites s where s.site_id = p_site_id and s.tenant_id = p_tenant) then
    raise exception 'Unknown site' using errcode = 'P0001';
  end if;
  if exists (select 1 from core.courses c
              where c.tenant_id = p_tenant and upper(c.code) = upper(p_code)
                and c.course_id is distinct from p_course_id) then
    raise exception 'A course with code % already exists', upper(p_code) using errcode = 'P0001';
  end if;
end
$$;

create function api.fn_create_course(p_code text, p_name text, p_start_date date, p_end_date date,
                                     p_scheduled integer default 0, p_loaded integer default 0,
                                     p_site_id integer default null, p_status text default 'REQUESTED',
                                     p_notes text default null)
returns table (course_id integer, code text)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_code   text := btrim(p_code);
  v_name   text := btrim(p_name);
  v_notes  text := nullif(btrim(p_notes), '');
  v_id     integer;
begin
  perform api_internal.check_course(v_tenant, null, v_code, v_name, p_start_date, p_end_date,
                                    p_scheduled, p_loaded, p_site_id, p_status);

  insert into core.courses (code, name, site_id, start_date, end_date, scheduled, loaded, loaded_at, status, notes)
  values (v_code, v_name, p_site_id, p_start_date, p_end_date, p_scheduled, p_loaded,
          case when p_loaded > 0 then localtimestamp end, p_status, v_notes)
  returning core.courses.course_id into v_id;

  perform api_internal.audit('courses', v_id, v_id, null, 'INSERT',
    jsonb_build_object('code', v_code, 'name', v_name, 'site_id', p_site_id, 'start_date', p_start_date,
                       'end_date', p_end_date, 'scheduled', p_scheduled, 'loaded', p_loaded, 'status', p_status,
                       'notes', v_notes));

  course_id := v_id;
  code := v_code;
  return next;
end
$$;

comment on function api.fn_create_course(text, text, date, date, integer, integer, integer, text, text) is
  'Create a course: code (unique in the tenant, case-insensitive), name, start_date (first night) and '
  'end_date (departure day), scheduled and loaded headcounts (loaded_at is set when loaded is above 0), '
  'an optional site, status REQUESTED (default) or CONFIRMED, and notes. Audited. Returns the new course_id.';

create function api.fn_update_course(p_course_id integer, p_code text default null, p_name text default null,
                                     p_start_date date default null, p_end_date date default null,
                                     p_scheduled integer default null, p_site_id integer default null,
                                     p_clear_site boolean default false, p_status text default null,
                                     p_notes text default null)
returns table (course_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_c      core.courses%rowtype;
  v_code   text;
  v_name   text;
  v_start  date;
  v_end    date;
  v_sched  integer;
  v_site   integer;
  v_status text;
  v_notes  text;
  v_n      integer;
  v_warn   text[] := '{}';
begin
  select * into v_c from core.courses c
   where c.course_id = p_course_id and c.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;

  v_status := coalesce(p_status, v_c.status);
  -- A cancelled course can only be reinstated (status back to REQUESTED or CONFIRMED).
  if v_c.status = 'CANCELLED' and v_status = 'CANCELLED' then
    raise exception 'The course is cancelled' using errcode = 'P0001';
  end if;

  v_code  := coalesce(btrim(p_code), v_c.code);
  v_name  := coalesce(btrim(p_name), v_c.name);
  v_start := coalesce(p_start_date, v_c.start_date);
  v_end   := coalesce(p_end_date, v_c.end_date);
  v_sched := coalesce(p_scheduled, v_c.scheduled);
  v_site  := case when p_clear_site then null else coalesce(p_site_id, v_c.site_id) end;
  v_notes := case when p_notes is null then v_c.notes else nullif(btrim(p_notes), '') end;

  perform api_internal.check_course(v_tenant, p_course_id, v_code, v_name, v_start, v_end, v_sched, v_c.loaded,
                                    v_site, v_status);

  if v_code = v_c.code and v_name = v_c.name and v_start = v_c.start_date and v_end = v_c.end_date
     and v_sched = v_c.scheduled and v_site is not distinct from v_c.site_id and v_status = v_c.status
     and v_notes is not distinct from v_c.notes then
    raise exception 'Nothing to change' using errcode = 'P0001';
  end if;

  update core.courses c
     set code = v_code, name = v_name, start_date = v_start, end_date = v_end, scheduled = v_sched,
         site_id = v_site, status = v_status, notes = v_notes
   where c.course_id = p_course_id;

  -- What the change leaves behind (live bookings only).
  select count(*) into v_n from core.allocations a
   where a.tenant_id = v_tenant and a.course_id = p_course_id and a.status <> 'CANCELLED'
     and (a.start_date < v_start or a.end_date > v_end);
  if v_n > 0 then
    v_warn := v_warn || format('%s %s now outside the course dates', v_n,
                               case when v_n = 1 then 'booking is' else 'bookings are' end);
  end if;
  if v_site is not null then
    select count(*) into v_n from core.allocations a
    join core.v_bed_path bp on bp.bed_id = a.bed_id
     where a.tenant_id = v_tenant and a.course_id = p_course_id and a.status <> 'CANCELLED'
       and bp.site_id <> v_site;
    if v_n > 0 then
      v_warn := v_warn || format('%s %s on another site', v_n,
                                 case when v_n = 1 then 'booking is' else 'bookings are' end);
    end if;
  end if;

  perform api_internal.audit('courses', p_course_id, p_course_id, null, 'UPDATE',
    jsonb_build_object(
      'from', jsonb_build_object('code', v_c.code, 'name', v_c.name, 'site_id', v_c.site_id,
                                 'start_date', v_c.start_date, 'end_date', v_c.end_date,
                                 'scheduled', v_c.scheduled, 'status', v_c.status, 'notes', v_c.notes),
      'to', jsonb_build_object('code', v_code, 'name', v_name, 'site_id', v_site,
                               'start_date', v_start, 'end_date', v_end,
                               'scheduled', v_sched, 'status', v_status, 'notes', v_notes),
      'warnings', v_warn));

  course_id := p_course_id;
  warnings := v_warn;
  return next;
end
$$;

comment on function api.fn_update_course(integer, text, text, date, date, integer, integer, boolean, text, text) is
  'Change a course: code, name, start_date, end_date, scheduled, site (p_clear_site removes it), status '
  '(REQUESTED or CONFIRMED; a cancelled course can be reinstated this way, its bookings stay cancelled) and '
  'notes (empty clears them). Anything left null stays as it is. Audited. Returns warnings for live bookings '
  'the change leaves outside the course dates or on another site.';

create function api.fn_update_loaded(p_course_id integer, p_loaded integer)
returns table (course_id integer, loaded integer, loaded_at timestamp, loaded_above_scheduled boolean)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_c      core.courses%rowtype;
  v_at     timestamp := localtimestamp;
begin
  if p_loaded is null or p_loaded < 0 then
    raise exception 'loaded must not be negative' using errcode = 'P0001';
  end if;
  select * into v_c from core.courses c
   where c.course_id = p_course_id and c.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;
  if v_c.status = 'CANCELLED' then
    raise exception 'The course is cancelled' using errcode = 'P0001';
  end if;

  update core.courses c set loaded = p_loaded, loaded_at = v_at where c.course_id = p_course_id;

  perform api_internal.audit('courses', p_course_id, p_course_id, null, 'LOADED',
    jsonb_build_object('from', v_c.loaded, 'to', p_loaded));

  course_id := p_course_id;
  loaded := p_loaded;
  loaded_at := v_at;
  loaded_above_scheduled := p_loaded > v_c.scheduled;
  return next;
end
$$;

comment on function api.fn_update_loaded(integer, integer) is
  'Set a course''s loaded (registered) headcount and stamp loaded_at with now. Audited. Returns the new '
  'figure and whether it is above scheduled.';

create function api.fn_cancel_course(p_course_id integer)
returns table (course_id integer, allocations_cancelled integer)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_c      core.courses%rowtype;
  v_n      integer := 0;
  a        record;
begin
  select * into v_c from core.courses c
   where c.course_id = p_course_id and c.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown course' using errcode = 'P0001';
  end if;
  if v_c.status = 'CANCELLED' then
    raise exception 'The course is already cancelled' using errcode = 'P0001';
  end if;

  for a in
    select x.allocation_id, x.individual_no, x.status from core.allocations x
     where x.tenant_id = v_tenant and x.course_id = p_course_id and x.status <> 'CANCELLED'
     order by x.allocation_id
     for update
  loop
    update core.allocations x
       set status = 'CANCELLED', checked_in_at = null, checked_out_at = null
     where x.allocation_id = a.allocation_id;
    perform api_internal.audit('allocations', a.allocation_id, p_course_id, a.individual_no, 'CANCEL',
      jsonb_build_object('from_status', a.status, 'reason', 'course cancelled'));
    v_n := v_n + 1;
  end loop;

  update core.courses c set status = 'CANCELLED' where c.course_id = p_course_id;

  perform api_internal.audit('courses', p_course_id, p_course_id, null, 'CANCEL',
    jsonb_build_object('from_status', v_c.status, 'allocations_cancelled', v_n));

  course_id := p_course_id;
  allocations_cancelled := v_n;
  return next;
end
$$;

comment on function api.fn_cancel_course(integer) is
  'Cancel a course and every live allocation on it (all kept, as CANCELLED). Each cancellation is audited. '
  'Returns how many allocations were cancelled.';

reset role;

-- migrate:down
set local role app_owner;
drop function api.fn_cancel_course(integer);
drop function api.fn_update_loaded(integer, integer);
drop function api.fn_update_course(integer, text, text, date, date, integer, integer, boolean, text, text);
drop function api.fn_create_course(text, text, date, date, integer, integer, integer, text, text);
drop function api_internal.check_course(integer, integer, text, text, date, date, integer, integer, integer, text);
reset role;
