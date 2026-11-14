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
  scheduled: number;
  loaded: number;
  loadedAt: string | null;
  allocated: number;
  loadedAboveScheduled: boolean;
}

// api.fn_bed_bars
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
