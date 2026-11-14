import { useEffect, useState } from "react";
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
    <div className="controls">
      <button type="button" className="btn icon" aria-label="Previous week" onClick={p.onPrev}>
        <Arrow dir="left" />
      </button>
      <span className="range" aria-live="polite">{p.rangeText}</span>
      <button type="button" className="btn icon" aria-label="Next week" onClick={p.onNext}>
        <Arrow dir="right" />
      </button>
      <button type="button" className="btn" onClick={p.onToday}>Today</button>
      <div className="seg" role="group" aria-label="Colour courses by">
        <span>Colour by</span>
        {basisButton("scheduled", "Scheduled")}
        {basisButton("loaded", "Loaded")}
      </div>
      <button type="button" className="btn" onClick={p.onExpandAll}>Expand all</button>
      <button type="button" className="btn" onClick={p.onCollapseToFloors}>Collapse to floors</button>
      <details className="settings">
        <summary className="btn">Settings</summary>
        <div className="settings-panel">
          <h2>Timeline</h2>
          <NumberField label="Weeks shown" value={p.settings.weeks} limits={LIMITS.weeks}
                       onChange={(weeks) => p.onSettings({ weeks })} />
          <NumberField label="Day width (px)" value={p.settings.dayWidth} limits={LIMITS.dayWidth}
                       onChange={(dayWidth) => p.onSettings({ dayWidth })} />
          <h2>Course thresholds</h2>
          <NumberField label="Green at or above (%)" value={p.settings.greenAt} limits={LIMITS.greenAt}
                       onChange={(greenAt) => p.onSettings({ greenAt })} />
          <NumberField label="Red below (%)" value={p.settings.redBelow}
                       limits={{ min: LIMITS.redBelow.min, max: Math.min(LIMITS.redBelow.max, p.settings.greenAt) }}
                       onChange={(redBelow) => p.onSettings({ redBelow })} />
          <p className="hint">Saved in this browser only.</p>
        </div>
      </details>
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
