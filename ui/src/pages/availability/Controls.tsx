// The availability toolbar: week navigation on the left; colour basis, tree
// expand/collapse, the legend and view settings on the right. Legend and
// settings open as small popovers.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { CollapseIcon, ExpandIcon, ListIcon, SlidersIcon } from "../../icons";
import { Legend } from "./LegendAndWarnings";
import { Arrow } from "./look";
import { LIMITS, type ViewSettings } from "./settings";
import type { Basis } from "./types";

interface Props {
  rangeText: string;
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
        <span className="range" aria-live="polite">{p.rangeText}</span>
        <button type="button" className="tb-btn icon" aria-label="Next week" onClick={p.onNext}>
          <Arrow dir="right" />
        </button>
        <button type="button" className="tb-btn" onClick={p.onToday}>Today</button>
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

// A button with a panel under it. Closes on a click outside or Esc.
function Popover({ label, icon, children }: { label: string; icon: ReactNode; children: ReactNode }) {
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
      <button type="button" className={`tb-btn${open ? " on" : ""}`} aria-expanded={open} onClick={() => setOpen(!open)}>
        {icon} <span className="tb-label">{label}</span>
      </button>
      {open && <div className="popover-panel" role="dialog" aria-label={label}>{children}</div>}
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
