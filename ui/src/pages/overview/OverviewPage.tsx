// Overview: for the chosen sites and weeks, a weekly chart of beds and places,
// then the warnings and a courses timeline. Everything comes from the API
// (0011); clicking a warning or course opens the same popups as Availability.
import { useCallback, useMemo, useState } from "react";
import { FilterIcon } from "../../icons";
import { useTenant } from "../../tenant";
import { Popover, RangePicker } from "../availability/Controls";
import { useBedBars, useCourseFigures, useLocations, useWarnings } from "../availability/data";
import { addDaysIso, dayLong, dayLongYear, ddmm, defaultStart, iso, mondayOf } from "../availability/dates";
import { Arrow, OverIcon, WarnIcon } from "../availability/look";
import { PopupView, type Notice } from "../availability/Popups";
import { useViewSettings } from "../availability/settings";
import type { LocationNode, Popup } from "../availability/types";
import { CourseTimeline } from "./CourseTimeline";
import { useSiteFilter, useWeeklyOverview } from "./data";
import { WeeklyChart } from "./WeeklyChart";
import "../availability/availability.css";
import "./overview.css";

export function OverviewPage() {
  const { code: tenant } = useTenant();
  const [settings] = useViewSettings(); // colour basis and thresholds, shared with Availability
  const [start, setStart] = useState(defaultStart);
  const [weeks, setWeeks] = useState(8);
  const [sites, setSites] = useSiteFilter(tenant);
  const [tab, setTab] = useState<"warnings" | "courses">("warnings");
  const to = addDaysIso(start, weeks * 7);

  const locations = useLocations(tenant);
  const nodes = useMemo(() => {
    const map = new Map<string, LocationNode>();
    const visit = (n: LocationNode) => {
      map.set(n.key, n);
      n.children.forEach(visit);
    };
    (locations.data ?? []).forEach(visit);
    return map;
  }, [locations.data]);
  const allSites = (locations.data ?? []).filter((n) => n.level === "Site");

  const overview = useWeeklyOverview(tenant, start, weeks, sites);
  const warnings = useWarnings(tenant, start, to, sites);
  const figures = useCourseFigures(tenant);
  const bars = useBedBars(tenant, start, weeks); // for opening bookings from warnings

  // Courses running in the weeks shown, at the chosen sites, earliest first.
  const courses = [...(figures.data?.values() ?? [])]
    .filter((c) => c.status !== "CANCELLED" && c.startDate < to && start < c.endDate)
    .filter((c) => sites === null || (c.siteId !== null && sites.includes(c.siteId)))
    .sort((a, b) => a.startDate.localeCompare(b.startDate) || a.code.localeCompare(b.code));

  const [popup, setPopup] = useState<{ p: Popup; seq: number } | null>(null);
  const open = useCallback((p: Popup) => setPopup((cur) => ({ p, seq: (cur?.seq ?? 0) + 1 })), []);
  const [notice, setNotice] = useState<Notice | null>(null);

  const siteLabel = sites === null ? "All sites"
    : sites.length === 0 ? "No sites"
    : sites.length === 1 ? allSites.find((s) => s.id === sites[0])?.name ?? "1 site"
    : `${sites.length} of ${allSites.length} sites`;
  const toggleSite = (id: number) => {
    const current = sites ?? allSites.map((s) => s.id);
    const next = current.includes(id) ? current.filter((x) => x !== id) : [...current, id];
    setSites(next.length === allSites.length ? null : next);
  };

  const list = warnings.data ?? [];
  const error = overview.error ?? warnings.error ?? figures.error;

  return (
    <div className="ov-page">
      <div className="av-toolbar">
        <div className="group">
          <button type="button" className="tb-btn icon" aria-label="Previous week" onClick={() => setStart(addDaysIso(start, -7))}>
            <Arrow dir="left" />
          </button>
          <Popover label="Choose weeks" align="left" triggerClass="tb-btn range-btn"
                   trigger={<span className="range">{dayLong(start)} – {dayLongYear(addDaysIso(to, -1))}</span>}>
            {(close) => <RangePicker start={start} weeks={weeks} onApply={(s, w) => { setStart(s); setWeeks(w); close(); }} />}
          </Popover>
          <button type="button" className="tb-btn icon" aria-label="Next week" onClick={() => setStart(addDaysIso(start, 7))}>
            <Arrow dir="right" />
          </button>
          <button type="button" className="tb-btn" onClick={() => setStart(iso(mondayOf(new Date())))}>Today</button>
          <Popover label="Filter sites" align="left" triggerClass={`tb-btn${sites !== null ? " active" : ""}`}
                   trigger={<><FilterIcon /> <span className="filter-label">{siteLabel}</span></>}>
            <div className="filter-panel">
              <h2>Sites</h2>
              <ul className="filter-tree">
                {allSites.map((s) => (
                  <li key={s.key}>
                    <label className="lvl-site">
                      <input type="checkbox" checked={sites === null || sites.includes(s.id)} onChange={() => toggleSite(s.id)} />
                      <span className="name">{s.name}</span>
                      <span className="meta">{s.bedCount} beds</span>
                    </label>
                  </li>
                ))}
              </ul>
              <div className="apply">
                <div className="quick">
                  <button type="button" className="tb-btn" disabled={sites === null} onClick={() => setSites(null)}>All</button>
                  <button type="button" className="tb-btn" disabled={sites?.length === 0} onClick={() => setSites([])}>None</button>
                </div>
              </div>
            </div>
          </Popover>
        </div>
      </div>

      {error && <p className="error">Could not load the overview: {error.message}</p>}
      {notice && (
        <div className={`av-notice${notice.warnings.length ? " warn" : ""}`} role="status">
          <div><strong>{notice.text}</strong></div>
          <button type="button" className="x" aria-label="Dismiss" onClick={() => setNotice(null)}>×</button>
        </div>
      )}

      <section className="ov-card">
        <h2>Beds and places by week</h2>
        <WeeklyChart rows={overview.data ?? []} />
      </section>

      <section className="ov-card ov-tabs">
        <div className="tab-bar" role="tablist">
          <button type="button" role="tab" aria-selected={tab === "warnings"} onClick={() => setTab("warnings")}>
            Warnings <span className="count">{list.length}</span>
          </button>
          <button type="button" role="tab" aria-selected={tab === "courses"} onClick={() => setTab("courses")}>
            Courses <span className="count">{courses.length}</span>
          </button>
        </div>
        <div className="tab-panel" role="tabpanel">
          {tab === "warnings" ? (
            list.length === 0 ? <p className="av-empty">No warnings for these sites and weeks.</p> : (
              <ul className="ov-warnings">
                {list.map((w, i) => (
                  <li key={`${w.kind}-${w.allocationId}-${w.courseId}-${i}`}>
                    <button type="button"
                            onClick={() => open(w.allocationId === null && w.courseId !== null
                              ? { kind: "course", courseId: w.courseId } : { kind: "warning", warning: w })}>
                      {w.kind === "LOADED_ABOVE_SCHEDULED" ? <OverIcon /> : <WarnIcon />}
                      <span className="msg">{w.message}</span>
                      <span className="when">{w.startDate && w.endDate ? `${ddmm(w.startDate)}–${ddmm(w.endDate)}` : ""}</span>
                      <span className={`sev sev-${w.severity.toLowerCase()}`}>{w.severity.toLowerCase()}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )
          ) : courses.length === 0 ? (
            <p className="av-empty">No courses run at these sites in these weeks.</p>
          ) : (
            <CourseTimeline courses={courses} start={start} weeks={weeks} settings={settings} onOpen={open} />
          )}
        </div>
      </section>

      {popup && (
        <PopupView key={popup.seq} popup={popup.p} onOpen={open} onNotice={setNotice} onClose={() => setPopup(null)}
                   data={{ tenant, settings, nodes, bars: bars.data ?? new Map(), figures: figures.data ?? new Map(),
                           summary: new Map(), warnings: list }} />
      )}
    </div>
  );
}
