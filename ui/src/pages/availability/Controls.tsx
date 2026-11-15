// The availability toolbar: week navigation on the left; colour basis, tree
// expand/collapse, the legend and view settings on the right. Legend and
// settings open as small popovers.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { CollapseIcon, ExpandIcon, FilterIcon, ListIcon, SlidersIcon } from "../../icons";
import { FilterPanel, filterLabel, isFiltered } from "./Filter";
import type { LocationFilter } from "./settings";
import type { LocationNode } from "./types";
import { Legend } from "./LegendAndWarnings";
import { addDaysIso, dayIndex, dayLong, dayLongYear, iso, mondayOf, parse } from "./dates";
import { Arrow } from "./look";
import { LIMITS, type ViewSettings } from "./settings";
import type { Basis } from "./types";

interface Props {
  roots: LocationNode[]; // the whole estate, for the location filter
  filter: LocationFilter;
  onFilter: (f: LocationFilter) => void;
  rangeText: string;
  start: string; // Monday of the first week shown
  onRange: (start: string, weeks: number) => void;
  settings: ViewSettings;
  onSettings: (change: Partial<ViewSettings>) => void;
  onPrev: () => void;
  onNext: () => void;
  onToday: () => void;
  onExpandAll: () => void;
  onCollapseToFloors: () => void;
}

export function Controls(p: Props) {
  const basisButton = (b: Basis, label: string) => (
    <button type="button" aria-pressed={p.settings.basis === b} onClick={() => p.onSettings({ basis: b })}>
      {label}
    </button>
  );

  return (
    <div className="av-toolbar">
      <div className="group">
        <button type="button" className="tb-btn icon" aria-label="Previous week" onClick={p.onPrev}>
          <Arrow dir="left" />
        </button>
        <Popover label="Choose weeks" align="left"
                 trigger={<span className="range" aria-live="polite">{p.rangeText}</span>} triggerClass="tb-btn range-btn">
          {(close) => (
            <RangePicker start={p.start} weeks={p.settings.weeks}
                         onApply={(start, weeks) => { p.onRange(start, weeks); close(); }} />
          )}
        </Popover>
        <button type="button" className="tb-btn icon" aria-label="Next week" onClick={p.onNext}>
          <Arrow dir="right" />
        </button>
        <button type="button" className="tb-btn" onClick={p.onToday}>Today</button>
        <Popover label="Filter locations" align="left" triggerClass={`tb-btn${isFiltered(p.filter, p.roots) ? " active" : ""}`}
                 trigger={<><FilterIcon /> <span className="filter-label">{filterLabel(p.filter, p.roots)}</span></>}>
          {(close) => <FilterPanel filter={p.filter} roots={p.roots} onFilter={p.onFilter} close={close} />}
        </Popover>
      </div>

      <div className="group">
        <div className="tb-seg" role="group" aria-label="Colour courses by">
          <span>Colour by</span>
          {basisButton("scheduled", "Scheduled")}
          {basisButton("loaded", "Loaded")}
        </div>
        <button type="button" className="tb-btn" onClick={p.onExpandAll} title="Expand every row">
          <ExpandIcon /> <span className="tb-label">Expand all</span>
        </button>
        <button type="button" className="tb-btn" onClick={p.onCollapseToFloors} title="Show floors with weekly counts">
          <CollapseIcon /> <span className="tb-label">Collapse to floors</span>
        </button>
        <Popover label="Legend" icon={<ListIcon />}>
          <Legend settings={p.settings} />
        </Popover>
        <Popover label="Settings" icon={<SlidersIcon />}>
          <div className="settings-panel">
            <h2>Timeline</h2>
            <NumberField label="Weeks shown" value={p.settings.weeks} limits={LIMITS.weeks}
                         onChange={(weeks) => p.onSettings({ weeks })} />
            <NumberField label="Minimum day width (px)" value={p.settings.minDayWidth} limits={LIMITS.minDayWidth}
                         onChange={(minDayWidth) => p.onSettings({ minDayWidth })} />
            <p className="hint">Days widen to fill the window; this is the narrowest they get.</p>
            <h2>Course thresholds</h2>
            <NumberField label="Green at or above (%)" value={p.settings.greenAt} limits={LIMITS.greenAt}
                         onChange={(greenAt) => p.onSettings({ greenAt })} />
            <NumberField label="Red below (%)" value={p.settings.redBelow}
                         limits={{ min: LIMITS.redBelow.min, max: Math.min(LIMITS.redBelow.max, p.settings.greenAt) }}
                         onChange={(redBelow) => p.onSettings({ redBelow })} />
            <p className="hint">Saved in this browser only.</p>
          </div>
        </Popover>
      </div>
    </div>
  );
}

// Choose the weeks shown: a first and a last week (any day picks its week, which
// runs Monday to Sunday, D9), or a quick length from the first week.
function RangePicker({ start, weeks, onApply }: { start: string; weeks: number; onApply: (start: string, weeks: number) => void }) {
  const [from, setFrom] = useState(start);
  const [to, setTo] = useState(addDaysIso(start, (weeks - 1) * 7));
  const fromMonday = from ? iso(mondayOf(parse(from))) : "";
  const toMonday = to ? iso(mondayOf(parse(to))) : "";
  const count = fromMonday && toMonday ? dayIndex(fromMonday, toMonday) / 7 + 1 : 0;
  const ok = count >= LIMITS.weeks.min && count <= LIMITS.weeks.max;

  return (
    <div className="range-picker">
      <h2>Weeks shown</h2>
      <div className="dates">
        <label>First week<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label>Last week<input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
      </div>
      <p className={`hint${ok || !fromMonday || !toMonday ? "" : " bad"}`}>
        {!fromMonday || !toMonday ? "Choose both weeks."
          : count < 1 ? "The last week must not be before the first."
          : count > LIMITS.weeks.max ? `At most ${LIMITS.weeks.max} weeks.`
          : `${dayLong(fromMonday)} – ${dayLongYear(addDaysIso(toMonday, 6))} · ${count} ${count === 1 ? "week" : "weeks"}`}
      </p>
      <div className="quick">
        {[4, 6, 8, 12].map((n) => (
          <button key={n} type="button" className="tb-btn" disabled={!fromMonday}
                  onClick={() => onApply(fromMonday, n)}>
            {n} weeks
          </button>
        ))}
      </div>
      <div className="apply">
        <button type="button" className="tb-btn primary" disabled={!ok} onClick={() => onApply(fromMonday, count)}>Show</button>
      </div>
    </div>
  );
}

// A button with a panel under it. Closes on a click outside or Esc. The panel's
// content may be a function given `close`, to close it after an action.
function Popover({ label, icon, trigger, triggerClass = "tb-btn", align = "right", children }: {
  label: string;
  icon?: ReactNode;
  trigger?: ReactNode;
  triggerClass?: string;
  align?: "left" | "right";
  children: ReactNode | ((close: () => void) => ReactNode);
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);
  return (
    <div className="popover" ref={ref}>
      <button type="button" className={`${triggerClass}${open ? " on" : ""}`} aria-expanded={open}
              aria-label={trigger ? label : undefined} title={trigger ? label : undefined} onClick={() => setOpen(!open)}>
        {trigger ?? <>{icon} <span className="tb-label">{label}</span></>}
      </button>
      {open && (
        <div className={`popover-panel ${align}`} role="dialog" aria-label={label}>
          {typeof children === "function" ? children(() => setOpen(false)) : children}
        </div>
      )}
    </div>
  );
}

// A number input that only applies values within its limits, so typing "1" on
// the way to "100" doesn't jump the setting; leaving the field shows the value in use.
function NumberField(p: {
  label: string;
  value: number;
  limits: { min: number; max: number };
  onChange: (n: number) => void;
}) {
  const [draft, setDraft] = useState(String(p.value));
  useEffect(() => setDraft(String(p.value)), [p.value]);

  return (
    <label>
      {p.label}
      <input
        type="number"
        min={p.limits.min}
        max={p.limits.max}
        value={draft}
        onChange={(e) => {
          setDraft(e.target.value);
          const n = Number(e.target.value);
          if (e.target.value !== "" && Number.isInteger(n) && n >= p.limits.min && n <= p.limits.max) p.onChange(n);
        }}
        onBlur={() => setDraft(String(p.value))}
      />
    </label>
  );
}
