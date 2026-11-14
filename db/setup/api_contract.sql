-- The API contract (decisions D22, D27): every view and function in the api
-- schema with its columns, arguments, result and description. PostgREST builds
-- the API from exactly this, so a change here is a change to the API.
-- Used by scripts/api-contract.sh. Output is sorted and stable.
select line from (
  select 'view api.' || c.relname as key,
         'view api.' || c.relname
         || coalesce(E'\n  -- ' || obj_description(c.oid, 'pg_class'), '')
         || E'\n' || string_agg('  ' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod), E'\n' order by a.attnum)
         || E'\n' as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'api' and c.relkind in ('v', 'm', 'r')
  group by c.oid, c.relname
  union all
  select 'function api.' || p.proname,
         'function api.' || p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
         || coalesce(E'\n  -- ' || obj_description(p.oid, 'pg_proc'), '')
         || E'\n  returns ' || pg_get_function_result(p.oid) || E'\n'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
) x
order by key;
