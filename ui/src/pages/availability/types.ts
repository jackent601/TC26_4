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
}

// api.fn_check_allocation
export interface Clash {
  bed_id: number;
  kind: "BOOKING" | "OUT_OF_ACTION";
  ref: string;
  start_date: string;
  end_date: string;
  message: string;
}

// What a popup is showing.
export type Popup =
  | { kind: "location"; key: string }
  | { kind: "booking"; bar: BedBar }
  | { kind: "outage"; bar: BedBar }
  | { kind: "week"; key: string; weekStart: string }
  | { kind: "course"; courseId: number }
  | { kind: "warning"; warning: Warning };

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
