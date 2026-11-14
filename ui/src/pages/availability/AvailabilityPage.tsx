// Availability page (phase 2, steps 1-2): header controls and the grid.
// Spec: claude_availability_page_overview.md; mockup: docs/pages_pocs/availability.html.
import { useCallback, useMemo, useState } from "react";
import { useTenant } from "../../tenant";
import { Controls } from "./Controls";
import { useBedBars, useCourseFigures, useLocations, useWeekSummary } from "./data";
import { addDaysIso, dayLong, dayLongYear, defaultStart, iso, mondayOf } from "./dates";
import { useCollapsed, useViewSettings } from "./settings";
import { TimelineGrid, type VisibleRow } from "./TimelineGrid";
import type { LocationNode } from "./types";
import "./availability.css";

export function AvailabilityPage() {
  const { code: tenant } = useTenant();
  const [settings, updateSettings] = useViewSettings();
  const [collapsed, setCollapsed] = useCollapsed(tenant);
  const [start, setStart] = useState(defaultStart);

  const locations = useLocations(tenant);
  const figures = useCourseFigures(tenant);
  const bars = useBedBars(tenant, start, settings.weeks);
  const summary = useWeekSummary(tenant, start, settings.weeks);

  // Rows in tree order, stopping below collapsed nodes.
  const rows = useMemo(() => {
    const out: VisibleRow[] = [];
    const visit = (n: LocationNode, depth: number) => {
      const isCollapsed = n.level !== "Bed" && collapsed.has(n.key);
      out.push({ node: n, depth, collapsed: isCollapsed });
      if (!isCollapsed) n.children.forEach((c) => visit(c, depth + 1));
    };
    (locations.data ?? []).forEach((n) => visit(n, 0));
    return out;
  }, [locations.data, collapsed]);

  const toggle = useCallback(
    (key: string) => {
      const next = new Set(collapsed);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      setCollapsed(next);
    },
    [collapsed, setCollapsed],
  );

  const collapseToFloors = () => {
    const floors = new Set<string>();
    const visit = (n: LocationNode) => {
      if (n.level === "Floor") floors.add(n.key);
      else n.children.forEach(visit);
    };
    (locations.data ?? []).forEach(visit);
    setCollapsed(floors);
  };

  const last = addDaysIso(start, settings.weeks * 7 - 1);
  const error = locations.error ?? figures.error ?? bars.error ?? summary.error;
  const loading = locations.isPending || figures.isPending || bars.isPending || summary.isPending;

  return (
    <div className="av-page">
      <header className="av-header">
        <div>
          <h1>Availability</h1>
          <p className="sub">Beds by night. Collapsed rows show each week's busiest night.</p>
        </div>
        <Controls
          rangeText={`${dayLong(start)} – ${dayLongYear(last)}`}
          settings={settings}
          onSettings={updateSettings}
          onPrev={() => setStart(addDaysIso(start, -7))}
          onNext={() => setStart(addDaysIso(start, 7))}
          onToday={() => setStart(iso(mondayOf(new Date())))}
          onExpandAll={() => setCollapsed(new Set())}
          onCollapseToFloors={collapseToFloors}
        />
      </header>

      {error && <p className="error">Could not load availability: {error.message}</p>}
      {!tenant || loading ? (
        <p>Loading…</p>
      ) : rows.length === 0 ? (
        <p className="av-empty">No locations in this tenant yet.</p>
      ) : (
        <TimelineGrid
          rows={rows}
          start={start}
          settings={settings}
          bars={bars.data ?? new Map()}
          summary={summary.data ?? new Map()}
          figures={figures.data ?? new Map()}
          onToggle={toggle}
        />
      )}
    </div>
  );
}
