// Colours and icons from the mockup (docs/pages_pocs/availability.html). Colours
// differ in lightness as well as hue, and every bar also has a text label.
import type { CourseColour, CourseFigure } from "./types";
import type { ViewSettings } from "./settings";

export type State = "free" | "out" | CourseColour | "external";
export const STATE_ORDER: State[] = ["free", "out", "green", "amber", "red", "external"];
export const STATE_NAMES: Record<State, string> = {
  free: "free",
  out: "out of action",
  green: "green",
  amber: "amber",
  red: "red",
  external: "external",
};

// The basis value a course is compared against.
export const basisOf = (c: CourseFigure, s: ViewSettings) => (s.basis === "loaded" ? c.loaded : c.scheduled);

// Course colour band, from the user's thresholds (D13, D29). The only place the
// bands are worked out: bars and collapsed rows both use it. The database gives
// the facts (allocated, scheduled, loaded); a course with no basis counts as green.
// Uses the whole numbers rather than the rounded pct_* columns, so a band edge
// can't move with rounding.
export function courseColour(c: CourseFigure, s: ViewSettings): CourseColour {
  const basis = basisOf(c, s);
  const pct = basis > 0 ? (c.allocated * 100) / basis : 100;
  if (pct >= s.greenAt) return "green";
  if (pct < s.redBelow) return "red";
  return "amber";
}

export function OverIcon() {
  return (
    <svg className="icon" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
      <circle cx="6" cy="6" r="5.2" fill="#FFFFFF" stroke="#4C1D95" strokeWidth="1.2" />
      <path d="M6 8.8 V3.6 M3.9 5.6 L6 3.5 L8.1 5.6" fill="none" stroke="#4C1D95" strokeWidth="1.3"
            strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function WarnIcon() {
  return (
    <svg className="icon" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
      <path d="M6 1 L11 10.5 H1 Z" fill="#FFF4E5" stroke="#7A1610" strokeWidth="1.2" strokeLinejoin="round" />
      <path d="M6 4.5 V7.2 M6 8.6 V8.9" stroke="#7A1610" strokeWidth="1.3" strokeLinecap="round" />
    </svg>
  );
}

export function Chevron({ open }: { open: boolean }) {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true" style={{ transform: `rotate(${open ? 90 : 0}deg)` }}>
      <path d="M4 2 L8 6 L4 10" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function Arrow({ dir }: { dir: "left" | "right" }) {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <path d={dir === "left" ? "M9 2.5 L4.5 7 L9 11.5" : "M5 2.5 L9.5 7 L5 11.5"} fill="none" stroke="currentColor"
            strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

// "Site · " before a row's bed count, unless the name already says the level
// ("Room 101", "Block A", "Floor 1"), so the label doesn't read "Room 101 Room".
export function levelPrefix(n: { level: string; name: string }) {
  return n.name.toLowerCase().startsWith(n.level.toLowerCase()) ? "" : `${n.level} · `;
}
