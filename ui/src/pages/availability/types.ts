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
  // Add a course (D36).
  | { kind: "newCourse" }
  | { kind: "warning"; warning: Warning }
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
