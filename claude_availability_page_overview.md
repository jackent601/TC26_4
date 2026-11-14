# Availability page: overview for building it

What the availability page must do, as agreed with the user. The clickable mockup is the reference: [`docs/pages_pocs/availability.html`](docs/pages_pocs/availability.html) (opens offline in any browser; notes in [`docs/pages_pocs/README.md`](docs/pages_pocs/README.md)). Decision numbers refer to [`docs/decisions.md`](docs/decisions.md).

Remember the principles in `CLAUDE.md`: the page only displays data and calls the API. Anything that decides what is allowed (clashes, rules, warnings) comes from the database. Display preferences (colour thresholds, how many weeks to show) belong to the user's view.

## Purpose

See which beds are free, allocated or out of action across the estate, night by night, and allocate beds to courses, usually in whole weeks and often as a group.

## Layout

- **Header:** page title, week navigation (previous / next week and the date range shown), Expand all, Collapse to floors, the **Colour by: Scheduled | Loaded** switch, and the LIVE / DEMO tenant switch with a "DEMO DATA" banner when on DEMO (D24, D25).
- **Legend:** free, out of action (hatched), allocated in green / amber / red (with the current thresholds and basis), external booking, and the two warning icons.
- **Warnings strip:** see Warnings below.
- **Grid:**
  - **Left:** a collapsible tree, Site > Building > Block > Floor > Room > Bed. Beds are the rows. Group rows show their level and bed count. Block is kept even when a building has one block (D28).
  - **Body:** one column per night; week lines and weekend shading.
  - **Bottom axis:** "week commencing" dates (DD/MM), one tick per week, which stays visible while scrolling.
- **Popups** open on click (see Interactions). The edit forms inside them are still to be designed.

## What each row shows

**Bed rows** show bars across the nights:

| Bar | Look | Label |
|---|---|---|
| Course allocation | Colour from the course's allocation level (below) | Course code, individual number, allocated / basis, e.g. `SAF-14 #3 · 7/8` |
| External booking | Grey, dashed border (D28) | Reference and name, e.g. `BK-4502 · Contractor` |
| Out of action | Hatched grey, behind allocations | "Out of action", with the level it was set on if not the bed, e.g. "(floor)" |

Extra markers on allocation bars:
- **Red outline and warning triangle:** the booking falls on an out-of-action bed.
- **Purple up-arrow:** the course has loaded > scheduled.

**Collapsed rows** (any level above Bed) show one cell per week with small counts of beds by state: free, out of action, green, amber, red, external. The counts are for the week's **busiest night**, the night with the fewest free beds (the "limiting date"). Clicking the cell opens a breakdown naming that night (D28).

## Colours (D13, D28)

Each course is coloured by how many of its individuals are allocated, compared with a basis:
- **Basis:** `scheduled` (planned headcount) or `loaded` (registered so far), chosen with the **Colour by** switch. Example: SAF-14 has 7 allocated, 8 scheduled and 7 loaded, so it's amber by scheduled and green by loaded.
- **Green:** allocated at or above the green threshold (default 100% of the basis).
- **Amber:** between the thresholds.
- **Red:** below the red threshold (default 80%).
- **Thresholds and basis are per user, set in the UI** (D28). They aren't stored centrally. Since D29 (migration 0007) the API returns facts only: allocated, scheduled, loaded and percentages per course, and beds per course on each week's busiest night. The UI applies the bands to both bars and collapsed rows, so the basis and thresholds are never sent to the API.
- Colours must differ in lightness as well as hue, and every bar has a text label, so the page works without relying on colour.

## Warnings

- **Warnings strip** under the legend, always shown whatever the colour switch says. It lists:
  - courses with loaded > scheduled (D14), e.g. "TEC-07: 12 loaded vs 10 scheduled";
  - bookings in out-of-action beds.

  Clicking an item opens that course or booking.
- **All warnings come from the database** (a warnings view in the `api` schema), never worked out in the UI. Rule warnings (mixed gender, grade, step-free, work pattern) will appear here too once the read functions exist (phase 1).

## Interactions

- **Click a tree row name:** popup with the location's path, bed count and outages; the edit form (location details and dated attributes, including outages) comes later.
- **Click an allocation bar:** popup with course, individual, bed, nights, status, scheduled, loaded (with when it was updated), allocated vs basis with its colour, and any warning. For an external booking: reference, name, nights, status.
- **Click an outage bar:** popup with where it is set, dates, reason, and the bookings it affects.
- **Click a collapsed week cell:** breakdown for the busiest night.
- **Allocating (D8, D9, D10):**
  - **Click an empty part of a bed row** to select that whole week. A week block has its first night on Monday and departure on Sunday: 6 nights, so Sunday night is free (D9, confirmed).
  - **Drag** sideways to select several weeks (first Monday to last Sunday) and down to select several beds. Group rows in between are skipped. A dashed outline shows the selection, with a label like "5 beds · 2 weeks · 16/11 – 29/11".
  - **On release**, a "New allocation" popup lists the beds, shows the first night and departure day (editable to any exact dates), the number of nights, and every clash on those beds (other bookings, outages).
  - **Clashes** are allowed with a warning by default (D11). If clashes are set to block, the popup says "Not allowed" and the Allocate button is disabled. This setting is a database rule severity (open: where it lives), not a user preference, even though the mockup's settings panel has a switch for it.
- **Keyboard:** every bar, row name and week cell is a real button. Activating an empty bed row with the keyboard selects the first visible week.

## Per-user view settings (UI only)

These are kept in the browser, e.g. local storage, not in the database:
- weeks shown (mockup default 6);
- day width;
- Colour by (scheduled or loaded);
- the green and red thresholds;
- which tree nodes are collapsed (mockup default: Floor 3 and Block B collapsed).

## Sample data to expect (DEMO tenant)

The DEMO tenant's data (`core.load_sample_data`, migration 0004) matches the mockup, with dates relative to today:
- five weeks from the Monday two weeks ago;
- 23 beds; courses LDR-01, SAF-14, TEC-07, INT-22, FIN-03;
- four external bookings, one clashing with the Block B floor outage;
- outages on Room 203 and on Block B Floor 1.

It also contains data that triggers the rules: mixed gender in Room 301, a grade below Floor 3's minimum, a step-free need on Floor 2, and a part-timer on a full-time floor.

## What the database needs to provide (phase 1, proposed)

These are the views and functions the page needs, as proposed SQL. They have **not been added as a migration yet**: agree the names first, then put them in a new migration (`0006_availability_read.sql`), wrapped in `set local role app_owner;` … `reset role;`, with a `-- migrate:down` that drops them, `comment on` for each `api` object, pgTAP tests, and an updated contract snapshot.

| Page needs | Object |
|---|---|
| The tree | `api.locations` (key, parent_key, level, id, name, bed_count) |
| Course colours and figures | `api.course_figures` (scheduled, loaded, `loaded_at`, allocated, `loaded_above_scheduled`) |
| Bed rows for the date range | `api.fn_bed_bars(p_from, p_to)`: allocations, external bookings and outages per bed that overlap the range, with an `on_outage` flag. Since 0008 they carry their full dates (popups need them) and the UI fits them to the weeks shown |
| Collapsed-row counts | `api.fn_week_summary(p_from, p_weeks)`: per location and week, the busiest night and its beds by category (free, out of action, external, and per course). Superseded the proposal below that took the basis and thresholds (D29, migration 0007) |
| Warnings strip | `api.warnings`: loaded > scheduled, bookings on out-of-action beds, double bookings |
| New-allocation popup clashes | `api.fn_check_allocation(p_bed_ids, p_from, p_to)`: existing bookings and outages per bed, before anything is saved |

Through PostgREST these become, for example:
```
GET  /api/locations
GET  /api/course_figures
POST /api/rpc/fn_bed_bars           {"p_from": "2026-11-16", "p_to": "2026-12-21"}
POST /api/rpc/fn_week_summary       {"p_from": "2026-11-16", "p_weeks": 5, "p_basis": "loaded", "p_green_at": 100, "p_red_below": 80}
GET  /api/warnings
POST /api/rpc/fn_check_allocation   {"p_bed_ids": [119, 120], "p_from": "2026-11-16", "p_to": "2026-11-22"}
```
The functions are `stable`, so `GET /api/rpc/...?p_from=...` also works.

### Tested

All of these were run on the DEMO sample data in PostgreSQL 16, as the `api_access` role with the DEMO tenant selected, the same way PostgREST runs them:
- **Locations:** 1 site, 1 building, 2 blocks, 4 floors, 13 rooms and 23 beds, with the site's bed count 23.
- **Course figures:** match the mockup, and TEC-07 is flagged as loaded above scheduled.
- **Bars over the five weeks:** 22 course allocations, 4 external bookings and 6 outage bars (Room 203's 2 beds, and Block B Floor 1's 4 beds). BK-4530 is flagged as on an outage.
- **Week summary:**
  - Block B Floor 1 is all out of action in the outage week;
  - Floor 3 is red while TEC-07 runs (5 of 10 allocated);
  - SAF-14's 7 beds count as amber by scheduled and green by loaded.
- **Warnings:** "TEC-07: 12 loaded vs 10 scheduled" and "BK-4530 is in an out-of-action bed (Room B101 bed A)".
- **Clash check** for Room B101 in the outage week: the floor outage on both beds, plus BK-4530 on bed A.
- **On LIVE:** nothing is visible.

### Notes

- **Helpers:** `core.v_bed_path` (every bed with its ancestors) and `core.v_bed_outages` (outages that apply to each bed, inheriting down from any level) are helpers in `core`, not endpoints.
- **Tenant filtering:** row-level security filters every query to the current tenant; nothing in these queries names a tenant.
- **Not included yet:**
  - **Rule warnings** (mixed gender, grade, step-free, work pattern) need the effective attributes per individual and per bed. They are the next part of phase 1, and will be added as more branches of `api.warnings` and as a flag on bars.
  - **Sort order:** `api.locations` doesn't carry `sort_order` yet; join it back from each level's table when the UI needs it.
- **Size:** `fn_week_summary` works through every bed, night and level. That's fine at this scale (23 beds × 35 nights); a larger estate may need it rewritten with set-based joins in place of the per-night subqueries.

### Proposed SQL

```sql
-- Helper: every bed with its ancestors (one row per bed).
create view core.v_bed_path as
select b.tenant_id, b.bed_id, b.code as bed_code,
       r.room_id, r.code as room_code, r.name as room_name,
       f.floor_id, f.name as floor_name,
       bl.block_id, bl.name as block_name,
       bu.building_id, bu.name as building_name,
       s.site_id, s.name as site_name
from core.beds b
join core.rooms r      on r.room_id = b.room_id
join core.floors f     on f.floor_id = r.floor_id
join core.blocks bl    on bl.block_id = f.block_id
join core.buildings bu on bu.building_id = bl.building_id
join core.sites s      on s.site_id = bu.site_id;

-- Helper: outages that apply to each bed (OUT_OF_ACTION inherits down from any level).
create view core.v_bed_outages as
select bp.bed_id, la.loc_attr_id as outage_id, la.valid_from, la.valid_to, la.comments as reason,
       case when la.bed_id is not null then 'Bed' when la.room_id is not null then 'Room'
            when la.floor_id is not null then 'Floor' when la.block_id is not null then 'Block'
            when la.building_id is not null then 'Building' else 'Site' end as set_on_level
from core.v_bed_path bp
join core.location_attributes la
  on la.attr_code = 'OUT_OF_ACTION' and la.attr_value = 'Y'
 and (la.bed_id = bp.bed_id or la.room_id = bp.room_id or la.floor_id = bp.floor_id
      or la.block_id = bp.block_id or la.building_id = bp.building_id or la.site_id = bp.site_id);

-- 1. The tree: one row per location, with parent and bed count.
create view api.locations as
select 'site:' || site_id as key, null::text as parent_key, 'Site' as level, site_id as id,
       min(site_name) as name, count(*) as bed_count
from core.v_bed_path group by site_id
union all
select 'building:' || building_id, 'site:' || site_id, 'Building', building_id, min(building_name), count(*)
from core.v_bed_path group by building_id, site_id
union all
select 'block:' || block_id, 'building:' || building_id, 'Block', block_id, min(block_name), count(*)
from core.v_bed_path group by block_id, building_id
union all
select 'floor:' || floor_id, 'block:' || block_id, 'Floor', floor_id, min(floor_name), count(*)
from core.v_bed_path group by floor_id, block_id
union all
select 'room:' || room_id, 'floor:' || floor_id, 'Room', room_id, min(room_name), count(*)
from core.v_bed_path group by room_id, floor_id
union all
select 'bed:' || bed_id, 'room:' || room_id, 'Bed', bed_id, 'Bed ' || upper(bed_code), 1
from core.v_bed_path;
-- (sort_order: join back to each level's table if the UI needs explicit ordering)

-- 2. Course figures for colouring and the warnings strip.
create view api.course_figures as
select c.course_id, c.code, c.name, c.start_date, c.end_date, c.status,
       c.scheduled, c.loaded, c.loaded_at,
       count(distinct a.individual_no) filter (where a.status <> 'CANCELLED') as allocated,
       c.loaded > c.scheduled as loaded_above_scheduled
from core.courses c
left join core.allocations a on a.course_id = c.course_id
group by c.course_id;

-- 3. Bars for every bed in a date range: allocations, external bookings, outages.
--    Dates are clipped to the range; on_outage flags a booking on an out-of-action bed.
create function api.fn_bed_bars(p_from date, p_to date)
returns table (bed_id integer, kind text, id integer, start_date date, end_date date,
               course_id integer, course_code text, individual_no integer,
               external_ref text, external_name text, status text,
               set_on_level text, reason text, on_outage boolean)
language sql stable security definer
set search_path = pg_catalog, core
as $$
  select a.bed_id,
         case when a.course_id is null then 'external' else 'allocation' end,
         a.allocation_id, greatest(a.start_date, p_from), least(a.end_date, p_to),
         a.course_id, c.code::text, a.individual_no, a.external_ref::text, a.external_name::text,
         a.status::text, null, null,
         exists (select 1 from core.v_bed_outages o
                  where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.status <> 'CANCELLED' and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'outage', o.outage_id, greatest(o.valid_from, p_from), least(o.valid_to, p_to),
         null, null, null, null, null, null, o.set_on_level, o.reason::text, null
  from core.v_bed_outages o
  where o.valid_from < p_to and p_from < o.valid_to
  order by 1, 4
$$;

-- 4. Collapsed rows: per location and week, the busiest night (fewest free beds)
--    and its counts by state. Basis and thresholds are the user's view settings.
create function api.fn_week_summary(p_from date, p_weeks integer,
                                    p_basis text default 'scheduled',
                                    p_green_at numeric default 100, p_red_below numeric default 80)
returns table (key text, week_start date, busiest_night date,
               free bigint, out_of_action bigint, green bigint, amber bigint, red bigint, external bigint)
language sql stable security definer
set search_path = pg_catalog, core
as $$
  with nights as (
    select (p_from + n)::date as night from generate_series(0, p_weeks * 7 - 1) n
  ), course_colour as (
    select course_id,
           case when basis = 0 or allocated * 100.0 / basis >= p_green_at then 'green'
                when allocated * 100.0 / basis < p_red_below then 'red' else 'amber' end as colour
    from (select course_id, allocated,
                 case when p_basis = 'loaded' then loaded else scheduled end as basis
          from api.course_figures) x
  ), bed_night as (
    select bp.*, n.night,
           case
             when exists (select 1 from core.v_bed_outages o
                           where o.bed_id = bp.bed_id and o.valid_from <= n.night and n.night < o.valid_to)
               then 'out'
             else coalesce((select case when a.course_id is null then 'external' else cc.colour end
                              from core.allocations a
                              left join course_colour cc on cc.course_id = a.course_id
                             where a.bed_id = bp.bed_id and a.status <> 'CANCELLED'
                               and a.start_date <= n.night and n.night < a.end_date
                             order by a.allocation_id limit 1), 'free')
           end as state
    from core.v_bed_path bp cross join nights n
  ), per_location as (
    select k.key, bn.night, bn.state
    from bed_night bn
    cross join lateral (values ('site:' || bn.site_id), ('building:' || bn.building_id),
                               ('block:' || bn.block_id), ('floor:' || bn.floor_id),
                               ('room:' || bn.room_id)) k(key)
  ), counts as (
    select key, night, p_from + ((night - p_from) / 7) * 7 as week_start,
           count(*) filter (where state = 'free')     as free,
           count(*) filter (where state = 'out')      as out_of_action,
           count(*) filter (where state = 'green')    as green,
           count(*) filter (where state = 'amber')    as amber,
           count(*) filter (where state = 'red')      as red,
           count(*) filter (where state = 'external') as external
    from per_location group by key, night
  )
  select distinct on (key, week_start)
         key, week_start, night, free, out_of_action, green, amber, red, external
  from counts
  order by key, week_start, free, night
$$;

-- 5. Warnings strip (always shown). Rule warnings (gender, grade, step-free,
--    work pattern) to be added in phase 1 as further union branches.
create view api.warnings as
select 'LOADED_ABOVE_SCHEDULED' as kind, 'WARNING' as severity,
       cf.code || ': ' || cf.loaded || ' loaded vs ' || cf.scheduled || ' scheduled' as message,
       cf.course_id, null::integer as allocation_id, null::integer as bed_id,
       cf.start_date, cf.end_date
from api.course_figures cf
where cf.loaded_above_scheduled
union all
select 'OUT_OF_ACTION', r.severity,
       coalesce(c.code || ' #' || a.individual_no, a.external_ref) || ' is in an out-of-action bed ('
         || bp.room_name || ' bed ' || upper(bp.bed_code) || ')',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
left join core.courses c on c.course_id = a.course_id
join core.rules r on r.rule_code = 'OUT_OF_ACTION' and r.active = 'Y'
where a.status <> 'CANCELLED'
  and exists (select 1 from core.v_bed_outages o
               where o.bed_id = a.bed_id and o.valid_from < a.end_date and a.start_date < o.valid_to)
union all
select 'DOUBLE_BOOKING', 'WARNING',
       'Bed ' || bp.room_name || ' ' || upper(bp.bed_code) || ' is double-booked',
       a.course_id, a.allocation_id, a.bed_id, a.start_date, a.end_date
from core.allocations a
join core.v_bed_path bp on bp.bed_id = a.bed_id
where a.status <> 'CANCELLED'
  and exists (select 1 from core.allocations b
               where b.bed_id = a.bed_id and b.allocation_id <> a.allocation_id and b.status <> 'CANCELLED'
                 and b.start_date < a.end_date and a.start_date < b.end_date);

-- 6. Clashes for the "New allocation" popup, before anything is saved.
create function api.fn_check_allocation(p_bed_ids integer[], p_from date, p_to date)
returns table (bed_id integer, kind text, ref text, start_date date, end_date date, message text)
language sql stable security definer
set search_path = pg_catalog, core
as $$
  select a.bed_id, 'BOOKING',
         coalesce(c.code || ' #' || a.individual_no, a.external_ref::text),
         a.start_date, a.end_date, 'Already booked for some of these nights'
  from core.allocations a
  left join core.courses c on c.course_id = a.course_id
  where a.bed_id = any(p_bed_ids) and a.status <> 'CANCELLED'
    and a.start_date < p_to and p_from < a.end_date
  union all
  select o.bed_id, 'OUT_OF_ACTION', o.reason::text, o.valid_from, o.valid_to,
         'Out of action (' || lower(o.set_on_level) || ') for some of these nights'
  from core.v_bed_outages o
  where o.bed_id = any(p_bed_ids) and o.valid_from < p_to and p_from < o.valid_to
  order by 1, 4
$$;
```

## Still open

- Where the "clashes block" setting lives (D11).
- The edit forms inside each popup.
- Status order (Allocated → Booked, or the reverse).
