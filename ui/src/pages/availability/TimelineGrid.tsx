// The availability grid: tree on the left, one column per night, bars on bed
// rows and busiest-night counts on collapsed rows (D28). Display only: what
// counts as a clash or a warning comes from the API. Every bar, row name and
// week cell is a button that opens a popup.
import type { CSSProperties } from "react";
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

  const ctx: GridContext = {
    start, nights, dayW, bodyWidth, lines, weekStarts, settings, bars, summary, figures, onToggle, onOpen,
  };

  return (
    <div className="av-scroll">
      <div className="av-grid" style={{ width: LABEL_WIDTH + bodyWidth }}>
        {rows.map((r) => <Row key={r.node.key} row={r} ctx={ctx} />)}
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

function Row({ row, ctx }: { row: VisibleRow; ctx: GridContext }) {
  const { node, depth, collapsed } = row;
  const isBed = node.level === "Bed";

  return (
    <div className={`av-row lvl-${node.level.toLowerCase()}`}>
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
        {isBed && <BedBars bars={ctx.bars.get(node.id) ?? []} ctx={ctx} />}
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
