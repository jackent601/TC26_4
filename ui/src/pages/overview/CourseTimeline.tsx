// Courses timeline: one row per course, a bar over its dates coloured by its
// band (the user's basis and thresholds, D29), with scheduled, loaded and
// allocated beside the name. Days widen to fill the width, like the
// availability grid. Click a course to open it. The first row adds a course,
// with dates from the weeks dragged across it.
import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { addDaysIso, barPlace, ddmm } from "../availability/dates";
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
        <NewCourseRow start={start} weeks={weeks} dayW={dayW} bodyWidth={bodyWidth} lines={lines} onOpen={onOpen} />
        {courses.map((c) => {
          const place = barPlace(start, nights, dayW, c.startDate, c.endDate); // whole days, arrival to departure
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
                {place && (
                  <button type="button" className={`av-bar st-${band}`} onClick={open} style={place}
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

// The first row: "New course". Drag across weeks (or click one) to open the
// New course popup with those dates; a week block is Monday (first night) to
// Sunday (departure), as on the availability grid (D9). Enter or Space on the
// row picks the first week shown; the name opens the popup without dates.
function NewCourseRow({ start, weeks, dayW, bodyWidth, lines, onOpen }: {
  start: string; weeks: number; dayW: number; bodyWidth: number; lines: CSSProperties; onOpen: (p: Popup) => void;
}) {
  const [drag, setDrag] = useState<{ w0: number; w1: number } | null>(null);
  const dragRef = useRef<{ w0: number; w1: number } | null>(null);
  const stopRef = useRef<(() => void) | null>(null);
  useEffect(() => () => stopRef.current?.(), []); // drop listeners if the row goes

  const weekAt = (body: Element, clientX: number) =>
    Math.min(weeks - 1, Math.max(0, Math.floor((clientX - body.getBoundingClientRect().left) / (7 * dayW))));
  const finish = (wa: number, wb: number) =>
    onOpen({ kind: "newCourse", from: addDaysIso(start, wa * 7), to: addDaysIso(start, wb * 7 + 6) });

  const onPointerDown = (e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const body = e.currentTarget;
    const w = weekAt(body, e.clientX);
    dragRef.current = { w0: w, w1: w };
    setDrag(dragRef.current);
    // Follow the pointer anywhere on the page; only its x position matters.
    const move = (ev: PointerEvent) => {
      const cur = dragRef.current;
      if (!cur) return;
      const w1 = weekAt(body, ev.clientX);
      if (w1 !== cur.w1) setDrag((dragRef.current = { ...cur, w1 }));
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      stopRef.current = null;
    };
    const up = () => {
      const d = dragRef.current;
      stop();
      dragRef.current = null;
      setDrag(null);
      if (d) finish(Math.min(d.w0, d.w1), Math.max(d.w0, d.w1));
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    stopRef.current = stop;
  };

  const sel = drag && { wa: Math.min(drag.w0, drag.w1), n: Math.abs(drag.w1 - drag.w0) + 1 };
  return (
    <div className="av-row ov-new-row">
      <div className="av-label">
        <button type="button" className="av-name" onClick={() => onOpen({ kind: "newCourse" })}
                title="Add a course, or drag across weeks to set its dates">
          <span className="plus" aria-hidden="true">+</span> <span className="code">New course</span>
        </button>
        <span className="hint">drag weeks</span>
      </div>
      <div className="av-body" style={{ width: bodyWidth, ...lines }}>
        <button type="button" className="av-add" aria-label="New course: drag across weeks to set its dates"
                onPointerDown={onPointerDown}
                onClick={(e) => { if (e.detail === 0) finish(0, 0); }} />
        {sel && (
          <div className="av-sel" style={{ left: sel.wa * 7 * dayW, width: sel.n * 7 * dayW }}>
            New course · {sel.n} {sel.n === 1 ? "week" : "weeks"} · {ddmm(addDaysIso(start, sel.wa * 7))} – {ddmm(addDaysIso(start, (sel.wa + sel.n - 1) * 7 + 6))}
          </div>
        )}
      </div>
    </div>
  );
}
