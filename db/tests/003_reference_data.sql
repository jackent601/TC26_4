-- Per-tenant reference data (migration 0003).
begin;
create extension pgtap;
select plan(6);

select results_eq($$ select t.code::text, count(a.*)::int from core.tenants t
                      left join core.attribute_types a using (tenant_id) group by t.code order by 1 $$,
                  $$ values ('DEMO', 6), ('LIVE', 6) $$,
                  'each tenant has the 6 starter attribute types');
select results_eq($$ select t.code::text, count(r.*)::int from core.tenants t
                      left join core.rules r using (tenant_id) group by t.code order by 1 $$,
                  $$ values ('DEMO', 6), ('LIVE', 6) $$,
                  'each tenant has the 6 starter rules (5 from 0003, DOUBLE_BOOKING from 0009)');

select is((select inherit_mode || '/' || comment_required from core.attribute_types a
            join core.tenants t using (tenant_id) where t.code = 'LIVE' and a.attr_code = 'OUT_OF_ACTION'),
          'ANY/Y', 'OUT_OF_ACTION applies at any level above a bed and needs a reason');
select is((select severity::text from core.rules r
            join core.tenants t using (tenant_id) where t.code = 'LIVE' and r.rule_code = 'OUT_OF_ACTION'),
          'WARNING', 'allocating into an out-of-action bed is a warning by default (D11)');

select throws_ok($$ insert into core.rules (tenant_id, rule_code, name, rule_type, individual_attr, severity, message)
                    select tenant_id, 'BAD', 'x', 'COMPARE', 'GRADE', 'WARNING', 'x'
                    from core.tenants where code = 'LIVE' $$,
                 '23514', null, 'a COMPARE rule without a location attribute is rejected');
select throws_ok($$ insert into core.rules (tenant_id, rule_code, name, rule_type, location_attr, severity, message)
                    select tenant_id, 'BAD', 'x', 'LOCATION_BLOCKS', 'NO_SUCH_ATTR', 'WARNING', 'x'
                    from core.tenants where code = 'LIVE' $$,
                 '23503', null, 'a rule cannot use an attribute the tenant does not have');

select * from finish();
rollback;
