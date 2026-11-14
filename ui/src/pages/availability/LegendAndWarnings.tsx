// Legend (reflects the user's basis and thresholds) and the warnings strip
// (from api.warnings, always shown whatever the colour basis, D14).
import { ddmm } from "./dates";
import { OverIcon, WarnIcon, type State } from "./look";
import type { ViewSettings } from "./settings";
import type { Popup, Warning } from "./types";

export function Legend({ settings: s }: { settings: ViewSettings }) {
  const items: [State, string][] = [
    ["free", "Free"],
    ["out", "Out of action"],
    ["green", `Allocated ≥ ${s.greenAt}% of ${s.basis}`],
    ["amber", `Allocated ${s.redBelow}–${s.greenAt}% of ${s.basis}`],
    ["red", `Allocated < ${s.redBelow}% of ${s.basis}`],
    ["external", "External booking"],
  ];
  return (
    <div className="av-legend">
      {items.map(([state, label]) => (
        <span key={state} className="item">
          <span className={`av-sw st-${state}`} />
          {label}
        </span>
      ))}
      <span className="item"><WarnIcon />Booking clashes with an outage</span>
      <span className="item"><OverIcon />Course loaded above scheduled</span>
    </div>
  );
}

export function WarningsStrip({ warnings, error, onOpen }: {
  warnings: Warning[];
  error: Error | null;
  onOpen: (p: Popup) => void;
}) {
  if (error) return <div className="av-warnings" role="region" aria-label="Warnings">Could not load warnings: {error.message}</div>;
  if (warnings.length === 0) return null;
  return (
    <div className="av-warnings" role="region" aria-label="Warnings">
      <strong>{warnings.length} {warnings.length === 1 ? "warning" : "warnings"}</strong>
      <ul>
        {warnings.map((w, i) => (
          <li key={`${w.kind}-${w.courseId}-${w.allocationId}-${i}`} className={`sev-${w.severity.toLowerCase()}`}>
            {/* Course-level warnings open the course; booking warnings open the booking. */}
            <button
              type="button"
              onClick={() =>
                onOpen(w.allocationId === null && w.courseId !== null
                  ? { kind: "course", courseId: w.courseId }
                  : { kind: "warning", warning: w })
              }
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
