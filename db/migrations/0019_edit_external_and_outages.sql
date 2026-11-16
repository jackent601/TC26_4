-- migrate:up
--------------------------------------------------------------------------------
-- 0019: change external bookings and outages from their popups (D39).
--
--   api.fn_update_external        an external booking's reference and name
--                                 (bed, dates, status and cancel already work
--                                 through the course-booking functions)
--   api.fn_update_outage          an outage's dates and reason; warns about
--                                 bookings it now lands on
--   api.fn_remove_outage          delete an outage (the audit keeps it)
--   api_internal.outage_location  where an outage is set: level, name, site
--   api_internal.audit_summary    + sentences for the three
--------------------------------------------------------------------------------
set local role app_owner;

-- =========================== External bookings ===========================

create function api.fn_update_external(p_allocation_id integer, p_ref text default null, p_name text default null)
returns table (allocation_id integer, external_ref text, external_name text)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_a core.allocations%rowtype;
  v_ref text;
  v_name text;
begin
  select * into v_a from core.allocations a
   where a.allocation_id = p_allocation_id and a.tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'Unknown allocation' using errcode = 'P0001';
  end if;
  if v_a.source <> 'EXTERNAL' then
    raise exception 'Only an external booking has a reference and name' using errcode = 'P0001';
  end if;

  v_ref := coalesce(btrim(p_ref), v_a.external_ref);
  v_name := coalesce(btrim(p_name), v_a.external_name);
  if v_ref = '' then
    raise exception 'Enter the booking reference' using errcode = 'P0001';
  end if;
  if length(v_ref) > 50 then
    raise exception 'The booking reference is longer than 50 characters' using errcode = 'P0001';
  end if;
  if v_name = '' then
    raise exception 'Enter who the booking is for' using errcode = 'P0001';
  end if;
  if length(v_name) > 200 then
    raise exception 'The name is longer than 200 characters' using errcode = 'P0001';
  end if;
  if v_ref = v_a.external_ref and v_name = v_a.external_name then
    raise exception 'Nothing to change' using errcode = 'P0001';
  end if;

  update core.allocations a set external_ref = v_ref, external_name = v_name
   where a.allocation_id = p_allocation_id;

  perform api_internal.audit('allocations', p_allocation_id, null, null, 'DETAILS',
    jsonb_build_object('bed_id', v_a.bed_id,
                       'from', jsonb_build_object('external_ref', v_a.external_ref, 'external_name', v_a.external_name),
                       'to', jsonb_build_object('external_ref', v_ref, 'external_name', v_name)));

  allocation_id := p_allocation_id;
  external_ref := v_ref;
  external_name := v_name;
  return next;
end
$$;

comment on function api.fn_update_external(integer, text, text) is
  'Change an external booking''s reference (p_ref) and/or who it is for (p_name); null keeps a value '
  '(D39). For one allocation (one bed). Its bed, dates, status and cancelling go through '
  'fn_move_allocation, fn_set_status and fn_cancel_allocation, as for course bookings. Audited.';

-- ================================ Outages ================================

-- Where an outage is set: its level, location id, name (as on the grid) and site.
create function api_internal.outage_location(p_outage_id integer)
returns table (level text, location_id integer, name text, site_id integer)
language sql stable
set search_path = pg_catalog, core
as $$
  select case when la.bed_id is not null then 'Bed' when la.room_id is not null then 'Room'
              when la.floor_id is not null then 'Floor' when la.block_id is not null then 'Block'
              when la.building_id is not null then 'Building' else 'Site' end,
         coalesce(la.bed_id, la.room_id, la.floor_id, la.block_id, la.building_id, la.site_id),
         coalesce(
           (select bp.room_name || ' bed ' || upper(bp.bed_code) from core.v_bed_path bp where bp.bed_id = la.bed_id),
           (select r.name from core.rooms r where r.room_id = la.room_id),
           (select bl.name || ' ' || f.name from core.floors f join core.blocks bl on bl.block_id = f.block_id
             where f.floor_id = la.floor_id),
           (select bl.name from core.blocks bl where bl.block_id = la.block_id),
           (select b.name from core.buildings b where b.building_id = la.building_id),
           (select s.name from core.sites s where s.site_id = la.site_id))::text,
         coalesce(
           (select bp.site_id from core.v_bed_path bp where bp.bed_id = la.bed_id),
           (select bp.site_id from core.v_bed_path bp where bp.room_id = la.room_id limit 1),
           (select bu.site_id from core.floors f join core.blocks bl on bl.block_id = f.block_id
              join core.buildings bu on bu.building_id = bl.building_id where f.floor_id = la.floor_id),
           (select bu.site_id from core.blocks bl join core.buildings bu on bu.building_id = bl.building_id
             where bl.block_id = la.block_id),
           (select b.site_id from core.buildings b where b.building_id = la.building_id),
           la.site_id)
  from core.location_attributes la
  where la.loc_attr_id = p_outage_id and la.tenant_id = core.current_tenant_id()
    and la.attr_code = 'OUT_OF_ACTION'
$$;

create function api.fn_update_outage(p_outage_id integer, p_from date default null, p_to date default null,
                                     p_reason text default null)
returns table (outage_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_o core.location_attributes%rowtype;
  v_loc record;
  v_from date;
  v_to date;
  v_reason text;
  v_warn text[];
begin
  select * into v_o from core.location_attributes la
   where la.loc_attr_id = p_outage_id and la.tenant_id = v_tenant and la.attr_code = 'OUT_OF_ACTION'
   for update;
  if not found then
    raise exception 'Unknown outage' using errcode = 'P0001';
  end if;
  select * into v_loc from api_internal.outage_location(p_outage_id);

  v_from := coalesce(p_from, v_o.valid_from);
  v_to := coalesce(p_to, v_o.valid_to);
  v_reason := coalesce(btrim(p_reason), v_o.comments);
  if v_to <= v_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if v_reason is null or v_reason = '' then
    raise exception 'Enter a reason' using errcode = 'P0001';
  end if;
  if length(v_reason) > 1000 then
    raise exception 'The reason is longer than 1000 characters' using errcode = 'P0001';
  end if;
  if v_from = v_o.valid_from and v_to = v_o.valid_to and v_reason is not distinct from v_o.comments then
    raise exception 'Nothing to change' using errcode = 'P0001';
  end if;

  update core.location_attributes la set valid_from = v_from, valid_to = v_to, comments = v_reason
   where la.loc_attr_id = p_outage_id;

  -- Live bookings it now lands on (saved anyway, as when added: D38).
  select coalesce(array_agg(format('%s in %s (%s to %s) is in an out-of-action bed',
                                   coalesce(c.code, a.external_ref), bp.room_name || ' bed ' || upper(bp.bed_code),
                                   to_char(a.start_date, 'DD/MM'), to_char(a.end_date, 'DD/MM'))
                            order by bp.room_code, bp.bed_code, a.start_date), '{}')
    into v_warn
    from core.allocations a
    join core.v_bed_path bp on bp.bed_id = a.bed_id
    left join core.courses c on c.course_id = a.course_id
   where a.tenant_id = v_tenant and a.status <> 'CANCELLED'
     and a.start_date < v_to and v_from < a.end_date
     and v_loc.location_id = case v_loc.level when 'Site' then bp.site_id when 'Building' then bp.building_id
                                              when 'Block' then bp.block_id when 'Floor' then bp.floor_id
                                              when 'Room' then bp.room_id else bp.bed_id end;

  perform api_internal.audit('location_attributes', p_outage_id, null, null, 'UPDATE',
    jsonb_build_object('location', v_loc.name, 'site_id', v_loc.site_id, 'level', v_loc.level,
                       'from', jsonb_build_object('start_date', v_o.valid_from, 'end_date', v_o.valid_to, 'reason', v_o.comments),
                       'to', jsonb_build_object('start_date', v_from, 'end_date', v_to, 'reason', v_reason),
                       'warnings', v_warn));

  outage_id := p_outage_id;
  warnings := v_warn;
  return next;
end
$$;

comment on function api.fn_update_outage(integer, date, date, text) is
  'Change an outage''s dates (p_from, p_to exclusive) and/or reason; null keeps a value (D39). Saved even '
  'when it lands on live bookings, which come back as warnings and show in api.warnings. Audited. '
  'Returns the outage id with its warnings.';

create function api.fn_remove_outage(p_outage_id integer)
returns table (outage_id integer)
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_o core.location_attributes%rowtype;
  v_loc record;
begin
  select * into v_o from core.location_attributes la
   where la.loc_attr_id = p_outage_id and la.tenant_id = v_tenant and la.attr_code = 'OUT_OF_ACTION'
   for update;
  if not found then
    raise exception 'Unknown outage' using errcode = 'P0001';
  end if;
  select * into v_loc from api_internal.outage_location(p_outage_id);

  delete from core.location_attributes la where la.loc_attr_id = p_outage_id;

  perform api_internal.audit('location_attributes', p_outage_id, null, null, 'DELETE',
    jsonb_build_object('location', v_loc.name, 'site_id', v_loc.site_id, 'level', v_loc.level,
                       'start_date', v_o.valid_from, 'end_date', v_o.valid_to, 'reason', v_o.comments));

  outage_id := p_outage_id;
  return next;
end
$$;

comment on function api.fn_remove_outage(integer) is
  'Remove an outage (D39): the location is back in service for those dates. The row is deleted; the '
  'audit log keeps where it was, its dates and reason. To end an outage early instead, change its end '
  'date with fn_update_outage.';

-- ============================ Audit wording =============================

create or replace function api_internal.audit_summary(p_table text, p_action text, p_detail jsonb,
                                           p_course text, p_bed text, p_bed_to text, p_site text)
returns text
language sql stable
set search_path = pg_catalog, core
as $$
  select case p_table || '/' || p_action
    when 'allocations/INSERT' then
      format('booked %s into %s, %s to %s', p_course, p_bed,
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'))
      || api_internal.warning_suffix(p_detail)
    when 'allocations/MOVE' then
      case
        when p_detail #>> '{from,bed_id}' is distinct from p_detail #>> '{to,bed_id}'
         and (p_detail #>> '{from,start_date}' is distinct from p_detail #>> '{to,start_date}'
              or p_detail #>> '{from,end_date}' is distinct from p_detail #>> '{to,end_date}') then
          format('moved %s from %s to %s, now %s to %s', p_course, p_bed, p_bed_to,
                 api_internal.ddmm(p_detail #>> '{to,start_date}'), api_internal.ddmm(p_detail #>> '{to,end_date}'))
        when p_detail #>> '{from,bed_id}' is distinct from p_detail #>> '{to,bed_id}' then
          format('moved %s from %s to %s', p_course, p_bed, p_bed_to)
        else
          format('changed %s''s dates in %s to %s to %s', p_course, p_bed_to,
                 api_internal.ddmm(p_detail #>> '{to,start_date}'), api_internal.ddmm(p_detail #>> '{to,end_date}'))
      end || api_internal.warning_suffix(p_detail)
    when 'allocations/CANCEL' then
      format('cancelled %s''s booking in %s', p_course, p_bed)
      || case when p_detail ->> 'reason' = 'course cancelled' then ' (course cancelled)' else '' end
    when 'allocations/STATUS' then
      format('set %s''s booking in %s to %s', p_course, p_bed, api_internal.status_name(p_detail ->> 'to_status'))
    when 'courses/INSERT' then
      format('added course %s: %s, %s to %s, %s scheduled', p_detail ->> 'code', p_detail ->> 'name',
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'),
             p_detail ->> 'scheduled')
    when 'courses/UPDATE' then
      'changed ' || coalesce(p_detail #>> '{from,code}', p_course) || ': ' || concat_ws(', ',
        case when p_detail #>> '{from,code}' is distinct from p_detail #>> '{to,code}'
             then 'code to ' || (p_detail #>> '{to,code}') end,
        case when p_detail #>> '{from,name}' is distinct from p_detail #>> '{to,name}'
             then 'name to ' || (p_detail #>> '{to,name}') end,
        case when p_detail #>> '{from,start_date}' is distinct from p_detail #>> '{to,start_date}'
               or p_detail #>> '{from,end_date}' is distinct from p_detail #>> '{to,end_date}'
             then 'dates to ' || api_internal.ddmm(p_detail #>> '{to,start_date}') || ' to '
                  || api_internal.ddmm(p_detail #>> '{to,end_date}') end,
        case when p_detail #>> '{from,scheduled}' is distinct from p_detail #>> '{to,scheduled}'
             then 'scheduled to ' || (p_detail #>> '{to,scheduled}') end,
        case when p_detail #>> '{from,site_id}' is distinct from p_detail #>> '{to,site_id}'
             then case when p_detail #>> '{to,site_id}' is null then 'no site'
                       else 'site to ' || coalesce(p_site, 'site ' || (p_detail #>> '{to,site_id}')) end end,
        case when p_detail #>> '{from,status}' is distinct from p_detail #>> '{to,status}'
             then 'status to ' || api_internal.status_name(p_detail #>> '{to,status}') end,
        case when p_detail #>> '{from,notes}' is distinct from p_detail #>> '{to,notes}' then 'notes' end)
      || api_internal.warning_suffix(p_detail)
    when 'courses/LOADED' then
      format('set %s loaded to %s (was %s)', p_course, p_detail ->> 'to', p_detail ->> 'from')
    when 'courses/CANCEL' then
      format('cancelled course %s and %s %s', p_course, p_detail ->> 'allocations_cancelled',
             case when p_detail ->> 'allocations_cancelled' = '1' then 'booking' else 'bookings' end)
    when 'location_attributes/INSERT' then
      format('put %s out of action, %s to %s: %s', p_detail ->> 'location',
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'),
             p_detail ->> 'reason')
      || api_internal.warning_suffix(p_detail)
    when 'allocations/DETAILS' then
      format('changed %s''s booking in %s: ', p_detail #>> '{from,external_ref}', p_bed) || concat_ws(', ',
        case when p_detail #>> '{from,external_ref}' is distinct from p_detail #>> '{to,external_ref}'
             then 'reference to ' || (p_detail #>> '{to,external_ref}') end,
        case when p_detail #>> '{from,external_name}' is distinct from p_detail #>> '{to,external_name}'
             then 'name to ' || (p_detail #>> '{to,external_name}') end)
    when 'location_attributes/UPDATE' then
      'changed the outage on ' || (p_detail ->> 'location') || ': ' || concat_ws(', ',
        case when p_detail #>> '{from,start_date}' is distinct from p_detail #>> '{to,start_date}'
               or p_detail #>> '{from,end_date}' is distinct from p_detail #>> '{to,end_date}'
             then 'dates to ' || api_internal.ddmm(p_detail #>> '{to,start_date}') || ' to '
                  || api_internal.ddmm(p_detail #>> '{to,end_date}') end,
        case when p_detail #>> '{from,reason}' is distinct from p_detail #>> '{to,reason}'
             then 'reason to ' || (p_detail #>> '{to,reason}') end)
      || api_internal.warning_suffix(p_detail)
    when 'location_attributes/DELETE' then
      format('removed the outage on %s (%s to %s: %s)', p_detail ->> 'location',
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'),
             p_detail ->> 'reason')
    else lower(p_action) || ' on ' || p_table
  end
$$;

reset role;

-- migrate:down
set local role app_owner;

-- 0017's wording.
create or replace function api_internal.audit_summary(p_table text, p_action text, p_detail jsonb,
                                           p_course text, p_bed text, p_bed_to text, p_site text)
returns text
language sql stable
set search_path = pg_catalog, core
as $$
  select case p_table || '/' || p_action
    when 'allocations/INSERT' then
      format('booked %s into %s, %s to %s', p_course, p_bed,
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'))
      || api_internal.warning_suffix(p_detail)
    when 'allocations/MOVE' then
      case
        when p_detail #>> '{from,bed_id}' is distinct from p_detail #>> '{to,bed_id}'
         and (p_detail #>> '{from,start_date}' is distinct from p_detail #>> '{to,start_date}'
              or p_detail #>> '{from,end_date}' is distinct from p_detail #>> '{to,end_date}') then
          format('moved %s from %s to %s, now %s to %s', p_course, p_bed, p_bed_to,
                 api_internal.ddmm(p_detail #>> '{to,start_date}'), api_internal.ddmm(p_detail #>> '{to,end_date}'))
        when p_detail #>> '{from,bed_id}' is distinct from p_detail #>> '{to,bed_id}' then
          format('moved %s from %s to %s', p_course, p_bed, p_bed_to)
        else
          format('changed %s''s dates in %s to %s to %s', p_course, p_bed_to,
                 api_internal.ddmm(p_detail #>> '{to,start_date}'), api_internal.ddmm(p_detail #>> '{to,end_date}'))
      end || api_internal.warning_suffix(p_detail)
    when 'allocations/CANCEL' then
      format('cancelled %s''s booking in %s', p_course, p_bed)
      || case when p_detail ->> 'reason' = 'course cancelled' then ' (course cancelled)' else '' end
    when 'allocations/STATUS' then
      format('set %s''s booking in %s to %s', p_course, p_bed, api_internal.status_name(p_detail ->> 'to_status'))
    when 'courses/INSERT' then
      format('added course %s: %s, %s to %s, %s scheduled', p_detail ->> 'code', p_detail ->> 'name',
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'),
             p_detail ->> 'scheduled')
    when 'courses/UPDATE' then
      'changed ' || coalesce(p_detail #>> '{from,code}', p_course) || ': ' || concat_ws(', ',
        case when p_detail #>> '{from,code}' is distinct from p_detail #>> '{to,code}'
             then 'code to ' || (p_detail #>> '{to,code}') end,
        case when p_detail #>> '{from,name}' is distinct from p_detail #>> '{to,name}'
             then 'name to ' || (p_detail #>> '{to,name}') end,
        case when p_detail #>> '{from,start_date}' is distinct from p_detail #>> '{to,start_date}'
               or p_detail #>> '{from,end_date}' is distinct from p_detail #>> '{to,end_date}'
             then 'dates to ' || api_internal.ddmm(p_detail #>> '{to,start_date}') || ' to '
                  || api_internal.ddmm(p_detail #>> '{to,end_date}') end,
        case when p_detail #>> '{from,scheduled}' is distinct from p_detail #>> '{to,scheduled}'
             then 'scheduled to ' || (p_detail #>> '{to,scheduled}') end,
        case when p_detail #>> '{from,site_id}' is distinct from p_detail #>> '{to,site_id}'
             then case when p_detail #>> '{to,site_id}' is null then 'no site'
                       else 'site to ' || coalesce(p_site, 'site ' || (p_detail #>> '{to,site_id}')) end end,
        case when p_detail #>> '{from,status}' is distinct from p_detail #>> '{to,status}'
             then 'status to ' || api_internal.status_name(p_detail #>> '{to,status}') end,
        case when p_detail #>> '{from,notes}' is distinct from p_detail #>> '{to,notes}' then 'notes' end)
      || api_internal.warning_suffix(p_detail)
    when 'courses/LOADED' then
      format('set %s loaded to %s (was %s)', p_course, p_detail ->> 'to', p_detail ->> 'from')
    when 'courses/CANCEL' then
      format('cancelled course %s and %s %s', p_course, p_detail ->> 'allocations_cancelled',
             case when p_detail ->> 'allocations_cancelled' = '1' then 'booking' else 'bookings' end)
    when 'location_attributes/INSERT' then
      format('put %s out of action, %s to %s: %s', p_detail ->> 'location',
             api_internal.ddmm(p_detail ->> 'start_date'), api_internal.ddmm(p_detail ->> 'end_date'),
             p_detail ->> 'reason')
      || api_internal.warning_suffix(p_detail)
    else lower(p_action) || ' on ' || p_table
  end
$$;

drop function api.fn_remove_outage(integer);
drop function api.fn_update_outage(integer, date, date, text);
drop function api_internal.outage_location(integer);
drop function api.fn_update_external(integer, text, text);

reset role;
