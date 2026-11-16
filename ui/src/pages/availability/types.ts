// Shapes the availability page works with. Views come typed from the generated
// schema (every column optional there, so they're tidied in data.ts); function
// results aren't in PostgREST's OpenAPI, so they're written out here to match
// db/api-contract.txt (migration 0006).

export type Level = "Site" | "Building" | "Block" | "Floor" | "Room" | "Bed";
export type Basis = "scheduled" | "loaded";
export type CourseColour = "green" | "amber" | "red";

// One node of the estate tree (api.locations).
export interface LocationNode {
  key: string;
  parentKey: string | null;
  level: Level;
  id: number;
  name: string;
  sortOrder: number;
  bedCount: number;
  children: LocationNode[];
  // Set on a copy made by the location filter when some of this node's blocks
  // are hidden: bedCount then counts only what's shown.
  partial?: boolean;
}

// api.course_figures
export interface CourseFigure {
  courseId: number;
  code: string;
  name: string;
  startDate: string;
  endDate: string;
  status: string;
  pctScheduled: number | null;
  pctLoaded: number | null;
  siteId: number | null;
  scheduled: number;
  loaded: number;
  loadedAt: string | null;
  allocated: number;
  loadedAboveScheduled: boolean;
}

// api.fn_bed_bars: full dates since 0008; the grid fits them to the weeks shown.
export interface BedBar {
  bed_id: number;
  kind: "allocation" | "external" | "outage";
  id: number;
  start_date: string;
  end_date: string;
  course_id: number | null;
  course_code: string | null;
  individual_no: number | null;
  external_ref: string | null;
  external_name: string | null;
  status: string | null;
  set_on_level: Level | null;
  reason: string | null;
  on_outage: boolean | null;
}

// api.warnings: worked out in the database; the UI only lists them.
export interface Warning {
  kind: string;
  severity: string;
  message: string;
  courseId: number | null;
  allocationId: number | null;
  bedId: number | null;
  startDate: string | null;
  endDate: string | null;
  siteId: number | null;
}

// A booking to bring into view on the availability grid and highlight: from a
// warning on the Overview (router state { focus }) or in the warnings strip.
export interface FocusBooking {
  allocationId: number;
  bedId: number;
  startDate: string;
}

// The booking a warning is about (outside course dates, out-of-action bed,
// double booking), or null for course-level warnings (loaded above scheduled).
export function bookingOf(w: Warning): FocusBooking | null {
  return w.allocationId !== null && w.bedId !== null && w.startDate !== null
    ? { allocationId: w.allocationId, bedId: w.bedId, startDate: w.startDate }
    : null;
}

// api.fn_check_allocation
export interface Clash {
  bed_id: number | null; // null for COURSE_DATES
  kind: "BOOKING" | "OUT_OF_ACTION" | "COURSE_DATES";
  ref: string;
  start_date: string;
  end_date: string;
  message: string;
  blocks: boolean; // the clash's rule is BLOCK, so saving would be refused (D30)
}

// api.fn_candidate_beds (0013, D35): every bed a course could be booked into
// for some nights, in estate order, with the database's suggestion.
export interface CandidateBed {
  bed_id: number;
  bed_name: string;
  room_id: number;
  room_name: string;
  floor_name: string;
  block_name: string;
  building_name: string;
  site_name: string;
  free: boolean; // no booking or outage on those nights
  course_in_room: boolean; // the course already has a bed in this room then
  warnings: string[]; // the clashes the active rules would raise
  blocks: boolean; // one of them is BLOCK: booking would be refused
  rank: number | null; // among the suggested beds
  suggested: boolean;
}

// api.audit (0015, D37): one change, with its summary sentence (no user in it).
export interface AuditRow {
  auditId: number;
  requestId: string | null;
  changedAt: string;
  changedBy: string;
  tableName: string;
  recordId: number;
  courseId: number | null;
  courseCode: string;
  allocationId: number | null;
  bedId: number | null;
  siteId: number | null;
  action: string;
  summary: string;
  warnings: string[];
}

// api.audit_requests: the rows of one request rolled into one line.
export interface AuditRequest {
  requestKey: string;
  changedAt: string;
  changedBy: string;
  changes: number;
  courseId: number | null;
  courseCode: string | null;
  siteId: number | null;
  summary: string;
  hasWarnings: boolean;
}

// What a popup is showing.
export type Popup =
  | { kind: "location"; key: string }
  | { kind: "booking"; bar: BedBar }
  | { kind: "outage"; bar: BedBar }
  | { kind: "week"; key: string; weekStart: string }
  | { kind: "course"; courseId: number }
  // Book beds for a course, starting from the course (D35).
  | { kind: "bookCourse"; courseId: number }
  // Add a course (D36); from/to pre-fill its dates (weeks dragged on the Courses tab).
  | { kind: "newCourse"; from?: string; to?: string }
  // Book beds for someone outside the courses (D38); beds and dates pre-filled from a grid selection.
  | { kind: "newExternal"; bedKeys?: string[]; from?: string; to?: string }
  // Put a location out of action (D38); `key` pre-selects the location, or
  // `bedKeys` (a grid selection) offers the places that hold those beds.
  | { kind: "newOutage"; key?: string; bedKeys?: string[]; from?: string; to?: string }
  | { kind: "warning"; warning: Warning }
  // A booking dragged to another bed and/or dates, to confirm (fn_move_allocation).
  | { kind: "move"; bar: BedBar; bedKey: string; from: string; to: string }
  // A selection of beds and nights (to = departure day, exclusive).
  | { kind: "new"; bedKeys: string[]; from: string; to: string };

// api.fn_week_summary (0007): beds by category on a week's busiest night,
// one row per course for category "course".
export interface WeekSummaryRow {
  key: string;
  week_start: string;
  busiest_night: string;
  category: "free" | "out_of_action" | "external" | "course";
  course_id: number | null;
  beds: number;
}

// The rows for one location and week, gathered. Courses are banded by the UI (D29).
export interface WeekSummary {
  busiestNight: string;
  free: number;
  outOfAction: number;
  external: number;
  courses: { courseId: number; beds: number }[];
}
