// The availability grid: tree on the left, one column per night, bars on bed
// rows and busiest-night counts on collapsed rows (D28). Display only: what
// counts as a clash or a warning comes from the API. Every bar, row name and
// week cell is a button that opens a popup. Empty parts of bed rows select
// week blocks for a new allocation (D8-D10).
import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { addDaysIso, dayIndex, dayLong, ddmm } from "./dates";
import { basisOf, Chevron, courseColour, OverIcon, STATE_NAMES, STATE_ORDER, WarnIcon, type State } from "./look";
import type { ViewSettings } from "./settings";
import type { BedBar, CourseFigure, LocationNode, Popup, WeekSummary } from "./types";

export const LABEL_WIDTH = 300;

export interface VisibleRow {
  node: LocationNode;
  depth: number;
  collapsed: boolean;
}

// What every row needs, shared rather than passed one by one.
interface GridContext {
  start: string;
  nights: number;
  dayW: number;
  bodyWidth: number;
  lines: CSSProperties;
  weekStarts: string[];
  settings: ViewSettings;
  bars: Map<number, BedBar[]>;
  summary: Map<string, WeekSummary>;
  figures: Map<number, CourseFigure>;
  onToggle: (key: string) => void;
  onOpen: (p: Popup) => void;
  // Selecting week blocks on bed rows.
  selection: Selection | null;
  onSelectStart: (rowIndex: number, e: ReactPointerEvent<HTMLElement>) => void;
  onSelectKey: (rowIndex: number) => void;
}

// A drag from one cell (row, week) to another. Rows are indexes into the
// visible rows; group rows in between are skipped when beds are collected.
interface Drag {
  r0: number;
  w0: number;
  r1: number;
  w1: number;
}

// What the dashed outline needs.
interface Selection {
  firstRow: number;
  lastRow: number;
  firstWeek: number;
  weeks: number;
  label: string;
  labelRow: number; // the first bed row, which carries the label
}

interface Props {
  rows: VisibleRow[];
  start: string;
  settings: ViewSettings;
  bars: Map<number, BedBar[]>;
  summary: Map<string, WeekSummary>;
  figures: Map<number, CourseFigure>;
  onToggle: (key: string) => void;
  onOpen: (p: Popup) => void;
}

export function TimelineGrid({ rows, start, settings, bars, summary, figures, onToggle, onOpen }: Props) {
  const dayW = settings.dayWidth;
  const nights = settings.weeks * 7;
  const bodyWidth = nights * dayW;
  const weekStarts = Array.from({ length: settings.weeks }, (_, w) => addDaysIso(start, w * 7));

  // Week lines, night lines and weekend shading (weeks start on Monday, D9).
  const lines: CSSProperties = {
    backgroundImage: [
      `repeating-linear-gradient(90deg, transparent 0 ${7 * dayW - 1}px, var(--av-week-line) ${7 * dayW - 1}px ${7 * dayW}px)`,
      `repeating-linear-gradient(90deg, transparent 0 ${dayW - 1}px, var(--av-night-line) ${dayW - 1}px ${dayW}px)`,
      `repeating-linear-gradient(90deg, transparent 0 ${5 * dayW}px, var(--av-weekend) ${5 * dayW}px ${7 * dayW}px)`,
    ].join(", "),
  };

  // ----------------------- Selecting week blocks -----------------------
  // A week block is Monday (first night) to Sunday (departure): 6 nights (D9).
  const [drag, setDrag] = useState<Drag | null>(null);
  const dragRef = useRef<Drag | null>(null);
  const stopRef = useRef<(() => void) | null>(null);
  useEffect(() => () => stopRef.current?.(), []); // drop listeners if the grid goes

  const weekAt = (body: Element, clientX: number) => {
    const w = Math.floor((clientX - body.getBoundingClientRect().left) / (7 * dayW));
    return Math.min(settings.weeks - 1, Math.max(0, w));
  };

  // Beds and dates for a drag; opens the "New allocation" popup.
  const finish = (d: Drag) => {
    const [ra, rb] = [Math.min(d.r0, d.r1), Math.max(d.r0, d.r1)];
    const [wa, wb] = [Math.min(d.w0, d.w1), Math.max(d.w0, d.w1)];
    const bedKeys = rows.slice(ra, rb + 1).filter((r) => r.node.level === "Bed").map((r) => r.node.key);
    if (bedKeys.length === 0) return;
    onOpen({ kind: "new", bedKeys, from: addDaysIso(start, wa * 7), to: addDaysIso(start, wb * 7 + 6) });
  };

  const onSelectStart = (rowIndex: number, e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const w = weekAt(e.currentTarget, e.clientX);
    const first: Drag = { r0: rowIndex, w0: w, r1: rowIndex, w1: w };
    dragRef.current = first;
    setDrag(first);

    // Follow the pointer anywhere on the page; the row under it gives the bed,
    // its body gives the week.
    const move = (ev: PointerEvent) => {
      const row = document.elementFromPoint(ev.clientX, ev.clientY)?.closest<HTMLElement>(".av-row[data-idx]");
      const body = row?.querySelector(".av-body");
      const cur = dragRef.current;
      if (!row || !body || !cur) return;
      const next = { ...cur, r1: Number(row.dataset.idx), w1: weekAt(body, ev.clientX) };
      if (next.r1 !== cur.r1 || next.w1 !== cur.w1) {
        dragRef.current = next;
        setDrag(next);
      }
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
      if (d) finish(d);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    stopRef.current = stop;
  };

  // Keyboard: activating an empty bed row selects its first visible week.
  const onSelectKey = (rowIndex: number) => finish({ r0: rowIndex, w0: 0, r1: rowIndex, w1: 0 });

  let selection: Selection | null = null;
  if (drag) {
    const [ra, rb] = [Math.min(drag.r0, drag.r1), Math.max(drag.r0, drag.r1)];
    const [wa, wb] = [Math.min(drag.w0, drag.w1), Math.max(drag.w0, drag.w1)];
    const beds = rows.slice(ra, rb + 1).filter((r) => r.node.level === "Bed").length;
    const weeks = wb - wa + 1;
    const labelRow = rows.findIndex((r, i) => i >= ra && r.node.level === "Bed");
    selection = {
      firstRow: ra, lastRow: rb, firstWeek: wa, weeks, labelRow,
      label: `${beds} ${beds === 1 ? "bed" : "beds"} · ${weeks} ${weeks === 1 ? "week" : "weeks"} · ` +
        `${ddmm(addDaysIso(start, wa * 7))} – ${ddmm(addDaysIso(start, wb * 7 + 6))}`,
    };
  }

  const ctx: GridContext = {
    start, nights, dayW, bodyWidth, lines, weekStarts, settings, bars, summary, figures, onToggle, onOpen,
    selection, onSelectStart, onSelectKey,
  };

  return (
    <div className="av-scroll">
      <div className="av-grid" style={{ width: LABEL_WIDTH + bodyWidth }}>
        {rows.map((r, i) => <Row key={r.node.key} row={r} index={i} ctx={ctx} />)}
        <div className="av-axis" style={{ width: LABEL_WIDTH + bodyWidth }}>
          <div className="av-label">Week commencing</div>
          <div className="av-ticks" style={{ width: bodyWidth }}>
            {weekStarts.map((ws, i) => (
              <div key={ws} className="av-tick" style={{ left: i * 7 * dayW }}>{ddmm(ws)}</div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function Row({ row, index, ctx }: { row: VisibleRow; index: number; ctx: GridContext }) {
  const { node, depth, collapsed } = row;
  const isBed = node.level === "Bed";
  const sel = ctx.selection;
  const inSelection = isBed && sel !== null && index >= sel.firstRow && index <= sel.lastRow;
  const firstSelectedBed = inSelection && index === sel!.labelRow;

  return (
    <div className={`av-row lvl-${node.level.toLowerCase()}`} data-idx={index}>
      <div className="av-label" style={{ paddingLeft: 8 + depth * 16 }}>
        {isBed ? (
          <span className="av-spacer" />
        ) : (
          <button type="button" className="av-toggle" aria-expanded={!collapsed}
                  aria-label={`${collapsed ? "Expand" : "Collapse"} ${node.name}`} onClick={() => ctx.onToggle(node.key)}>
            <Chevron open={!collapsed} />
          </button>
        )}
        <button type="button" className="av-name" onClick={() => ctx.onOpen({ kind: "location", key: node.key })}>
          {node.name}
        </button>
        {!isBed && (
          <span className="av-meta">
            {node.level} · {node.bedCount} {node.bedCount === 1 ? "bed" : "beds"}
          </span>
        )}
      </div>
      <div className="av-body" style={{ width: ctx.bodyWidth, ...(isBed || collapsed ? ctx.lines : {}) }}>
        {isBed && (
          // The empty part of the row: drag to select week blocks; Enter or
          // Space selects the first week shown.
          <button type="button" className="av-add" aria-label={`New allocation on ${node.name}`}
                  onPointerDown={(e) => ctx.onSelectStart(index, e)}
                  onClick={(e) => { if (e.detail === 0) ctx.onSelectKey(index); }} />
        )}
        {isBed && <BedBars bars={ctx.bars.get(node.id) ?? []} ctx={ctx} />}
        {inSelection && (
          <div className="av-sel" style={{ left: sel!.firstWeek * 7 * ctx.dayW, width: sel!.weeks * 7 * ctx.dayW }}>
            {firstSelectedBed && sel!.label}
          </div>
        )}
        {collapsed && <WeekCells node={node} ctx={ctx} />}
      </div>
    </div>
  );
}

function BedBars({ bars, ctx }: { bars: BedBar[]; ctx: GridContext }) {
  // Bars carry their full dates (0008); fit them to the nights shown.
  const place = (b: BedBar): CSSProperties => {
    const a = Math.max(0, dayIndex(ctx.start, b.start_date));
    const z = Math.min(ctx.nights, dayIndex(ctx.start, b.end_date));
    return { left: a * ctx.dayW + 1, width: (z - a) * ctx.dayW - 2 };
  };

  return (
    <>
      {bars.map((b) => {
        const dates = `${ddmm(b.start_date)} to ${ddmm(b.end_date)}`;

        if (b.kind === "outage") {
          const label = "Out of action" + (b.set_on_level && b.set_on_level !== "Bed" ? ` (${b.set_on_level.toLowerCase()})` : "");
          const aria = `${label}: ${b.reason ?? "no reason given"}, ${dates}`;
          return (
            <button key={`o${b.id}`} type="button" className="av-bar st-out" style={place(b)} title={aria}
                    aria-label={aria} onClick={() => ctx.onOpen({ kind: "outage", bar: b })}>
              <span>{label}</span>
            </button>
          );
        }

        const course = b.course_id !== null ? ctx.figures.get(b.course_id) : undefined;
        const state: State = b.kind === "external" ? "external" : course ? courseColour(course, ctx.settings) : "amber";
        const over = course?.loadedAboveScheduled ?? false;
        const label =
          b.kind === "external"
            ? `${b.external_ref ?? ""} · ${b.external_name ?? ""}`
            : `${b.course_code} #${b.individual_no}` + (course ? ` · ${course.allocated}/${basisOf(course, ctx.settings)}` : "");
        const aria = `${label}, ${dates}` + (b.on_outage ? ", clashes with an outage" : "") +
          (over ? ", course loaded above scheduled" : "");
        return (
          <button key={`a${b.id}`} type="button" className={`av-bar st-${state}${b.on_outage ? " on-outage" : ""}`}
                  style={place(b)} title={aria} aria-label={aria} onClick={() => ctx.onOpen({ kind: "booking", bar: b })}>
            {b.on_outage && <WarnIcon />}
            {over && <OverIcon />}
            <span>{label}</span>
          </button>
        );
      })}
    </>
  );
}

// Beds by state on a week's busiest night, with courses banded by the user's
// thresholds (D29). Shared by the week cells and the week popup.
export function weekCounts(s: WeekSummary, figures: Map<number, CourseFigure>, settings: ViewSettings) {
  const counts: Record<State, number> = {
    free: s.free, out: s.outOfAction, green: 0, amber: 0, red: 0, external: s.external,
  };
  for (const c of s.courses) {
    const fig = figures.get(c.courseId);
    counts[fig ? courseColour(fig, settings) : "amber"] += c.beds;
  }
  return counts;
}

function WeekCells({ node, ctx }: { node: LocationNode; ctx: GridContext }) {
  return (
    <div className="av-weeks">
      {ctx.weekStarts.map((ws) => {
        const s = ctx.summary.get(`${node.key}|${ws}`);
        if (!s) return <div key={ws} className="av-week" style={{ width: 7 * ctx.dayW }} />;
        const counts = weekCounts(s, ctx.figures, ctx.settings);
        const shown = STATE_ORDER.filter((k) => counts[k] > 0);
        const aria = `${node.name}, week of ${ddmm(ws)}, busiest night ${dayLong(s.busiestNight)}: ` +
          shown.map((k) => `${counts[k]} ${STATE_NAMES[k]}`).join(", ");
        return (
          <button key={ws} type="button" className="av-week" style={{ width: 7 * ctx.dayW }} title={aria}
                  aria-label={aria} onClick={() => ctx.onOpen({ kind: "week", key: node.key, weekStart: ws })}>
            {shown.map((k) => (
              <span key={k} className="av-chip">
                <span className={`av-sw st-${k}`} />
                {counts[k]}
              </span>
            ))}
          </button>
        );
      })}
    </div>
  );
}
