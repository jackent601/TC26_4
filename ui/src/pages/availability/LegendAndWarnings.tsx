// Legend (reflects the user's basis and thresholds) and the warnings strip
// (from api.warnings, always shown whatever the colour basis, D14).
import { ddmm } from "./dates";
import { OverIcon, WarnIcon, type State } from "./look";
import type { ViewSettings } from "./settings";
import { bookingOf, type FocusBooking, type Popup, type Warning } from "./types";

// A vertical list, opened from the toolbar's Legend button.
export function Legend({ settings: s }: { settings: ViewSettings }) {
  const beds: [State, string][] = [
    ["free", "Free"],
    ["out", "Out of action"],
    ["external", "External booking"],
  ];
  const courses: [State, string][] = [
    ["green", `${s.greenAt}% or more allocated`],
    ["amber", `${s.redBelow}% to ${s.greenAt}%`],
    ["red", `Below ${s.redBelow}%`],
  ];
  const row = ([state, label]: [State, string]) => (
    <li key={state}><span className={`av-sw st-${state}`} />{label}</li>
  );
  return (
    <div className="av-legend">
      <h2>Beds</h2>
      <ul>{beds.map(row)}</ul>
      <h2>Courses, by {s.basis}</h2>
      <ul>{courses.map(row)}</ul>
      <h2>Markers</h2>
      <ul>
        <li><WarnIcon />Booking clash</li>
        <li><OverIcon />Course loaded above scheduled</li>
      </ul>
    </div>
  );
}

export function WarningsStrip({ warnings, error, onOpen, onShowBooking }: {
  warnings: Warning[];
  error: Error | null;
  onOpen: (p: Popup) => void;
  onShowBooking: (f: FocusBooking) => void; // a booking warning: bring the booking into view, highlighted
}) {
  if (error) return <div className="av-warnings" role="region" aria-label="Warnings">Could not load warnings: {error.message}</div>;
  if (warnings.length === 0) return null;
  return (
    <div className="av-warnings" role="region" aria-label="Warnings">
      <strong>{warnings.length} {warnings.length === 1 ? "warning" : "warnings"}</strong>
      <ul>
        {warnings.map((w, i) => (
          <li key={`${w.kind}-${w.courseId}-${w.allocationId}-${i}`} className={`sev-${w.severity.toLowerCase()}`}>
            {/* Booking warnings show the booking on the grid; course-level ones open the course. */}
            <button
              type="button"
              title={bookingOf(w) ? "Show this booking on the grid" : undefined}
              onClick={() => {
                const b = bookingOf(w);
                if (b) onShowBooking(b);
                else onOpen(w.courseId !== null ? { kind: "course", courseId: w.courseId } : { kind: "warning", warning: w });
              }}
            >
              {w.kind === "LOADED_ABOVE_SCHEDULED" ? <OverIcon /> : <WarnIcon />}
              <span>
                {w.message}
                {/* Booking warnings get their dates; course-level ones are about the whole course. */}
                {w.allocationId !== null && w.startDate && w.endDate && ` · ${ddmm(w.startDate)}–${ddmm(w.endDate)}`}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
