-- migrate:up
--------------------------------------------------------------------------------
-- 0015: the audit trail as users see it (D37).
--
--   core.audit_log.request_id    groups the rows of one user action; set per
--                                request by api_internal.pre_request
--   api.audit                    one row per change with a summary sentence
--                                written in SQL ("booked FIN-03 into Room 101
--                                bed A, 23/11 to 28/11"); filter by course,
--                                allocation, user, site or time with PostgREST
--   api.audit_requests           one row per request: six beds booked at once
--                                read as "booked 6 beds for FIN-03, ..."
--   api_internal.audit_summary   the wording, next to the functions that write
--                                the detail it reads
--
-- Names in summaries (course codes, bed names, sites) are resolved when read,
-- from the current rows, falling back to the id when a row has gone. The log
-- itself is unchanged apart from request_id: it stays standalone, with no
-- foreign keys. Immutability and token-based identity are later hardening.
--------------------------------------------------------------------------------
set local role app_owner;

alter table core.audit_log add column request_id uuid;
create index audit_tenant_time_ix on core.audit_log (tenant_id, changed_at desc);
create index audit_record_ix on core.audit_log (table_name, record_id);

-- The pre-request hook also gives each request an id for its audit rows.
create or replace function api_internal.pre_request()
returns void
language plpgsql security definer
set search_path = pg_catalog, core
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_tenant  text := nullif(v_headers ->> 'x-tenant', '');
  v_user    text := coalesce(nullif(v_headers ->> 'x-user', ''), 'anonymous');
begin
  perform set_config('app.user', v_user, true);
  perform set_config('app.request_id', gen_random_uuid()::text, true);
  if v_tenant is not null then
    perform api.use_tenant(v_tenant);       -- raises 'Unknown tenant: ...' if not found
  end if;
end
$$;

-- Audit rows carry the request id (null when written outside a request).
create or replace function api_internal.audit(p_table text, p_record integer, p_course integer,
                                              p_individual integer, p_action text, p_detail jsonb)
returns void
language sql
set search_path = pg_catalog, core
as $$
  insert into core.audit_log (table_name, record_id, course_id, individual_no, action, detail, changed_by, request_id)
  values (p_table, p_record, p_course, p_individual, p_action, p_detail::text,
          coalesce(nullif(current_setting('app.user', true), ''), 'anonymous'),
          nullif(current_setting('app.request_id', true), '')::uuid);
$$;

-- ============================ Wording helpers ============================

-- The detail column is text; every row written by api_internal.audit is JSON.
create function api_internal.safe_jsonb(p text)
returns jsonb
language plpgsql immutable
as $$
begin
  return p::jsonb;
exception when others then
  return jsonb_build_object('text', p);
end
$$;

-- '2026-11-23' -> '23/11'; null stays null.
create function api_internal.ddmm(p text)
returns text
language sql stable
as $$ select to_char(p::date, 'DD/MM') $$;

-- 'CHECKED_IN' -> 'Checked in'.
create function api_internal.status_name(p text)
returns text
language sql immutable
as $$ select upper(left(p, 1)) || lower(replace(substr(p, 2), '_', ' ')) $$;

-- ' (2 warnings)' when the detail carries warnings; '' otherwise.
create function api_internal.warning_suffix(p jsonb)
returns text
language sql immutable
as $$
  select case when jsonb_typeof(p -> 'warnings') = 'array' and jsonb_array_length(p -> 'warnings') > 0
              then format(' (%s warning%s)', jsonb_array_length(p -> 'warnings'),
                          case when jsonb_array_length(p -> 'warnings') = 1 then '' else 's' end)
              else '' end
$$;

-- The sentence for one audit row, without the user (the reader prepends it).
-- p_course: the course code; p_bed: the bed the row is about (or the bed moved
-- from); p_bed_to: the bed moved to; p_site: the site a course was moved to.
create function api_internal.audit_summary(p_table text, p_action text, p_detail jsonb,
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

-- A view's functions run with the caller's rights (unlike its tables), so the
-- API role needs execute on the wording helpers. They stay out of the API:
-- api_internal is not an exposed schema.
grant execute on function api_internal.safe_jsonb(text), api_internal.ddmm(text), api_internal.status_name(text),
  api_internal.warning_suffix(jsonb), api_internal.audit_summary(text, text, jsonb, text, text, text, text)
  to api_access;

-- ================================ Views =================================

create view api.audit as
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

comment on view api.audit is
  'The audit trail, one row per change: who (changed_by), when (changed_at), what (table_name, record_id, '
  'action) and a summary sentence without the user, e.g. "booked FIN-03 into Room 101 bed A, 23/11 to 28/11". '
  'course_id covers a course and its bookings; allocation_id is set for booking rows; site_id is the bed''s '
  'site, or the course''s. request_id groups the rows of one request (see audit_requests). detail is the raw '
  'JSON; warnings are those the change was saved with. Filter and order with PostgREST (D37).';

create view api.audit_requests as
with rows as (
  select * from api.audit
), grp as (
  select coalesce(r.request_id::text, 'row-' || r.audit_id) as request_key,
         min(r.changed_at) as changed_at, min(r.changed_by) as changed_by, count(*)::integer as changes,
         min(r.course_id) as course_id, min(r.course_code) as course_code, min(r.site_id) as site_id,
         bool_and(r.table_name = 'allocations' and r.action = 'INSERT') as all_bookings,
         min(r.audit_id) as first_id,
         (array_agg(r.summary order by r.audit_id) filter (where r.table_name = 'courses'))[1] as course_summary,
         min(r.detail ->> 'start_date') as start_date, min(r.detail ->> 'end_date') as end_date,
         bool_or(cardinality(r.warnings) > 0) as has_warnings
  from rows r
  group by 1
)
select g.request_key, g.changed_at, g.changed_by, g.changes, g.course_id, g.course_code, g.site_id,
       case when g.changes = 1 then f.summary
            when g.course_summary is not null then g.course_summary
            when g.all_bookings then format('booked %s beds for %s, %s to %s', g.changes, g.course_code,
                                            api_internal.ddmm(g.start_date), api_internal.ddmm(g.end_date))
            else f.summary || format(' (and %s more)', g.changes - 1) end as summary,
       g.has_warnings
from grp g
join rows f on f.audit_id = g.first_id;

comment on view api.audit_requests is
  'The audit trail with the rows of one request rolled into one line, e.g. "booked 6 beds for FIN-03, '
  '23/11 to 28/11" or "cancelled course INT-22 and 4 bookings". request_key matches audit.request_id '
  '(or "row-<audit_id>" for rows written outside a request); changes counts the rows. Filter by course_id, '
  'site_id, changed_by or changed_at with PostgREST (D37).';

reset role;

-- migrate:down
set local role app_owner;
drop view api.audit_requests;
drop view api.audit;
drop function api_internal.audit_summary(text, text, jsonb, text, text, text, text);
drop function api_internal.warning_suffix(jsonb);
drop function api_internal.status_name(text);
drop function api_internal.ddmm(text);
drop function api_internal.safe_jsonb(text);

create or replace function api_internal.audit(p_table text, p_record integer, p_course integer,
                                              p_individual integer, p_action text, p_detail jsonb)
returns void
language sql
set search_path = pg_catalog, core
as $$
  insert into core.audit_log (table_name, record_id, course_id, individual_no, action, detail, changed_by)
  values (p_table, p_record, p_course, p_individual, p_action, p_detail::text,
          coalesce(nullif(current_setting('app.user', true), ''), 'anonymous'));
$$;

create or replace function api_internal.pre_request()
returns void
language plpgsql security definer
set search_path = pg_catalog, core
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_tenant  text := nullif(v_headers ->> 'x-tenant', '');
  v_user    text := coalesce(nullif(v_headers ->> 'x-user', ''), 'anonymous');
begin
  perform set_config('app.user', v_user, true);
  if v_tenant is not null then
    perform api.use_tenant(v_tenant);
  end if;
end
$$;

drop index core.audit_record_ix;
drop index core.audit_tenant_time_ix;
alter table core.audit_log drop column request_id;
reset role;
