// Availability page: header controls, legend, warnings strip, the grid, its
// popups (phase 2) and course booking through them (phase 3).
// Spec: claude_availability_page_overview.md; mockup: docs/pages_pocs/availability.html.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router";
import { PopupView, type Notice } from "./Popups";
import { WarnIcon } from "./look";
import { useTenant } from "../../tenant";
import { Controls } from "./Controls";
import { useBedBars, useCourseFigures, useLocations, useWarnings, useWeekSummary } from "./data";
import { WarningsStrip } from "./LegendAndWarnings";
import { addDaysIso, dayLong, dayLongYear, defaultStart, iso, mondayOf, parse } from "./dates";
import { useCollapsed, useLocationFilter, useViewSettings } from "./settings";
import { pruneTree } from "./Filter";
import { TimelineGrid, type VisibleRow } from "./TimelineGrid";
import type { LocationNode, Popup } from "./types";
import "./availability.css";

// A booking to bring into view when the page opens, e.g. from a warning on the
// Overview: passed as router state { focus }.
export interface FocusBooking {
  allocationId: number;
  bedId: number;
  startDate: string;
}

export function AvailabilityPage() {
  const { code: tenant } = useTenant();
  const [settings, updateSettings] = useViewSettings();
  const [collapsed, setCollapsed] = useCollapsed(tenant);
  const [start, setStart] = useState(defaultStart);

  const locations = useLocations(tenant);
  const figures = useCourseFigures(tenant);
  const bars = useBedBars(tenant, start, settings.weeks);
  const summary = useWeekSummary(tenant, start, settings.weeks);
  const warnings = useWarnings(tenant, start);

  // The open popup; `seq` gives each opening a fresh dialog.
  const [popup, setPopup] = useState<{ p: Popup; seq: number } | null>(null);
  const open = useCallback((p: Popup) => setPopup((cur) => ({ p, seq: (cur?.seq ?? 0) + 1 })), []);
  // The result of the last change made from a popup, until dismissed.
  const [notice, setNotice] = useState<Notice | null>(null);

  // Every location by key, for paths and lookups in popups.
  const nodes = useMemo(() => {
    const map = new Map<string, LocationNode>();
    const visit = (n: LocationNode) => {
      map.set(n.key, n);
      n.children.forEach(visit);
    };
    (locations.data ?? []).forEach(visit);
    return map;
  }, [locations.data]);

  // The part of the estate shown: the ticked blocks, with their sites and
  // buildings above them (all when there's no filter).
  const [filter, setFilter] = useLocationFilter(tenant);
  const estate = useMemo(() => locations.data ?? [], [locations.data]);
  const roots = useMemo(() => pruneTree(estate, filter), [estate, filter]);

  // Rows in tree order, stopping below collapsed nodes. A filtered (partial)
  // site or building can't collapse: its weekly counts from the database cover
  // all of its blocks, not just those shown.
  const rows = useMemo(() => {
    const out: VisibleRow[] = [];
    const visit = (n: LocationNode, depth: number) => {
      const isCollapsed = n.level !== "Bed" && !n.partial && collapsed.has(n.key);
      out.push({ node: n, depth, collapsed: isCollapsed });
      if (!isCollapsed) n.children.forEach((c) => visit(c, depth + 1));
    };
    roots.forEach((n) => visit(n, 0));
    return out;
  }, [roots, collapsed]);

  const toggle = useCallback(
    (key: string) => {
      const next = new Set(collapsed);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      setCollapsed(next);
    },
    [collapsed, setCollapsed],
  );

  // ---------------------- Arriving to show a booking ----------------------
  // Start the week before the booking, make its bed's row visible (expand the
  // rows above it; add its block to the filter if it's filtered out), then the
  // grid scrolls to the bar and highlights it.
  const location = useLocation();
  const navigate = useNavigate();
  const [focus, setFocus] = useState<(FocusBooking & { seq: number }) | null>(null);
  useEffect(() => {
    const f = (location.state as { focus?: FocusBooking } | null)?.focus;
    if (!f) return;
    setFocus({ ...f, seq: Date.now() });
    setStart(addDaysIso(iso(mondayOf(parse(f.startDate))), -7));
    navigate(location.pathname, { replace: true, state: null }); // not again on refresh or back
  }, [location.state, location.pathname, navigate]);

  const revealed = useRef<number | null>(null); // once per arrival, so rows can be collapsed again afterwards
  useEffect(() => {
    if (!focus || nodes.size === 0 || revealed.current === focus.seq) return;
    revealed.current = focus.seq;
    const above: LocationNode[] = [];
    for (let n = nodes.get(`bed:${focus.bedId}`); n?.parentKey; ) {
      n = nodes.get(n.parentKey);
      if (n) above.push(n);
    }
    const shut = above.filter((n) => collapsed.has(n.key));
    if (shut.length > 0) {
      const next = new Set(collapsed);
      shut.forEach((n) => next.delete(n.key));
      setCollapsed(next);
    }
    const block = above.find((n) => n.level === "Block");
    if (block && filter.blocks !== null && !filter.blocks.includes(block.key)) {
      setFilter({ blocks: [...filter.blocks, block.key] });
    }
  }, [focus, nodes, collapsed, setCollapsed, filter, setFilter]);

  const collapseToFloors = () => {
    const floors = new Set<string>();
    const visit = (n: LocationNode) => {
      if (n.level === "Floor") floors.add(n.key);
      else n.children.forEach(visit);
    };
    roots.forEach(visit);
    setCollapsed(floors);
  };

  const last = addDaysIso(start, settings.weeks * 7 - 1);
  const error = locations.error ?? figures.error ?? bars.error ?? summary.error;
  const loading = locations.isPending || figures.isPending || bars.isPending || summary.isPending;

  return (
    <div className="av-page">
      {/* The page title is in the app's title bar; the legend is a toolbar popover. */}
      <Controls
        roots={estate}
        filter={filter}
        onFilter={setFilter}
        rangeText={`${dayLong(start)} – ${dayLongYear(last)}`}
        start={start}
        onRange={(s, weeks) => { setStart(s); updateSettings({ weeks }); }}
        settings={settings}
        onSettings={updateSettings}
        onPrev={() => setStart(addDaysIso(start, -7))}
        onNext={() => setStart(addDaysIso(start, 7))}
        onToday={() => setStart(iso(mondayOf(new Date())))}
        onExpandAll={() => setCollapsed(new Set())}
        onCollapseToFloors={collapseToFloors}
        onOpen={open}
      />

      <WarningsStrip warnings={warnings.data ?? []} error={warnings.error} onOpen={open} />
      {notice && (
        <div className={`av-notice${notice.warnings.length ? " warn" : ""}`} role="status">
          <div>
            <strong>{notice.text}</strong>
            {notice.warnings.length > 0 && (
              <ul className="av-list">{notice.warnings.map((w, i) => <li key={i}><WarnIcon /> Saved with a warning: {w}</li>)}</ul>
            )}
          </div>
          <button type="button" className="x" aria-label="Dismiss" onClick={() => setNotice(null)}>×</button>
        </div>
      )}

      {error && <p className="error">Could not load availability: {error.message}</p>}
      {!tenant || loading ? (
        <p>Loading…</p>
      ) : rows.length === 0 ? (
        <p className="av-empty">
          {estate.length === 0 ? "No locations in this tenant yet." : "No locations are ticked in the filter."}
        </p>
      ) : (
        <TimelineGrid
          rows={rows}
          start={start}
          settings={settings}
          bars={bars.data ?? new Map()}
          summary={summary.data ?? new Map()}
          figures={figures.data ?? new Map()}
          onToggle={toggle}
          onOpen={open}
          highlight={focus ? { allocationId: focus.allocationId, seq: focus.seq } : null}
        />
      )}

      {popup && (
        <PopupView
          key={popup.seq}
          popup={popup.p}
          onOpen={open}
          onNotice={setNotice}
          onClose={() => setPopup(null)}
          data={{
            tenant,
            settings,
            nodes,
            bars: bars.data ?? new Map(),
            figures: figures.data ?? new Map(),
            summary: summary.data ?? new Map(),
            warnings: warnings.data ?? [],
          }}
        />
      )}
    </div>
  );
}
