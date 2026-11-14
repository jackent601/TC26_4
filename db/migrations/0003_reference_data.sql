-- migrate:up
--------------------------------------------------------------------------------
-- 0003: tenants and their reference data (attribute types and rules).
--
-- Reference data is per tenant, so each tenant (and the demo) can change its
-- own rules. core.load_reference_data(tenant_id) installs the starter set into
-- one tenant; it is also used when a new tenant is added and by the demo reset.
--
-- Rule direction for COMPARE: <individual value> <operator> <location value>.
-- Severity: BLOCK stops an allocation; WARNING and INFO save with a warning.
-- OUT_OF_ACTION is WARNING by default (decision D11: allowed with a warning);
-- set it to BLOCK to forbid allocating into out-of-action beds.
--------------------------------------------------------------------------------
set local role app_owner;

create function core.load_reference_data(p_tenant_id integer)
returns void
language plpgsql
set search_path = pg_catalog, core
as $$
declare
  v_prev text := current_setting('app.tenant_id', true);
begin
  -- Row-level security only accepts rows for the current tenant.
  perform set_config('app.tenant_id', p_tenant_id::text, true);

  insert into core.attribute_types
    (tenant_id, attr_code, name, description, applies_to, data_type, inherit_mode, allow_overlap, comment_required)
  values
    (p_tenant_id, 'OUT_OF_ACTION', 'Out of action',
     'Location cannot be used (repairs, closure). Set at any level; applies to every bed below. Reason goes in comments.',
     'LOCATION', 'FLAG', 'ANY', 'N', 'Y'),
    (p_tenant_id, 'GENDER', 'Gender',
     'Individual''s gender, used to avoid mixed-gender rooms.',
     'INDIVIDUAL', 'TEXT', 'NEAREST', 'N', 'N'),
    (p_tenant_id, 'GRADE', 'Grade',
     'Individual''s seniority grade (higher number = more senior).',
     'INDIVIDUAL', 'NUMBER', 'NEAREST', 'N', 'N'),
    (p_tenant_id, 'MIN_GRADE', 'Minimum grade',
     'Lowest grade a location is intended for. Nearest setting wins, so a room can override its floor.',
     'LOCATION', 'NUMBER', 'NEAREST', 'N', 'N'),
    (p_tenant_id, 'STEP_FREE', 'Step-free access',
     'On an individual: needs step-free access. On a location: has step-free access.',
     'BOTH', 'FLAG', 'NEAREST', 'N', 'N'),
    (p_tenant_id, 'WORK_PATTERN', 'Work pattern',
     'FT (full-time) or PT (part-time).',
     'INDIVIDUAL', 'TEXT', 'NEAREST', 'N', 'N');

  insert into core.rules
    (tenant_id, rule_code, name, rule_type, individual_attr, location_attr, operator, scope, severity, active, message)
  values
    (p_tenant_id, 'OUT_OF_ACTION', 'Bed is out of action', 'LOCATION_BLOCKS',
     null, 'OUT_OF_ACTION', null, null, 'WARNING', 'Y',
     'This bed is out of action for some or all of these nights.'),
    (p_tenant_id, 'NO_MIXED_GENDER', 'No mixed-gender rooms', 'MATCH_WITHIN',
     'GENDER', null, null, 'ROOM', 'WARNING', 'Y',
     'This room would have occupants of different genders.'),
    (p_tenant_id, 'GRADE_SUITABLE', 'Room suits the individual''s grade', 'COMPARE',
     'GRADE', 'MIN_GRADE', '>=', null, 'WARNING', 'Y',
     'This room is intended for a higher grade.'),
    (p_tenant_id, 'STEP_FREE_NEEDED', 'Step-free access where needed', 'REQUIRES',
     'STEP_FREE', 'STEP_FREE', null, null, 'WARNING', 'Y',
     'This individual needs step-free access and this location does not have it.'),
    (p_tenant_id, 'WORK_PATTERN_FLOOR', 'Keep full-time and part-time apart', 'MATCH_WITHIN',
     'WORK_PATTERN', null, null, 'FLOOR', 'INFO', 'Y',
     'Full-time and part-time individuals would share this floor.');

  perform set_config('app.tenant_id', coalesce(v_prev, ''), true);
end
$$;

-- The two starting tenants. More can be added later (e.g. one per team):
-- insert a row, then select core.load_reference_data(<its tenant_id>).
insert into core.tenants (code, name, is_demo) values
  ('LIVE', 'Live',                 'N'),
  ('DEMO', 'Demo (sample data)',   'Y');

select core.load_reference_data(tenant_id) from core.tenants order by tenant_id;

reset role;

-- migrate:down
-- Removes the tenants, so all of their data goes too (children first).
-- Runs as the migration (superuser) login, which bypasses row-level security.
delete from core.allocations;
delete from core.course_individual_attributes;
delete from core.course_attributes;
delete from core.courses;
delete from core.location_attributes;
delete from core.beds;
delete from core.rooms;
delete from core.floors;
delete from core.blocks;
delete from core.buildings;
delete from core.sites;
delete from core.rules;
delete from core.attribute_types;
delete from core.audit_log;
delete from core.tenants;
drop function core.load_reference_data(integer);
