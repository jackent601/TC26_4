// Weekly chart (plain SVG, themed by CSS variables). Per week: scheduled and
// loaded places as bars, a stacked bar of the busiest night's beds (allocated,
// external, free), and beds in service as a dashed line. Hover or focus a week
// for its figures; the legend shows or hides each series.
import { useEffect, useRef, useState } from "react";
import { dayLong, ddmm } from "../availability/dates";
import type { WeekRow } from "./data";

type SeriesId = "scheduled" | "loaded" | "allocated" | "external" | "free" | "available";
const SERIES: { id: SeriesId; label: string; kind: "bar" | "stack" | "line" }[] = [
  { id: "scheduled", label: "Scheduled places", kind: "bar" },
  { id: "loaded", label: "Loaded places", kind: "bar" },
  { id: "allocated", label: "Allocated beds", kind: "stack" },
  { id: "external", label: "External bookings", kind: "stack" },
  { id: "free", label: "Free beds", kind: "stack" },
  { id: "available", label: "Beds in service", kind: "line" },
];

const HEIGHT = 260;
const M = { top: 14, right: 16, bottom: 30, left: 44 };

// A round step for about four gridlines: 1, 2 or 5 times a power of ten.
function niceStep(max: number) {
  const raw = Math.max(max, 1) / 4;
  const p = 10 ** Math.floor(Math.log10(raw));
  return [1, 2, 5, 10].map((m) => m * p).find((s) => s >= raw) ?? p * 10;
}

export function WeeklyChart({ rows }: { rows: WeekRow[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const [hover, setHover] = useState<number | null>(null);
  const [hidden, setHidden] = useState<Set<SeriesId>>(new Set());
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const shown = (id: SeriesId) => !hidden.has(id);
  const toggle = (id: SeriesId) => {
    const next = new Set(hidden);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setHidden(next);
  };

  const plotW = Math.max(width - M.left - M.right, 100);
  const plotH = HEIGHT - M.top - M.bottom;
  const n = Math.max(rows.length, 1);
  const groupW = plotW / n;
  const bw = Math.max(4, Math.min(26, groupW * 0.22));
  const gap = Math.min(4, bw * 0.25);

  const stackTotal = (r: WeekRow) =>
    (shown("allocated") ? r.allocated : 0) + (shown("external") ? r.external : 0) + (shown("free") ? r.free : 0);
  const max = Math.max(
    1,
    ...rows.flatMap((r) => [
      shown("scheduled") ? r.scheduled : 0,
      shown("loaded") ? r.loaded : 0,
      shown("available") ? r.beds_available : 0,
      stackTotal(r),
    ]),
  );
  const step = niceStep(max);
  const yMax = Math.ceil(max / step) * step;
  const ticks = Array.from({ length: yMax / step + 1 }, (_, i) => i * step);
  const y = (v: number) => M.top + plotH - (v / yMax) * plotH;
  const cx = (i: number) => M.left + groupW * (i + 0.5);
  const barX = (i: number, slot: number) => cx(i) - (3 * bw + 2 * gap) / 2 + slot * (bw + gap);

  const bar = (key: string, x: number, from: number, to: number, cls: string) =>
    to > from ? <rect key={key} className={cls} x={x} y={y(to)} width={bw} height={y(from) - y(to)} rx={2} /> : null;

  const linePoints = rows.map((r, i) => `${cx(i)},${y(r.beds_available)}`).join(" ");
  const h = hover !== null ? rows[hover] : undefined;

  return (
    <div className="ov-chart">
      <div className="ov-legend" role="group" aria-label="Series">
        {SERIES.map((s) => (
          <button key={s.id} type="button" aria-pressed={shown(s.id)} onClick={() => toggle(s.id)}
                  title={shown(s.id) ? `Hide ${s.label.toLowerCase()}` : `Show ${s.label.toLowerCase()}`}>
            <span className={`sw ${s.kind} s-${s.id}`} />
            {s.label}
          </button>
        ))}
      </div>

      <div className="ov-plot" ref={ref}>
        <svg width={width} height={HEIGHT} role="img" aria-label="Beds and places by week">
          {ticks.map((t) => (
            <g key={t}>
              <line className="grid" x1={M.left} x2={M.left + plotW} y1={y(t)} y2={y(t)} />
              <text className="tick" x={M.left - 8} y={y(t)} dy="0.32em" textAnchor="end">{t}</text>
            </g>
          ))}

          {rows.map((r, i) => {
            let base = 0;
            const stack: [SeriesId, number][] = [["allocated", r.allocated], ["external", r.external], ["free", r.free]];
            return (
              <g key={r.week_start}>
                {hover === i && <rect className="hover" x={M.left + groupW * i} y={M.top} width={groupW} height={plotH} />}
                {shown("scheduled") && bar("s", barX(i, 0), 0, r.scheduled, "s-scheduled")}
                {shown("loaded") && bar("l", barX(i, 1), 0, r.loaded, "s-loaded")}
                {stack.map(([id, v]) => {
                  if (!shown(id)) return null;
                  const el = bar(id, barX(i, 2), base, base + v, `s-${id}`);
                  base += v;
                  return el;
                })}
                <text className="tick" x={cx(i)} y={HEIGHT - 10} textAnchor="middle">{ddmm(r.week_start)}</text>
              </g>
            );
          })}

          {shown("available") && rows.length > 0 && (
            <g className="s-available-line">
              <polyline points={linePoints} />
              {rows.map((r, i) => <circle key={r.week_start} cx={cx(i)} cy={y(r.beds_available)} r={hover === i ? 4 : 2.5} />)}
            </g>
          )}

          {/* Hover and keyboard targets, one per week. */}
          {rows.map((r, i) => (
            <rect key={`t${r.week_start}`} className="target" x={M.left + groupW * i} y={M.top} width={groupW} height={plotH}
                  tabIndex={0} role="button"
                  aria-label={`Week of ${ddmm(r.week_start)}: ${r.beds_available} beds in service, ${r.allocated} allocated, ` +
                    `${r.external} external, ${r.free} free; ${r.scheduled} scheduled and ${r.loaded} loaded places`}
                  onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)}
                  onFocus={() => setHover(i)} onBlur={() => setHover(null)} />
          ))}
        </svg>

        {h && hover !== null && (
          <div className="ov-tip" style={{ left: Math.min(Math.max(cx(hover), 110), width - 110) }}>
            <strong>Week of {ddmm(h.week_start)}</strong>
            <span className="muted">{h.busiest_night ? `Busiest night ${dayLong(h.busiest_night)}` : "No beds"}</span>
            <dl>
              <dt><span className="sw line s-available" />Beds in service</dt><dd>{h.beds_available}</dd>
              <dt><span className="sw stack s-allocated" />Allocated</dt><dd>{h.allocated}</dd>
              <dt><span className="sw stack s-external" />External</dt><dd>{h.external}</dd>
              <dt><span className="sw stack s-free" />Free</dt><dd>{h.free}</dd>
              <dt><span className="sw bar s-scheduled" />Scheduled</dt><dd>{h.scheduled}</dd>
              <dt><span className="sw bar s-loaded" />Loaded</dt><dd>{h.loaded}</dd>
              <dt>Courses running</dt><dd>{h.courses}</dd>
            </dl>
          </div>
        )}
      </div>
    </div>
  );
}
