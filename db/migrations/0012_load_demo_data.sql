-- migrate:up
--------------------------------------------------------------------------------
-- 0012: new installs come with the DEMO tenant's sample data (D34).
--
-- Loads core.load_sample_data (migration 0004) into the DEMO tenant, but only
-- if DEMO has no beds yet, so an existing database (or demo data someone has
-- been using) is left alone. LIVE never gets sample data (D25). Dates are
-- relative to the day this runs; "Reset demo data" (api.reset_demo_data) or
-- scripts/db-seed.sh reloads them relative to today.
--------------------------------------------------------------------------------
set local role app_owner;

do $$
declare
  v_demo integer;
begin
  select tenant_id into v_demo from core.tenants where code = 'DEMO' and is_demo = 'Y';
  if v_demo is not null then
    -- Row-level security shows one tenant at a time.
    perform set_config('app.tenant_id', v_demo::text, true);
    if not exists (select 1 from core.beds where tenant_id = v_demo) then
      perform core.load_sample_data(v_demo);
    end if;
    perform set_config('app.tenant_id', '', true);
  end if;
end
$$;

reset role;

-- migrate:down
-- Removes the DEMO tenant's sample data (estate, courses and bookings),
-- children first. Its reference data (attribute types, rules) and audit log
-- stay, as before this migration.
set local role app_owner;

do $$
declare
  v_demo integer;
begin
  select tenant_id into v_demo from core.tenants where code = 'DEMO' and is_demo = 'Y';
  if v_demo is not null then
    perform set_config('app.tenant_id', v_demo::text, true);
    delete from core.allocations                  where tenant_id = v_demo;
    delete from core.course_individual_attributes where tenant_id = v_demo;
    delete from core.course_attributes            where tenant_id = v_demo;
    delete from core.courses                      where tenant_id = v_demo;
    delete from core.location_attributes          where tenant_id = v_demo;
    delete from core.beds                         where tenant_id = v_demo;
    delete from core.rooms                        where tenant_id = v_demo;
    delete from core.floors                       where tenant_id = v_demo;
    delete from core.blocks                       where tenant_id = v_demo;
    delete from core.buildings                    where tenant_id = v_demo;
    delete from core.sites                        where tenant_id = v_demo;
    perform set_config('app.tenant_id', '', true);
  end if;
end
$$;

reset role;
