-- migrate:up
--------------------------------------------------------------------------------
-- 0003: reference data the product needs to run: attribute types and rules.
-- A starter set based on the team's examples; edit or extend in a later
-- migration (or, once built, through the admin page).
--
-- Rule direction for COMPARE: <individual value> <operator> <location value>.
-- Severity: BLOCK stops an allocation; WARNING and INFO save with a warning.
-- OUT_OF_ACTION is WARNING by default (decision D11: allowed with a warning);
-- set it to BLOCK to forbid allocating into out-of-action beds.
--------------------------------------------------------------------------------
insert into core.attribute_types
  (attr_code, name, description, applies_to, data_type, inherit_mode, allow_overlap, comment_required)
values
  ('OUT_OF_ACTION', 'Out of action',
   'Location cannot be used (repairs, closure). Set at any level; applies to every bed below. Reason goes in comments.',
   'LOCATION', 'FLAG', 'ANY', 'N', 'Y'),
  ('GENDER', 'Gender',
   'Individual''s gender, used to avoid mixed-gender rooms.',
   'INDIVIDUAL', 'TEXT', 'NEAREST', 'N', 'N'),
  ('GRADE', 'Grade',
   'Individual''s seniority grade (higher number = more senior).',
   'INDIVIDUAL', 'NUMBER', 'NEAREST', 'N', 'N'),
  ('MIN_GRADE', 'Minimum grade',
   'Lowest grade a location is intended for. Nearest setting wins, so a room can override its floor.',
   'LOCATION', 'NUMBER', 'NEAREST', 'N', 'N'),
  ('STEP_FREE', 'Step-free access',
   'On an individual: needs step-free access. On a location: has step-free access.',
   'BOTH', 'FLAG', 'NEAREST', 'N', 'N'),
  ('WORK_PATTERN', 'Work pattern',
   'FT (full-time) or PT (part-time).',
   'INDIVIDUAL', 'TEXT', 'NEAREST', 'N', 'N');

insert into core.rules
  (rule_code, name, rule_type, individual_attr, location_attr, operator, scope, severity, active, message)
values
  ('OUT_OF_ACTION', 'Bed is out of action', 'LOCATION_BLOCKS',
   null, 'OUT_OF_ACTION', null, null, 'WARNING', 'Y',
   'This bed is out of action for some or all of these nights.'),
  ('NO_MIXED_GENDER', 'No mixed-gender rooms', 'MATCH_WITHIN',
   'GENDER', null, null, 'ROOM', 'WARNING', 'Y',
   'This room would have occupants of different genders.'),
  ('GRADE_SUITABLE', 'Room suits the individual''s grade', 'COMPARE',
   'GRADE', 'MIN_GRADE', '>=', null, 'WARNING', 'Y',
   'This room is intended for a higher grade.'),
  ('STEP_FREE_NEEDED', 'Step-free access where needed', 'REQUIRES',
   'STEP_FREE', 'STEP_FREE', null, null, 'WARNING', 'Y',
   'This individual needs step-free access and this location does not have it.'),
  ('WORK_PATTERN_FLOOR', 'Keep full-time and part-time apart', 'MATCH_WITHIN',
   'WORK_PATTERN', null, null, 'FLOOR', 'INFO', 'Y',
   'Full-time and part-time individuals would share this floor.');

-- migrate:down
delete from core.rules where rule_code in
  ('OUT_OF_ACTION', 'NO_MIXED_GENDER', 'GRADE_SUITABLE', 'STEP_FREE_NEEDED', 'WORK_PATTERN_FLOOR');
delete from core.attribute_types where attr_code in
  ('OUT_OF_ACTION', 'GENDER', 'GRADE', 'MIN_GRADE', 'STEP_FREE', 'WORK_PATTERN');
