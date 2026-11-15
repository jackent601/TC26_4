// Courses timeline: one row per course, a bar over its dates coloured by its
// band (the user's basis and thresholds, D29), with scheduled, loaded and
// allocated beside the name. Days widen to fill the width, like the
// availability grid. Click a course to open it.
import { useEffect, useRef, useState, type CSSProperties } from "react";
import { addDaysIso, dayIndex, ddmm } from "../availability/dates";
import { basisOf, courseColour, OverIcon } from "../availability/look";
import type { ViewSettings } from "../availability/settings";
import type { CourseFigure, Popup } from "../availability/types";

const LABEL = 300; // matches .ov-course .av-label

export function CourseTimeline({ courses, start, weeks, settings, onOpen }: {
  courses: CourseFigure[];
  start: string;
  weeks: number;
  settings: ViewSettings;
  onOpen: (p: Popup) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState(0);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setAvailable(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const nights = weeks * 7;
  const dayW = Math.max(settings.minDayWidth, Math.floor((available - LABEL) / nights) || 0);
  const bodyWidth = nights * dayW;
  const weekStarts = Array.from({ length: weeks }, (_, w) => addDaysIso(start, w * 7));
  const lines: CSSProperties = {
    backgroundImage: [
      `repeating-linear-gradient(90deg, transparent 0 ${7 * dayW - 1}px, var(--grid-week-line) ${7 * dayW - 1}px ${7 * dayW}px)`,
      `repeating-linear-gradient(90deg, transparent 0 ${5 * dayW}px, var(--grid-weekend) ${5 * dayW}px ${7 * dayW}px)`,
    ].join(", "),
  };

  return (
    <div className="av-scroll ov-course" ref={ref}>
      <div className="av-grid" style={{ width: LABEL + bodyWidth }}>
        {courses.map((c) => {
          const a = Math.max(0, dayIndex(start, c.startDate));
          const z = Math.min(nights, dayIndex(start, c.endDate));
          const band = courseColour(c, settings);
          const basis = basisOf(c, settings);
          const label = `${c.allocated}/${basis} ${settings.basis} · ${c.loaded} loaded`;
          const open = () => onOpen({ kind: "course", courseId: c.courseId });
          return (
            <div key={c.courseId} className="av-row">
              <div className="av-label">
                <button type="button" className="av-name" onClick={open} title={`${c.code}: ${c.name}`}>
                  <span className="code">{c.code}</span> <span className="cname">{c.name}</span>
                </button>
                <span className="figs" title="Scheduled · loaded · allocated">
                  <span>S {c.scheduled}</span><span>L {c.loaded}</span><span>A {c.allocated}</span>
                </span>
              </div>
              <div className="av-body" style={{ width: bodyWidth, ...lines }}>
                {z > a && (
                  <button type="button" className={`av-bar st-${band}`} onClick={open}
                          style={{ left: a * dayW + 1, width: (z - a) * dayW - 2 }}
                          title={`${c.code}: ${ddmm(c.startDate)} to ${ddmm(c.endDate)}, ${label}`}
                          aria-label={`${c.code}, ${ddmm(c.startDate)} to ${ddmm(c.endDate)}, ${label}` +
                            (c.loadedAboveScheduled ? ", loaded above scheduled" : "")}>
                    {c.loadedAboveScheduled && <OverIcon />}
                    <span>{c.code} · {label}</span>
                  </button>
                )}
              </div>
            </div>
          );
        })}
        <div className="av-axis" style={{ width: LABEL + bodyWidth }}>
          <div className="av-label">Week commencing</div>
          <div className="av-ticks" style={{ width: bodyWidth }}>
            {weekStarts.map((ws, i) => <div key={ws} className="av-tick" style={{ left: i * 7 * dayW }}>{ddmm(ws)}</div>)}
          </div>
        </div>
      </div>
    </div>
  );
}
