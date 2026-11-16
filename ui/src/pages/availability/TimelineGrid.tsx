// The availability grid: tree on the left, one column per night, bars on bed
// rows and busiest-night counts on collapsed rows (D28). Display only: what
// counts as a clash or a warning comes from the API. Every bar, row name and
// week cell is a button that opens a popup; booking bars can also be dragged to
// another bed or dates (confirmed in a popup). Empty parts of bed rows select
// week blocks for a new allocation (D8-D10).
import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { addDaysIso, barPlace, dayLong, ddmm } from "./dates";
import { basisOf, Chevron, courseColour, levelPrefix, OverIcon, STATE_NAMES, STATE_ORDER, WarnIcon, type State } from "./look";
import type { ViewSettings } from "./settings";
import type { BedBar, CourseFigure, LocationNode, Popup, WeekSummary } from "./types";

export const LABEL_WIDTH = 260; // matches .av-label in availability.css

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
  // Dragging a booking to another bed and/or dates.
  moving: MoveDrag | null;
  onBarDown: (bar: BedBar, rowIndex: number, e: ReactPointerEvent<HTMLElement>) => void;
  justDragged: () => boolean; // a drag just ended: the click that follows isn't a click
  doubleBooked: Set<number>; // allocation ids api.warnings reports as double-booked
}

// A booking being dragged: over which bed row, shifted by how many days.
interface MoveDrag {
  bar: BedBar;
  row: number;
  days: number;
  active: boolean; // past the few pixels that tell a drag from a click
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
  // A booking to scroll to and highlight once drawn; a new seq does it again.
  highlight?: { allocationId: number; seq: number } | null;
  // Bookings the database reports as double-booked (api.warnings): marked on their bars.
  doubleBooked?: Set<number>;
}

const NONE = new Set<number>();

export function TimelineGrid({ rows, start, settings, bars, summary, figures, onToggle, onOpen, highlight = null,
                               doubleBooked = NONE }: Props) {
  const nights = settings.weeks * 7;
  // Fill the available width: days widen to fit, never narrower than the
  // user's minimum day width (then the grid scrolls sideways).
  const scrollRef = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState(0);
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setAvailable(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const dayW = Math.max(settings.minDayWidth, Math.floor((available - LABEL_WIDTH) / nights) || 0);
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

  // ------------------------ Highlighting a booking ------------------------
  // When asked (e.g. arriving from a warning on the Overview), scroll the
  // booking's bar into view and play a glow that fades. Waits until the bar is
  // drawn: bars and rows load after the page opens.
  const highlighted = useRef<number | null>(null);
  useEffect(() => {
    if (!highlight || highlighted.current === highlight.seq) return;
    const el = scrollRef.current?.querySelector<HTMLElement>(`.av-bar[data-allocation="${highlight.allocationId}"]`);
    if (!el) return;
    highlighted.current = highlight.seq;
    el.scrollIntoView({ block: "center", inline: "center", behavior: "smooth" });
    el.classList.remove("flash");
    void el.offsetWidth; // restart the animation
    el.classList.add("flash");
    // Off when the animation ends, or after its length if no animationend comes (a background tab).
    el.addEventListener("animationend", () => el.classList.remove("flash"), { once: true });
    setTimeout(() => el.classList.remove("flash"), 3000);
  }, [highlight, bars, rows, dayW]);

  // ------------------------- Dragging a booking -------------------------
  // Grab a booking bar and drop it on another bed row and/or other days; it
  // keeps its length. Dropping opens a popup to confirm the move, which the
  // database then checks and saves (fn_move_allocation). A press that moves
  // less than a few pixels is a click and opens the booking as before.
  const [moving, setMoving] = useState<MoveDrag | null>(null);
  const movingRef = useRef<MoveDrag | null>(null);
  const moveStopRef = useRef<(() => void) | null>(null);
  const dragged = useRef(false);
  useEffect(() => () => moveStopRef.current?.(), []);

  const onBarDown = (bar: BedBar, rowIndex: number, e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0) return;
    const x0 = e.clientX, y0 = e.clientY;
    movingRef.current = { bar, row: rowIndex, days: 0, active: false };

    const move = (ev: PointerEvent) => {
      const cur = movingRef.current;
      if (!cur) return;
      if (!cur.active && Math.hypot(ev.clientX - x0, ev.clientY - y0) < 5) return;
      // The bed row under the pointer; elsewhere (a group row, outside the grid) keeps the last one.
      const el = document.elementFromPoint(ev.clientX, ev.clientY)?.closest<HTMLElement>(".av-row[data-idx]");
      const i = el ? Number(el.dataset.idx) : cur.row;
      const row = rows[i]?.node.level === "Bed" ? i : cur.row;
      const days = Math.round((ev.clientX - x0) / dayW);
      if (!cur.active || row !== cur.row || days !== cur.days) {
        movingRef.current = { ...cur, row, days, active: true };
        setMoving(movingRef.current);
      }
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      moveStopRef.current = null;
    };
    const up = () => {
      const cur = movingRef.current;
      stop();
      movingRef.current = null;
      setMoving(null);
      if (!cur?.active) return;
      dragged.current = true;
      setTimeout(() => { dragged.current = false; }, 0);
      const target = rows[cur.row].node;
      if (target.id === cur.bar.bed_id && cur.days === 0) return; // dropped where it was
      onOpen({
        kind: "move", bar: cur.bar, bedKey: target.key,
        from: addDaysIso(cur.bar.start_date, cur.days), to: addDaysIso(cur.bar.end_date, cur.days),
      });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    moveStopRef.current = stop;
  };

  const ctx: GridContext = {
    start, nights, dayW, bodyWidth, lines, weekStarts, settings, bars, summary, figures, onToggle, onOpen,
    selection, onSelectStart, onSelectKey,
    moving: moving?.active ? moving : null, onBarDown, justDragged: () => dragged.current, doubleBooked,
  };

  return (
    <div className="av-scroll" ref={scrollRef}>
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
        {isBed || node.partial ? (
          // Beds don't collapse; nor does a filtered site or building (its
          // weekly counts would cover blocks that aren't shown).
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
            {levelPrefix(node)}{node.bedCount} {node.bedCount === 1 ? "bed" : "beds"}{node.partial ? " · filtered" : ""}
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
        {isBed && <BedBars bars={ctx.bars.get(node.id) ?? []} index={index} ctx={ctx} />}
        {isBed && ctx.moving && ctx.moving.row === index && <MoveGhost m={ctx.moving} ctx={ctx} />}
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

// Where a dragged booking would land, with its new dates.
function MoveGhost({ m, ctx }: { m: MoveDrag; ctx: GridContext }) {
  const from = addDaysIso(m.bar.start_date, m.days);
  const to = addDaysIso(m.bar.end_date, m.days);
  const place = barPlace(ctx.start, ctx.nights, ctx.dayW, from, to);
  if (!place) return null;
  const ref = m.bar.kind === "external" ? m.bar.external_ref : m.bar.course_code;
  // Moving sideways changes the dates: say so, in red.
  if (m.days !== 0) {
    return (
      <div className="av-move-ghost dates" style={place} role="alert">
        <WarnIcon /> {ref}: dates change to {ddmm(from)} – {ddmm(to)} (was {ddmm(m.bar.start_date)} – {ddmm(m.bar.end_date)})
      </div>
    );
  }
  return <div className="av-move-ghost" style={place}>{ref} · {ddmm(from)} – {ddmm(to)}</div>;
}

// Bookings on one bed that overlap each other (a double booking): each gets a
// lane, so the row splits into half-height lanes and every bar shows in full;
// `clashes` are the nights two of them share. Only overlapping bookings are
// laid out in lanes; the rest keep the full row. Display only: whether this is
// a warning or refused is the database's (the DOUBLE_BOOKING rule, D30).
function laneLayout(bars: BedBar[]) {
  const bookings = bars.filter((b) => b.kind !== "outage").sort((a, b) => a.start_date.localeCompare(b.start_date));
  const lanes = new Map<number, { lane: number; of: number }>();
  const clashes: { from: string; to: string }[] = [];
  let group: BedBar[] = [];
  let groupEnd = "";
  const close = () => {
    if (group.length > 1) {
      const ends: string[] = []; // the last end date in each lane
      for (const b of group) {
        let lane = ends.findIndex((e) => e <= b.start_date);
        if (lane < 0) lane = ends.push(b.end_date) - 1;
        else ends[lane] = b.end_date;
        lanes.set(b.id, { lane, of: 0 });
      }
      for (const b of group) lanes.get(b.id)!.of = ends.length;
      for (let i = 0; i < group.length; i++) {
        for (let j = i + 1; j < group.length; j++) {
          const from = group[i].start_date > group[j].start_date ? group[i].start_date : group[j].start_date;
          const to = group[i].end_date < group[j].end_date ? group[i].end_date : group[j].end_date;
          if (from < to) clashes.push({ from, to });
        }
      }
    }
    group = [];
  };
  for (const b of bookings) {
    if (group.length > 0 && b.start_date >= groupEnd) close();
    group.push(b);
    groupEnd = group.length === 1 || b.end_date > groupEnd ? b.end_date : groupEnd;
  }
  close();
  return { lanes, clashes };
}

function BedBars({ bars, index, ctx }: { bars: BedBar[]; index: number; ctx: GridContext }) {
  // Bars carry their full dates (0008); fit them to the days shown, whole days
  // (barPlace). Overlapping bookings share the row in lanes (laneLayout).
  const { lanes, clashes } = laneLayout(bars);
  return (
    <>
      {clashes.map((c, i) => {
        const place = barPlace(ctx.start, ctx.nights, ctx.dayW, c.from, c.to);
        return place && <div key={`c${i}`} className="av-clash" style={place} title={`Double booking, ${ddmm(c.from)} to ${ddmm(c.to)}`} />;
      })}
      {bars.map((b) => {
        const fit = barPlace(ctx.start, ctx.nights, ctx.dayW, b.start_date, b.end_date);
        if (!fit) return null;
        // In a lane: a slice of the row's 26px, one above the other.
        const lane = lanes.get(b.id);
        const h = lane ? Math.floor(26 / lane.of) - 1 : 0;
        const place: CSSProperties = lane ? { ...fit, top: 3 + lane.lane * (h + 1), height: h } : fit;
        const dates = `${ddmm(b.start_date)} to ${ddmm(b.end_date)}`;

        if (b.kind === "outage") {
          const label = "Out of action" + (b.set_on_level && b.set_on_level !== "Bed" ? ` (${b.set_on_level.toLowerCase()})` : "");
          const aria = `${label}: ${b.reason ?? "no reason given"}, ${dates}`;
          return (
            <button key={`o${b.id}`} type="button" className="av-bar st-out" style={fit} title={aria}
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
            // Individual numbers are internal (D31): the course and its figures only.
            : `${b.course_code}` + (course ? ` · ${course.allocated}/${basisOf(course, ctx.settings)}` : "");
        const double = ctx.doubleBooked.has(b.id); // from api.warnings (DOUBLE_BOOKING)
        const aria = `${label}, ${dates}` + (b.on_outage ? ", clashes with an outage" : "") +
          (double ? ", double-booked" : "") + (over ? ", course loaded above scheduled" : "");
        const beingMoved = ctx.moving?.bar.id === b.id;
        return (
          <button key={`a${b.id}`} type="button"
                  className={`av-bar movable st-${state}${b.on_outage ? " on-outage" : ""}${double ? " double" : ""}` +
                    `${lane ? " in-lane" : ""}${beingMoved ? " moving" : ""}`}
                  style={place} title={`${aria} (drag to move)`} aria-label={aria} data-allocation={b.id}
                  onPointerDown={(e) => ctx.onBarDown(b, index, e)}
                  onClick={() => { if (!ctx.justDragged()) ctx.onOpen({ kind: "booking", bar: b }); }}>
            {(b.on_outage || double) && <WarnIcon />}
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
