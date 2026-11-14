# Accommodation allocation MVP: v2 data model

14 tables in five groups. Structure only; the full definitions, including checks and indexes, are in [`0001_schema.sql`](../src/db/migrations/0001_schema.sql).

| Group | Tables |
|---|---|
| Supply | `SITES` > `BUILDINGS` > `BLOCKS` > `FLOORS` > `ROOMS` > `BEDS`, plus `LOCATION_ATTRIBUTES` |
| Vocabulary and rules | `ATTRIBUTE_TYPES`, `RULES` |
| Demand | `COURSES`, `COURSE_ATTRIBUTES`, `COURSE_INDIVIDUAL_ATTRIBUTES` |
| Allocation | `ALLOCATIONS` |
| Audit | `AUDIT_LOG` (standalone, no relationships) |

## Entity relationship diagram

```mermaid
%% Relationships read parent ||--o{ child. o| = optional (nullable FK).
%% LOCATION_ATTRIBUTES: each row is linked to exactly ONE of the six estate levels.
%% AUDIT_LOG is standalone (no relationships).
erDiagram
    %% ---------- Supply: estate hierarchy ----------
    SITES     ||--o{ BUILDINGS : contains
    BUILDINGS ||--o{ BLOCKS    : contains
    BLOCKS    ||--o{ FLOORS    : contains
    FLOORS    ||--o{ ROOMS     : contains
    ROOMS     ||--o{ BEDS      : contains

    %% ---------- Supply: location attributes (one level per row) ----------
    SITES     |o--o{ LOCATION_ATTRIBUTES : "has attributes"
    BUILDINGS |o--o{ LOCATION_ATTRIBUTES : "has attributes"
    BLOCKS    |o--o{ LOCATION_ATTRIBUTES : "has attributes"
    FLOORS    |o--o{ LOCATION_ATTRIBUTES : "has attributes"
    ROOMS     |o--o{ LOCATION_ATTRIBUTES : "has attributes"
    BEDS      |o--o{ LOCATION_ATTRIBUTES : "has attributes"

    %% ---------- Vocabulary ----------
    ATTRIBUTE_TYPES ||--o{ LOCATION_ATTRIBUTES          : "attr_code"
    ATTRIBUTE_TYPES ||--o{ COURSE_ATTRIBUTES            : "attr_code"
    ATTRIBUTE_TYPES ||--o{ COURSE_INDIVIDUAL_ATTRIBUTES : "attr_code"
    ATTRIBUTE_TYPES |o--o{ RULES                        : "individual_attr, location_attr"

    %% ---------- Demand ----------
    SITES   |o--o{ COURSES                      : hosts
    COURSES ||--o{ COURSE_ATTRIBUTES            : "default attributes"
    COURSES ||--o{ COURSE_INDIVIDUAL_ATTRIBUTES : "individual attributes"

    %% ---------- Allocation ----------
    COURSES |o--o{ ALLOCATIONS : "course_id (null = external)"
    BEDS    ||--o{ ALLOCATIONS : "occupied by"

    SITES {
        int     site_id PK
        varchar code UK
        varchar name
        int     sort_order
    }
    BUILDINGS {
        int     building_id PK
        int     site_id FK
        varchar code "unique within site"
        varchar name
        int     sort_order
    }
    BLOCKS {
        int     block_id PK
        int     building_id FK
        varchar code "unique within building"
        varchar name
        int     sort_order
    }
    FLOORS {
        int     floor_id PK
        int     block_id FK
        varchar code "unique within block"
        varchar name
        int     sort_order
    }
    ROOMS {
        int     room_id PK
        int     floor_id FK
        varchar code "unique within floor"
        varchar name
        int     sort_order
    }
    BEDS {
        int     bed_id PK
        int     room_id FK
        varchar code "unique within room"
    }
    LOCATION_ATTRIBUTES {
        int     loc_attr_id PK
        varchar attr_code FK
        varchar attr_value
        date    valid_from
        date    valid_to "exclusive"
        varchar comments "outage reason when OUT_OF_ACTION"
        int     site_id FK "exactly one of the six level FKs is set"
        int     building_id FK
        int     block_id FK
        int     floor_id FK
        int     room_id FK
        int     bed_id FK
    }
    ATTRIBUTE_TYPES {
        varchar attr_code PK
        varchar name
        varchar description
        varchar applies_to "LOCATION | INDIVIDUAL | BOTH"
        varchar data_type "TEXT | NUMBER | FLAG"
        varchar inherit_mode "NEAREST | ANY"
        char    allow_overlap "Y | N"
        char    comment_required "Y | N"
    }
    RULES {
        varchar rule_code PK
        varchar name
        varchar rule_type "COMPARE | REQUIRES | MATCH_WITHIN | SOLE_USE | LOCATION_BLOCKS"
        varchar individual_attr FK "null for LOCATION_BLOCKS"
        varchar location_attr FK
        varchar operator ">= | <= | ="
        varchar scope "ROOM | FLOOR | BLOCK"
        varchar severity "BLOCK | WARNING | INFO"
        char    active "Y | N"
        varchar message
    }
    COURSES {
        int     course_id PK
        varchar code UK
        varchar name
        int     site_id FK "optional"
        date    start_date
        date    end_date
        int     est_attendees "individuals are numbered 1..est_attendees"
        varchar status "REQUESTED | CONFIRMED | CANCELLED"
        varchar notes
    }
    COURSE_ATTRIBUTES {
        int     course_id PK,FK
        varchar attr_code PK,FK
        varchar attr_value "default for every individual"
    }
    COURSE_INDIVIDUAL_ATTRIBUTES {
        int     course_id PK,FK
        int     individual_no PK "anonymous, 1..est_attendees"
        varchar attr_code PK,FK
        varchar attr_value "overrides the course default"
    }
    ALLOCATIONS {
        int       allocation_id PK
        int       course_id FK "null with individual_no = external booking"
        int       individual_no "not a FK: no individuals table"
        int       bed_id FK
        date      start_date "first night"
        date      end_date "departure day, exclusive"
        varchar   status "ALLOCATED | BOOKED | CHECKED_IN | CHECKED_OUT | NO_SHOW | CANCELLED"
        timestamp checked_in_at
        timestamp checked_out_at
        varchar   source "LOCAL | EXTERNAL"
        varchar   external_ref
        varchar   external_name
        timestamp created_at
    }
    AUDIT_LOG {
        int       audit_id PK
        varchar   table_name
        int       record_id
        int       course_id "lookup only, no FK"
        int       individual_no "lookup only, no FK"
        varchar   action
        varchar   detail
        varchar   changed_by
        timestamp changed_at
    }
```

## Rules the diagram can't show

These are enforced by checks in the schema or by application logic, not by relationships.

- **One level per location attribute.** Each `LOCATION_ATTRIBUTES` row sets exactly one of `site_id`, `building_id`, `block_id`, `floor_id`, `room_id`, `bed_id` (schema check).
- **Course allocation or external booking.** An `ALLOCATIONS` row has both `course_id` and `individual_no`, or neither with `source = EXTERNAL` (schema check).
- **Individuals have no table.** `individual_no` is an anonymous number from 1 to the course's `est_attendees`. It is not a foreign key; the range is checked by application logic.
- **Outages are attributes.** An outage is a location attribute with `attr_code = OUT_OF_ACTION`, value `Y`, and the reason in `comments`. Its attribute type uses `inherit_mode = ANY`, so it applies to every bed below the level it is set on and cannot be overridden.
- **Attribute behaviour.** `allow_overlap` and `comment_required` on `ATTRIBUTE_TYPES` are enforced by application logic.
- **Rule attributes.** `LOCATION_BLOCKS` rules have no `individual_attr`; `COMPARE` and `REQUIRES` need both attributes; `MATCH_WITHIN` and `SOLE_USE` need `individual_attr` (schema check).
- **Dates.** Start is the first night and end is the departure day (exclusive), so two stays overlap when `a.start_date < b.end_date and b.start_date < a.end_date`.
- **Warnings are not stored.** Conflicts and warnings are computed by queries each time; there is no table for them in the MVP.
