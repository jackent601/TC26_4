-- migrate:up
--------------------------------------------------------------------------------
-- 0017: external bookings and outages from the UI (D38). The tables already
-- hold both (allocations with source EXTERNAL; location_attributes
-- OUT_OF_ACTION); these are their write functions.
--
--   api.fn_book_external        book beds for someone outside the courses
--   api.fn_add_outage           put a site, building, block, floor, room or bed
--                               out of action; warns about bookings it lands on
--   api_internal.audit_summary  + "put Room 203 out of action, ..."
--   api.audit                   an external booking is named by its reference
--                               ("booked BK-4519 into ..."); an outage has a site
--------------------------------------------------------------------------------
set local role app_owner;

-- ========================= External bookings =========================

create function api.fn_book_external(p_ref text, p_name text, p_bed_ids integer[], p_from date, p_to date)
returns table (allocation_id integer, bed_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_ref text := nullif(btrim(p_ref), '');
  v_name text := nullif(btrim(p_name), '');
  v_bed integer;
  v_id integer;
  v_warn text[];
begin
  if v_ref is null then
    raise exception 'Enter the booking reference' using errcode = 'P0001';
  end if;
  if length(v_ref) > 50 then
    raise exception 'The booking reference is longer than 50 characters' using errcode = 'P0001';
  end if;
  if v_name is null then
    raise exception 'Enter who the booking is for' using errcode = 'P0001';
  end if;
  if length(v_name) > 200 then
    raise exception 'The name is longer than 200 characters' using errcode = 'P0001';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if p_bed_ids is null or cardinality(p_bed_ids) = 0 then
    raise exception 'Choose at least one bed' using errcode = 'P0001';
  end if;
  if (select count(distinct b) from unnest(p_bed_ids) b) <> cardinality(p_bed_ids) then
    raise exception 'A bed is listed more than once' using errcode = 'P0001';
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
    v_warn := api_internal.bed_clashes(v_bed, p_from, p_to);   -- raises if a clash rule is BLOCK

    insert into core.allocations (bed_id, start_date, end_date, status, source, external_ref, external_name)
    values (v_bed, p_from, p_to, 'BOOKED', 'EXTERNAL', v_ref, v_name)
    returning core.allocations.allocation_id into v_id;

    perform api_internal.audit('allocations', v_id, null, null, 'INSERT',
      jsonb_build_object('external_ref', v_ref, 'external_name', v_name, 'bed_id', v_bed,
                         'start_date', p_from, 'end_date', p_to, 'warnings', v_warn));

    allocation_id := v_id;
    bed_id := v_bed;
    warnings := v_warn;
    return next;
  end loop;
end
$$;

comment on function api.fn_book_external(text, text, integer[], date, date) is
  'Book beds for someone outside the courses (an external booking, D38): p_ref is the booking reference, '
  'p_name who it is for, from p_from (first night) to p_to (departure day). One allocation per bed, '
  'status BOOKED, source EXTERNAL. Clashes warn unless their rule is BLOCK, which refuses the whole '
  'request (D30). Audited. Returns each new allocation with its warnings.';

-- =============================== Outages ===============================

create function api.fn_add_outage(p_level text, p_location_id integer, p_from date, p_to date, p_reason text)
returns table (outage_id integer, warnings text[])
language plpgsql volatile security definer
set search_path = pg_catalog, core
as $$
#variable_conflict use_column
declare
  v_tenant integer := api_internal.require_tenant();
  v_level text := initcap(btrim(coalesce(p_level, '')));
  v_reason text := nullif(btrim(p_reason), '');
  v_name text;
  v_site integer;
  v_id integer;
  v_warn text[];
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = 'P0001';
  end if;
  if v_reason is null then
    raise exception 'Enter a reason' using errcode = 'P0001';
  end if;
  if length(v_reason) > 1000 then
    raise exception 'The reason is longer than 1000 characters' using errcode = 'P0001';
  end if;

  -- The location, named as on the availability grid, and its site.
  case v_level
    when 'Site' then
      select s.name, s.site_id into v_name, v_site from core.sites s
       where s.tenant_id = v_tenant and s.site_id = p_location_id;
    when 'Building' then
      select b.name, b.site_id into v_name, v_site from core.buildings b
       where b.tenant_id = v_tenant and b.building_id = p_location_id;
    when 'Block' then
      select bl.name, bu.site_id into v_name, v_site from core.blocks bl
        join core.buildings bu on bu.building_id = bl.building_id
       where bl.tenant_id = v_tenant and bl.block_id = p_location_id;
    when 'Floor' then
      select bl.name || ' ' || f.name, bu.site_id into v_name, v_site from core.floors f
        join core.blocks bl on bl.block_id = f.block_id
        join core.buildings bu on bu.building_id = bl.building_id
       where f.tenant_id = v_tenant and f.floor_id = p_location_id;
    when 'Room' then
      select r.name, bu.site_id into v_name, v_site from core.rooms r
        join core.floors f on f.floor_id = r.floor_id
        join core.blocks bl on bl.block_id = f.block_id
        join core.buildings bu on bu.building_id = bl.building_id
       where r.tenant_id = v_tenant and r.room_id = p_location_id;
    when 'Bed' then
      select bp.room_name || ' bed ' || upper(bp.bed_code), bp.site_id into v_name, v_site from core.v_bed_path bp
       where bp.tenant_id = v_tenant and bp.bed_id = p_location_id;
    else
      raise exception 'Unknown level: % (Site, Building, Block, Floor, Room or Bed)', p_level using errcode = 'P0001';
  end case;
  if v_name is null then
    raise exception 'Unknown location' using errcode = 'P0001';
  end if;

  insert into core.location_attributes (attr_code, attr_value, valid_from, valid_to, comments,
                                        site_id, building_id, block_id, floor_id, room_id, bed_id)
  values ('OUT_OF_ACTION', 'Y', p_from, p_to, v_reason,
          case when v_level = 'Site'     then p_location_id end,
          case when v_level = 'Building' then p_location_id end,
          case when v_level = 'Block'    then p_location_id end,
          case when v_level = 'Floor'    then p_location_id end,
          case when v_level = 'Room'     then p_location_id end,
          case when v_level = 'Bed'      then p_location_id end)
  returning loc_attr_id into v_id;

  -- Live bookings it lands on (D38: saved anyway; api.warnings lists them from now on).
  select coalesce(array_agg(format('%s in %s (%s to %s) is now in an out-of-action bed',
                                   coalesce(c.code, a.external_ref), bp.room_name || ' bed ' || upper(bp.bed_code),
                                   to_char(a.start_date, 'DD/MM'), to_char(a.end_date, 'DD/MM'))
                            order by bp.room_code, bp.bed_code, a.start_date), '{}')
    into v_warn
    from core.allocations a
    join core.v_bed_path bp on bp.bed_id = a.bed_id
    left join core.courses c on c.course_id = a.course_id
   where a.tenant_id = v_tenant and a.status <> 'CANCELLED'
     and a.start_date < p_to and p_from < a.end_date
     and p_location_id = case v_level when 'Site' then bp.site_id when 'Building' then bp.building_id
                                      when 'Block' then bp.block_id when 'Floor' then bp.floor_id
                                      when 'Room' then bp.room_id else bp.bed_id end;

  perform api_internal.audit('location_attributes', v_id, null, null, 'INSERT',
    jsonb_build_object('attr_code', 'OUT_OF_ACTION', 'level', v_level, 'location_id', p_location_id,
                       'location', v_name, 'site_id', v_site, 'start_date', p_from, 'end_date', p_to,
                       'reason', v_reason, 'warnings', v_warn));

  outage_id := v_id;
  warnings := v_warn;
  return next;
end
$$;

comment on function api.fn_add_outage(text, integer, date, date, text) is
  'Put a location out of action (an outage, D38): p_level is Site, Building, Block, Floor, Room or Bed and '
  'p_location_id its id (as in api.locations), from p_from to p_to (exclusive), with a reason. It applies to '
  'every bed under the location. Saved even when it lands on live bookings: each one is returned as a '
  'warning and listed in api.warnings from then on. Audited. Returns the outage id with its warnings.';

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
    else lower(p_action) || ' on ' || p_table
  end
$$;

create or replace view api.audit as
select l.audit_id, l.request_id, l.changed_at, l.changed_by::text as changed_by,
       l.table_name::text as table_name, l.record_id, l.course_id,
       coalesce(c.code::text, d.j ->> 'code', d.j #>> '{from,code}', a.external_ref::text, d.j ->> 'external_ref',
                'course ' || l.course_id) as course_code,
       case when l.table_name = 'allocations' then l.record_id end as allocation_id,
       coalesce(a.bed_id, (d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer) as bed_id,
       coalesce(bp.site_id, c.site_id, (d.j ->> 'site_id')::integer) as site_id,
       l.action::text as action,
       api_internal.audit_summary(l.table_name, l.action, d.j,
         coalesce(c.code::text, d.j ->> 'code', a.external_ref::text, d.j ->> 'external_ref', 'course ' || l.course_id),
         coalesce(bf.room_name || ' bed ' || upper(bf.bed_code),
                  'bed ' || coalesce((d.j ->> 'bed_id')::text, d.j #>> '{from,bed_id}', a.bed_id::text)),
         coalesce(bt.room_name || ' bed ' || upper(bt.bed_code), 'bed ' || (d.j #>> '{to,bed_id}')),
         s.name::text) as summary,
       d.j as detail,
       coalesce(array(select jsonb_array_elements_text(d.j -> 'warnings')
                       where jsonb_typeof(d.j -> 'warnings') = 'array'), '{}'::text[]) as warnings
from core.audit_log l
cross join lateral (select api_internal.safe_jsonb(l.detail) as j) d
left join core.courses c on c.course_id = l.course_id
left join core.allocations a on l.table_name = 'allocations' and a.allocation_id = l.record_id
left join core.v_bed_path bp on bp.bed_id = coalesce(a.bed_id, (d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer)
left join core.v_bed_path bf on bf.bed_id = coalesce((d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer, a.bed_id)
left join core.v_bed_path bt on bt.bed_id = (d.j #>> '{to,bed_id}')::integer
left join core.sites s on s.site_id = (d.j #>> '{to,site_id}')::integer;

reset role;

-- migrate:down
set local role app_owner;

create or replace view api.audit as
select l.audit_id, l.request_id, l.changed_at, l.changed_by::text as changed_by,
       l.table_name::text as table_name, l.record_id, l.course_id,
       coalesce(c.code::text, d.j ->> 'code', d.j #>> '{from,code}', 'course ' || l.course_id) as course_code,
       case when l.table_name = 'allocations' then l.record_id end as allocation_id,
       coalesce(a.bed_id, (d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer) as bed_id,
       coalesce(bp.site_id, c.site_id) as site_id,
       l.action::text as action,
       api_internal.audit_summary(l.table_name, l.action, d.j,
         coalesce(c.code::text, d.j ->> 'code', 'course ' || l.course_id),
         coalesce(bf.room_name || ' bed ' || upper(bf.bed_code),
                  'bed ' || coalesce((d.j ->> 'bed_id')::text, d.j #>> '{from,bed_id}', a.bed_id::text)),
         coalesce(bt.room_name || ' bed ' || upper(bt.bed_code), 'bed ' || (d.j #>> '{to,bed_id}')),
         s.name::text) as summary,
       d.j as detail,
       coalesce(array(select jsonb_array_elements_text(d.j -> 'warnings')
                       where jsonb_typeof(d.j -> 'warnings') = 'array'), '{}'::text[]) as warnings
from core.audit_log l
cross join lateral (select api_internal.safe_jsonb(l.detail) as j) d
left join core.courses c on c.course_id = l.course_id
left join core.allocations a on l.table_name = 'allocations' and a.allocation_id = l.record_id
left join core.v_bed_path bp on bp.bed_id = coalesce(a.bed_id, (d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer)
left join core.v_bed_path bf on bf.bed_id = coalesce((d.j ->> 'bed_id')::integer, (d.j #>> '{from,bed_id}')::integer, a.bed_id)
left join core.v_bed_path bt on bt.bed_id = (d.j #>> '{to,bed_id}')::integer
left join core.sites s on s.site_id = (d.j #>> '{to,site_id}')::integer;

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
    else lower(p_action) || ' on ' || p_table
  end
$$;

drop function api.fn_add_outage(text, integer, date, date, text);
drop function api.fn_book_external(text, text, integer[], date, date);

reset role;
