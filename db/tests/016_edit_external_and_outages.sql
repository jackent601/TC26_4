-- Changing external bookings and outages (migration 0019, D39), on the DEMO
-- sample data. w0 is the Monday two weeks ago. BK-4471 is an external booking in
-- Room 104 bed B; Room 203 is out of action w0+10 to w0+20 (Heating failure);
-- Block B Floor 1 is out of action w0+21 to w0+28 (Fire alarm upgrade), where
-- BK-4519 (w0+3 to w0+10) and BK-4530 (w0+22 to w0+25) are in Room B101 bed A.
begin;
create extension pgtap;
select plan(19);

select api.use_tenant('DEMO');
select count(*) from api.reset_demo_data();
select set_config('app.user', 'Phil', true);

select date_trunc('week', current_date - 14)::date as w0 \gset
select allocation_id as bk from core.allocations where tenant_id = core.current_tenant_id() and external_ref = 'BK-4471' \gset
select min(allocation_id) as course_alloc from core.allocations where tenant_id = core.current_tenant_id() and course_id is not null \gset
select loc_attr_id as heating from core.location_attributes where tenant_id = core.current_tenant_id() and comments = 'Heating failure' \gset
select loc_attr_id as alarm from core.location_attributes where tenant_id = core.current_tenant_id() and comments = 'Fire alarm upgrade' \gset
select site_id as nc from core.sites where tenant_id = core.current_tenant_id() and code = 'NC' \gset
select to_char(:'w0'::date + 3, 'DD/MM') as d3, to_char(:'w0'::date + 5, 'DD/MM') as d5, to_char(:'w0'::date + 10, 'DD/MM') as d10,
       to_char(:'w0'::date + 20, 'DD/MM') as d20, to_char(:'w0'::date + 22, 'DD/MM') as d22, to_char(:'w0'::date + 25, 'DD/MM') as d25,
       to_char(:'w0'::date + 28, 'DD/MM') as d28 \gset

----------------------------- fn_update_external -----------------------------
select results_eq(format($$ select external_ref, external_name from api.fn_update_external(%s, ' BK-4471A ', ' Assessors ') $$, :bk),
                  $$ values ('BK-4471A', 'Assessors') $$, 'an external booking''s reference and name change, trimmed');
select results_eq(format($$ select external_ref::text, external_name::text from core.allocations where allocation_id = %s $$, :bk),
                  $$ values ('BK-4471A', 'Assessors') $$, 'and are saved');
select is((select summary from api.audit where allocation_id = :bk order by audit_id desc limit 1),
          'changed BK-4471''s booking in Room 104 bed B: reference to BK-4471A, name to Assessors', 'audited as a sentence');
select results_eq(format($$ select external_ref, external_name from api.fn_update_external(%s, p_name => 'Visiting assessors') $$, :bk),
                  $$ values ('BK-4471A', 'Visiting assessors') $$, 'null keeps a value');
select throws_ok(format($$ select * from api.fn_update_external(%s, 'X') $$, :course_alloc),
                 'P0001', 'Only an external booking has a reference and name', 'not for a course booking');
select throws_ok(format($$ select * from api.fn_update_external(%s, 'BK-4471A') $$, :bk),
                 'P0001', 'Nothing to change', 'nothing to change');
select throws_ok(format($$ select * from api.fn_update_external(%s, '  ') $$, :bk),
                 'P0001', 'Enter the booking reference', 'the reference can''t be emptied');

------------------------------ fn_update_outage ------------------------------
-- Block B Floor 1 from w0+5: now also over BK-4519.
select is((select warnings from api.fn_update_outage(:alarm, :'w0'::date + 5)),
          array[format('BK-4519 in Room B101 bed A (%s to %s) is in an out-of-action bed', :'d3', :'d10'),
                format('BK-4530 in Room B101 bed A (%s to %s) is in an out-of-action bed', :'d22', :'d25')],
          'changing an outage''s dates warns about every booking it lands on');
select results_eq(format($$ select valid_from, valid_to, comments::text from core.location_attributes where loc_attr_id = %s $$, :alarm),
                  format($$ values (%L::date, %L::date, 'Fire alarm upgrade') $$, (:'w0'::date + 5), (:'w0'::date + 28)),
                  'only the start date changed');
select results_eq(format($$ select summary, site_id from api.audit where table_name = 'location_attributes' and record_id = %s
                             order by audit_id desc limit 1 $$, :alarm),
                  format($$ values ('changed the outage on Block B Floor 1: dates to %s to %s (2 warnings)', %s) $$, :'d5', :'d28', :nc),
                  'audited as a sentence, at its site');
select is((select cardinality(warnings) from api.fn_update_outage(:heating, p_reason => ' Boiler replaced ')), 0, 'the reason can change alone');
select is((select summary from api.audit where table_name = 'location_attributes' and record_id = :heating order by audit_id desc limit 1),
          'changed the outage on Room 203: reason to Boiler replaced', 'and says so');
select throws_ok(format($$ select * from api.fn_update_outage(%s, p_reason => 'Boiler replaced') $$, :heating),
                 'P0001', 'Nothing to change', 'nothing to change');
select throws_ok(format($$ select * from api.fn_update_outage(%s, %L, %L) $$, :heating, (:'w0'::date + 20), (:'w0'::date + 20)),
                 'P0001', 'p_to must be after p_from', 'the end must be after the start');
select throws_ok(format($$ select * from api.fn_update_outage(%s, p_reason => ' ') $$, :heating),
                 'P0001', 'Enter a reason', 'the reason can''t be emptied');

------------------------------ fn_remove_outage ------------------------------
select count(*) from api.fn_remove_outage(:heating);
select is((select count(*)::int from core.location_attributes where loc_attr_id = :heating), 0, 'removing an outage deletes it');
select is((select summary from api.audit where table_name = 'location_attributes' and record_id = :heating order by audit_id desc limit 1),
          format('removed the outage on Room 203 (%s to %s: Boiler replaced)', :'d10', :'d20'), 'the audit keeps what it was');

------------------------------ Tenant isolation ------------------------------
select api.use_tenant('LIVE');
select throws_ok(format($$ select * from api.fn_update_outage(%s, p_reason => 'x') $$, :alarm),
                 'P0001', 'Unknown outage', 'LIVE can''t change a DEMO outage');
select throws_ok(format($$ select * from api.fn_update_external(%s, 'x') $$, :bk),
                 'P0001', 'Unknown allocation', 'or a DEMO external booking');

select * from finish();
rollback;
