// Popups (phase 2 step 4, writes from phase 3). What's shown comes from data the
// page already has, except clashes (fn_check_allocation) and candidate beds
// (fn_candidate_beds). Course allocations can be booked, moved, cancelled and
// have their status set (0009), and a course can be booked from its own popup
// (0013, D35); other edit forms come later.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { format, parseISO } from "date-fns";
import { useAudit, useCandidateBeds, useClashes } from "./data";
import { addDaysIso, dayIndex, dayLong, ddmm, iso, mondayOf } from "./dates";
import { basisOf, courseColour, OverIcon, STATE_NAMES, STATE_ORDER, WarnIcon } from "./look";
import type { ViewSettings } from "./settings";
import { weekCounts } from "./TimelineGrid";
import type { BedBar, CandidateBed, Clash, CourseFigure, Level, LocationNode, Popup, Warning, WeekSummary } from "./types";
import {
  COURSE_STATUSES, STATUSES, useAddOutage, useAllocateCourse, useBookExternal, useCancelAllocation, useCancelCourse, useCreateCourse, useMoveAllocation,
  useSetStatus, useUpdateCourse, useUpdateLoaded, type Allocated, type CourseChange, type CourseInput,
} from "./writes";

export interface PopupData {
  tenant: string | null;
  settings: ViewSettings;
  nodes: Map<string, LocationNode>;
  bars: Map<number, BedBar[]>;
  figures: Map<number, CourseFigure>;
  summary: Map<string, WeekSummary>;
  warnings: Warning[];
}

interface Props {
  popup: Popup;
  data: PopupData;
  onOpen: (p: Popup) => void;
  onNotice: (n: Notice) => void;
  onClose: () => void;
}

export function PopupView({ popup, data, onOpen, onNotice, onClose }: Props) {
  switch (popup.kind) {
    case "location": return <LocationPopup nodeKey={popup.key} data={data} onClose={onClose} />;
    case "booking": return <BookingPopup bar={popup.bar} data={data} onOpen={onOpen} onNotice={onNotice} onClose={onClose} />;
    case "outage": return <OutagePopup bar={popup.bar} data={data} onClose={onClose} />;
    case "week": return <WeekPopup nodeKey={popup.key} weekStart={popup.weekStart} data={data} onOpen={onOpen} onClose={onClose} />;
    case "course": return <CoursePopup courseId={popup.courseId} data={data} onOpen={onOpen} onNotice={onNotice} onClose={onClose} />;
    case "bookCourse": return <BookCoursePopup courseId={popup.courseId} data={data} onClose={onClose} />;
    case "newCourse": return <NewCoursePopup from={popup.from} to={popup.to} data={data} onOpen={onOpen} onClose={onClose} />;
    case "warning": return <WarningPopup warning={popup.warning} data={data} onOpen={onOpen} onNotice={onNotice} onClose={onClose} />;
    case "newExternal": return <NewExternalPopup bedKeys={popup.bedKeys} from={popup.from} to={popup.to} data={data} onOpen={onOpen} onClose={onClose} />;
    case "newOutage": return <NewOutagePopup nodeKey={popup.key} bedKeys={popup.bedKeys} from={popup.from} to={popup.to} data={data} onOpen={onOpen} onClose={onClose} />;
    case "move": return <MovePopup bar={popup.bar} bedKey={popup.bedKey} from={popup.from} to={popup.to} data={data} onClose={onClose} />;
    case "new": return <NewAllocationPopup bedKeys={popup.bedKeys} from={popup.from} to={popup.to} data={data} onOpen={onOpen} onClose={onClose} />;
  }
}

// ------------------------------- Pieces --------------------------------

// A modal dialog (native <dialog>: focus stays inside, Esc closes, focus returns).
function Dialog(p: { kind: string; title: string; onClose: () => void; children: ReactNode; actions?: ReactNode; wide?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  const onClose = useRef(p.onClose);
  onClose.current = p.onClose;
  // Where focus was when the popup opened (the bar or row clicked), captured on
  // first render so a re-run effect (React StrictMode in dev) can't change it.
  const returnTo = useRef(document.activeElement as HTMLElement | null);
  const done = useRef(false);

  // Every way of closing comes here once: close the dialog, put focus back,
  // tell the page. Done directly rather than waiting for the browser's "close"
  // event, which didn't always arrive in testing.
  const close = () => {
    if (done.current) return;
    done.current = true;
    ref.current?.close();
    const el = returnTo.current;
    if (el && document.contains(el)) el.focus();
    onClose.current();
  };
  const closeRef = useRef(close);
  closeRef.current = close;

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    // Esc fires "cancel" straight away; route it through close(). "close" is a
    // backstop for anything else that closes the dialog (e.g. a form).
    const onCancel = (e: Event) => {
      e.preventDefault();
      closeRef.current();
    };
    const onNativeClose = () => closeRef.current();
    d.addEventListener("cancel", onCancel);
    d.addEventListener("close", onNativeClose);
    if (!d.open) d.showModal();
    return () => {
      d.removeEventListener("cancel", onCancel);
      d.removeEventListener("close", onNativeClose);
    };
  }, []);
  return (
    <dialog ref={ref} className={`av-dialog${p.wide ? " wide" : ""}`} aria-labelledby="av-dialog-title"
            onClick={(e) => { if (e.target === ref.current) close(); }}>
      <div className="av-dialog-inner">
        <div className="av-dialog-head">
          <div>
            <div className="kind">{p.kind}</div>
            <h2 id="av-dialog-title">{p.title}</h2>
          </div>
          <button type="button" className="x" aria-label="Close" onClick={close}>×</button>
        </div>
        {p.children}
        <div className="actions">
          {p.actions}
          <button type="button" className="btn" onClick={close}>Close</button>
        </div>
      </div>
    </dialog>
  );
}

function Facts({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl>
      {rows.map(([k, v]) => (
        <div key={k} className="fact"><dt>{k}</dt><dd>{v}</dd></div>
      ))}
    </dl>
  );
}

const Later = ({ what }: { what: string }) => <p className="placeholder">{what} comes with the write API (phase 3).</p>;

// ------------------------------- Helpers -------------------------------

function pathOf(nodes: Map<string, LocationNode>, key: string): string {
  const names: string[] = [];
  for (let n = nodes.get(key); n; n = n.parentKey ? nodes.get(n.parentKey) : undefined) names.unshift(n.name);
  return names.join(" › ");
}

function ancestorAt(nodes: Map<string, LocationNode>, key: string, level: Level): LocationNode | undefined {
  for (let n = nodes.get(key); n; n = n.parentKey ? nodes.get(n.parentKey) : undefined) if (n.level === level) return n;
  return undefined;
}

function bedsUnder(n: LocationNode): LocationNode[] {
  return n.level === "Bed" ? [n] : n.children.flatMap(bedsUnder);
}

// "Mon 16/11 – Sun 22/11 (6 nights)": end is the departure day.
function stay(start: string, end: string) {
  const n = dayIndex(start, end);
  return `${dayLong(start)} – ${dayLong(end)} (${n} ${n === 1 ? "night" : "nights"})`;
}

const stamp = (s: string | null) => (s ? format(parseISO(s), "dd/MM/yyyy HH:mm") : "never");
// "NO_SHOW" -> "No show", "out of action" -> "Out of action".
const titleCase = (s: string) => s.charAt(0).toUpperCase() + s.slice(1).toLowerCase().replace(/_/g, " ");

function allocatedText(c: CourseFigure, s: ViewSettings) {
  const pct = s.basis === "loaded" ? c.pctLoaded : c.pctScheduled;
  return `${c.allocated} of ${basisOf(c, s)} ${s.basis}` + (pct !== null ? ` (${pct}%)` : "") +
    ` · ${STATE_NAMES[courseColour(c, s)]}`;
}

function WarningList({ list }: { list: Warning[] }) {
  if (list.length === 0) return <>None</>;
  return (
    <ul className="av-list">
      {list.map((w, i) => (
        <li key={i}>{w.kind === "LOADED_ABOVE_SCHEDULED" ? <OverIcon /> : <WarnIcon />} {w.message}</li>
      ))}
    </ul>
  );
}

// "15/11 16:02"
const when = (s: string) => format(parseISO(s), "dd/MM HH:mm");

// The history of a course or a booking (api.audit, D37): who, when, what.
function HistoryList({ tenant, courseId, allocationId }: { tenant: string | null; courseId?: number; allocationId?: number }) {
  const history = useAudit(tenant, { courseId, allocationId });
  return (
    <div className="av-changes">
      <h3>History</h3>
      {history.isPending ? <p className="summary">Loading…</p> :
        history.error ? <p className="clash bad">Could not load the history: {history.error.message}</p> :
        history.data.length === 0 ? <p className="summary">No changes recorded.</p> : (
          <ul className="av-history">
            {history.data.map((h) => (
              <li key={h.auditId}>
                <span className="when">{when(h.changedAt)}</span>
                <span className="who">{h.changedBy}</span>
                <span className="what">{h.warnings.length > 0 && <WarnIcon />} {h.summary}</span>
              </li>
            ))}
          </ul>
        )}
    </div>
  );
}

function findBar(bars: Map<number, BedBar[]>, allocationId: number): BedBar | undefined {
  for (const list of bars.values()) {
    const b = list.find((x) => x.kind !== "outage" && x.id === allocationId);
    if (b) return b;
  }
  return undefined;
}

// ------------------------------- Popups --------------------------------

function LocationPopup({ nodeKey, data, onClose }: { nodeKey: string; data: PopupData; onClose: () => void }) {
  const node = data.nodes.get(nodeKey);
  if (!node) return null;
  // Outages on any bed at or below this location, in the weeks loaded.
  const seen = new Map<number, { bar: BedBar; setOn: string }>();
  for (const bed of bedsUnder(node)) {
    for (const b of data.bars.get(bed.id) ?? []) {
      if (b.kind !== "outage" || seen.has(b.id)) continue;
      const level = b.set_on_level ?? "Bed";
      const at = ancestorAt(data.nodes, bed.key, level);
      seen.set(b.id, { bar: b, setOn: at ? `${at.name} (${level.toLowerCase()})` : level });
    }
  }
  const outages = [...seen.values()];
  return (
    <Dialog kind={node.level} title={node.name} onClose={onClose}>
      <Facts rows={[
        ["Path", pathOf(data.nodes, node.key)],
        ["Beds", node.bedCount],
        ["Outages in the weeks shown", outages.length === 0 ? "None" : (
          <ul className="av-list">
            {outages.map(({ bar, setOn }) => (
              <li key={bar.id}>{bar.reason ?? "No reason given"} · {setOn} · {stay(bar.start_date, bar.end_date)}</li>
            ))}
          </ul>
        )],
      ]} />
      <Later what="Editing location details and dated attributes" />
    </Dialog>
  );
}

function BookingPopup({ bar, data, onOpen, onNotice, onClose }: {
  bar: BedBar; data: PopupData; onOpen: (p: Popup) => void; onNotice: (n: Notice) => void; onClose: () => void;
}) {
  const bedPath = pathOf(data.nodes, `bed:${bar.bed_id}`);
  const warnings = data.warnings.filter(
    (w) => w.allocationId === bar.id || (bar.course_id !== null && w.allocationId === null && w.courseId === bar.course_id),
  );

  if (bar.kind === "external") {
    return (
      <Dialog kind="External booking" title={bar.external_ref ?? "External booking"} onClose={onClose}>
        <Facts rows={[
          ["Name", bar.external_name ?? ""],
          ["Bed", bedPath],
          ["Nights", stay(bar.start_date, bar.end_date)],
          ["Status", titleCase(bar.status ?? "")],
          ["Warnings", <WarningList list={warnings} />],
        ]} />
        <HistoryList tenant={data.tenant} allocationId={bar.id} />
      </Dialog>
    );
  }

  // Individual numbers are internal (D31): the title names the course only.
  const c = bar.course_id !== null ? data.figures.get(bar.course_id) : undefined;
  return (
    <Dialog kind="Allocation" title={c ? `${c.code}: ${c.name}` : bar.course_code ?? "Allocation"} onClose={onClose}
            actions={c && <button type="button" className="btn" onClick={() => onOpen({ kind: "course", courseId: c.courseId })}>Open course</button>}>
      <Facts rows={[
        ["Bed", bedPath],
        ["Nights", stay(bar.start_date, bar.end_date)],
        ["Status", titleCase(bar.status ?? "")],
        ...(c ? ([
          ["Scheduled", c.scheduled],
          ["Loaded", `${c.loaded} (updated ${stamp(c.loadedAt)})`],
          ["Allocated", allocatedText(c, data.settings)],
        ] as [string, ReactNode][]) : []),
        ["Warnings", <WarningList list={warnings} />],
      ]} />
      <BookingChanges bar={bar} data={data} onNotice={onNotice} onClose={onClose} />
      <HistoryList tenant={data.tenant} allocationId={bar.id} />
    </Dialog>
  );
}

// Change a course allocation: status, move (bed and/or dates), cancel. The
// database checks and audits each (0009); results go to the page's notice.
function BookingChanges({ bar, data, onNotice, onClose }: {
  bar: BedBar; data: PopupData; onNotice: (n: Notice) => void; onClose: () => void;
}) {
  const [status, setStatus] = useState(bar.status ?? "ALLOCATED");
  const [bedKey, setBedKey] = useState(`bed:${bar.bed_id}`);
  const [first, setFirst] = useState(bar.start_date);
  const [departure, setDeparture] = useState(bar.end_date);
  const setStatusCall = useSetStatus(data.tenant);
  const move = useMoveAllocation(data.tenant);
  const cancel = useCancelAllocation(data.tenant);
  const busy = setStatusCall.isPending || move.isPending || cancel.isPending;
  const error = setStatusCall.error ?? move.error ?? cancel.error;

  const beds = [...data.nodes.values()].filter((n) => n.level === "Bed"); // tree order
  const bed = data.nodes.get(bedKey);
  const moved = bedKey !== `bed:${bar.bed_id}` || first !== bar.start_date || departure !== bar.end_date;
  const datesOk = first !== "" && departure !== "" && departure > first;
  const label = bar.course_code ?? "Allocation";

  const done = (n: Notice) => {
    onNotice(n);
    onClose();
  };

  return (
    <div className="av-changes">
      <h3>Change</h3>
      <div className="row">
        <label className="av-field">
          Status
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            {STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}
          </select>
        </label>
        <button type="button" className="btn" disabled={busy || status === bar.status}
                onClick={() => setStatusCall.mutate({ id: bar.id, status }, {
                  onSuccess: (r) => done({ text: `${label}: status set to ${titleCase(r.status)}.`, warnings: [] }),
                })}>
          Set status
        </button>
      </div>

      <div className="row">
        <label className="av-field grow">
          Bed
          <select value={bedKey} onChange={(e) => setBedKey(e.target.value)}>
            {beds.map((b) => <option key={b.key} value={b.key}>{pathOf(data.nodes, b.key).split(" › ").slice(-3).join(" › ")}</option>)}
          </select>
        </label>
      </div>
      <div className="dates">
        <label>First night<input type="date" value={first} onChange={(e) => setFirst(e.target.value)} /></label>
        <label>Departure<input type="date" value={departure} onChange={(e) => setDeparture(e.target.value)} /></label>
      </div>
      <div className="row end">
        <button type="button" className="btn" disabled={busy || !moved || !datesOk || !bed}
                onClick={() => bed && move.mutate({ id: bar.id, bedId: bed.id, from: first, to: departure }, {
                  onSuccess: (r) => done({ text: `${label}: moved to ${bedName(data.nodes, bed)}, ${stay(r.start_date, r.end_date)}.`, warnings: r.warnings }),
                })}>
          Move
        </button>
        <button type="button" className="btn danger" disabled={busy}
                onClick={() => {
                  if (window.confirm(`Cancel this ${label} allocation? It stays in the history as cancelled.`)) {
                    cancel.mutate(bar.id, { onSuccess: () => done({ text: `${label}: allocation cancelled.`, warnings: [] }) });
                  }
                }}>
          Cancel allocation
        </button>
      </div>
      {!datesOk && <p className="clash bad">Departure must be after the first night.</p>}
      {error && <p className="clash bad">Not saved: {error.message}</p>}
    </div>
  );
}

// A message for the page after a write, with any warnings the database returned.
export interface Notice {
  text: string;
  warnings: string[];
}

function OutagePopup({ bar, data, onClose }: { bar: BedBar; data: PopupData; onClose: () => void }) {
  const level = bar.set_on_level ?? "Bed";
  const at = ancestorAt(data.nodes, `bed:${bar.bed_id}`, level);
  const bedIds = at ? bedsUnder(at).map((b) => b.id) : [bar.bed_id];
  const clashes = useClashes(data.tenant, bedIds, bar.start_date, bar.end_date);
  const bookings = (clashes.data ?? []).filter((c) => c.kind === "BOOKING");

  return (
    <Dialog kind="Out of action" title={bar.reason ?? "Out of action"} onClose={onClose}>
      <Facts rows={[
        ["Set on", at ? `${pathOf(data.nodes, at.key)} (${level.toLowerCase()})` : level],
        ["Dates", stay(bar.start_date, bar.end_date)],
        ["Reason", bar.reason ?? "No reason given"],
        ["Bookings affected", clashes.isPending ? "Checking…" : clashes.error ? `Could not check: ${clashes.error.message}` :
          bookings.length === 0 ? "None" : (
            <ul className="av-list">
              {bookings.map((c, i) => (
                <li key={i}>{c.ref} · {pathOf(data.nodes, `bed:${c.bed_id}`).split(" › ").slice(-2).join(" ")} · {ddmm(c.start_date)}–{ddmm(c.end_date)}</li>
              ))}
            </ul>
          )],
      ]} />
      <Later what="Editing or ending an outage" />
    </Dialog>
  );
}

function WeekPopup({ nodeKey, weekStart, data, onOpen, onClose }: {
  nodeKey: string; weekStart: string; data: PopupData; onOpen: (p: Popup) => void; onClose: () => void;
}) {
  const node = data.nodes.get(nodeKey);
  const s = data.summary.get(`${nodeKey}|${weekStart}`);
  if (!node || !s) return null;
  const counts = weekCounts(s, data.figures, data.settings);
  return (
    <Dialog kind={`Week of ${ddmm(weekStart)}`} title={node.name} onClose={onClose}>
      <p className="summary">Busiest night: {dayLong(s.busiestNight)}, the night with the fewest free beds.</p>
      <Facts rows={[
        ...STATE_ORDER.filter((k) => counts[k] > 0).map((k) => [titleCase(STATE_NAMES[k]), counts[k]] as [string, ReactNode]),
        ["Courses", s.courses.length === 0 ? "None" : (
          <ul className="av-list">
            {s.courses.map((c) => {
              const f = data.figures.get(c.courseId);
              return (
                <li key={c.courseId}>
                  <button type="button" className="link" onClick={() => onOpen({ kind: "course", courseId: c.courseId })}>
                    {f?.code ?? `Course ${c.courseId}`}
                  </button>
                  : {c.beds} {c.beds === 1 ? "bed" : "beds"}{f && ` · ${allocatedText(f, data.settings)}`}
                </li>
              );
            })}
          </ul>
        )],
      ]} />
    </Dialog>
  );
}

function CoursePopup({ courseId, data, onOpen, onNotice, onClose }: {
  courseId: number; data: PopupData; onOpen: (p: Popup) => void; onNotice: (n: Notice) => void; onClose: () => void;
}) {
  const c = data.figures.get(courseId);
  if (!c) return null;
  const warnings = data.warnings.filter((w) => w.courseId === courseId && w.allocationId === null);
  return (
    <Dialog kind="Course" title={`${c.code}: ${c.name}`} onClose={onClose}
            actions={c.status !== "CANCELLED" && (
              <button type="button" className="btn primary" onClick={() => onOpen({ kind: "bookCourse", courseId })}>Book beds</button>
            )}>
      <Facts rows={[
        ["Dates", stay(c.startDate, c.endDate)],
        ["Status", titleCase(c.status)],
        ["Scheduled", c.scheduled],
        ["Loaded", `${c.loaded} (updated ${stamp(c.loadedAt)})`],
        ["Allocated", `${c.allocated}`],
        ["Of scheduled", c.pctScheduled !== null ? `${c.pctScheduled}%` : "No scheduled figure"],
        ["Of loaded", c.pctLoaded !== null ? `${c.pctLoaded}%` : "No loaded figure"],
        ["Colour", allocatedText(c, data.settings)],
        ["Warnings", <WarningList list={warnings} />],
      ]} />
      <CourseChanges c={c} data={data} onNotice={onNotice} onClose={onClose} />
      <HistoryList tenant={data.tenant} courseId={courseId} />
    </Dialog>
  );
}

// ----------------------------- Courses (D36) -----------------------------

const sitesOf = (nodes: Map<string, LocationNode>) => [...nodes.values()].filter((n) => n.level === "Site");

function courseValid(v: CourseInput) {
  return v.code.trim() !== "" && v.name.trim() !== "" && v.startDate !== "" && v.endDate !== "" &&
    v.endDate > v.startDate && v.scheduled >= 0 && v.loaded >= 0;
}

// The course fields shared by the New course form and the Course popup's edit
// form. The database validates; this only keeps the inputs well-formed.
function CourseFields({ value: v, onChange, sites, withLoaded, disabled }: {
  value: CourseInput; onChange: (v: CourseInput) => void; sites: LocationNode[]; withLoaded: boolean; disabled: boolean;
}) {
  const set = (patch: Partial<CourseInput>) => onChange({ ...v, ...patch });
  const num = (s: string) => Math.max(0, Math.min(9999, Math.floor(Number(s)) || 0));
  return (
    <div className="av-form">
      <label className="av-field">Code<input type="text" maxLength={30} value={v.code} disabled={disabled} onChange={(e) => set({ code: e.target.value })} /></label>
      <label className="av-field">Name<input type="text" maxLength={200} value={v.name} disabled={disabled} onChange={(e) => set({ name: e.target.value })} /></label>
      <label className="av-field">Site
        <select value={v.siteId ?? ""} disabled={disabled} onChange={(e) => set({ siteId: e.target.value === "" ? null : Number(e.target.value) })}>
          <option value="">No site (any bed)</option>
          {sites.map((s) => <option key={s.key} value={s.id}>{s.name}</option>)}
        </select>
      </label>
      <label className="av-field">Status
        <select value={v.status} disabled={disabled} onChange={(e) => set({ status: e.target.value })}>
          {COURSE_STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}
        </select>
      </label>
      <label className="av-field">First night<input type="date" value={v.startDate} disabled={disabled} onChange={(e) => set({ startDate: e.target.value })} /></label>
      <label className="av-field">Departure<input type="date" value={v.endDate} disabled={disabled} onChange={(e) => set({ endDate: e.target.value })} /></label>
      <label className="av-field">Scheduled<input type="number" min={0} max={9999} value={v.scheduled} disabled={disabled} onChange={(e) => set({ scheduled: num(e.target.value) })} /></label>
      {withLoaded && (
        <label className="av-field">Loaded<input type="number" min={0} max={9999} value={v.loaded} disabled={disabled} onChange={(e) => set({ loaded: num(e.target.value) })} /></label>
      )}
    </div>
  );
}

// Add a course (fn_create_course), then offer to book its beds straight away.
function NewCoursePopup({ from, to, data, onOpen, onClose }: {
  from?: string; to?: string; data: PopupData; onOpen: (p: Popup) => void; onClose: () => void;
}) {
  const sites = sitesOf(data.nodes);
  // Dates from weeks dragged on the Courses tab, else next week.
  const monday = addDaysIso(iso(mondayOf(new Date())), 7);
  const [v, setV] = useState<CourseInput>({
    code: "", name: "", siteId: sites.length === 1 ? sites[0].id : null,
    startDate: from ?? monday, endDate: to ?? addDaysIso(monday, 5), scheduled: 0, loaded: 0, status: "REQUESTED",
  });
  const create = useCreateCourse(data.tenant);
  const valid = courseValid(v);

  if (create.data) {
    const id = create.data.course_id;
    return (
      <Dialog kind="Course added" title={`${create.data.code}: ${v.name.trim()}`} onClose={onClose}
              actions={<button type="button" className="btn primary" onClick={() => onOpen({ kind: "bookCourse", courseId: id })}>Book beds</button>}>
        <p className="clash ok">Saved: {stay(v.startDate, v.endDate)}, {v.scheduled} scheduled, {v.loaded} loaded.</p>
      </Dialog>
    );
  }

  return (
    <Dialog kind="New course" title="Add a course" onClose={onClose} wide
            actions={
              <button type="button" className="btn primary" disabled={!valid || create.isPending}
                      onClick={() => create.mutate({ ...v, code: v.code.trim(), name: v.name.trim() })}>
                {create.isPending ? "Saving…" : "Add course"}
              </button>
            }>
      <CourseFields value={v} onChange={setV} sites={sites} withLoaded disabled={create.isPending} />
      {v.startDate && v.endDate && (v.endDate > v.startDate
        ? <p className="summary">{stay(v.startDate, v.endDate)}</p>
        : <p className="clash bad">Departure must be after the first night.</p>)}
      {create.error && <p className="clash bad">Not saved: {create.error.message}</p>}
    </Dialog>
  );
}

// Edit a course from its popup: details (fn_update_course), the loaded figure
// (fn_update_loaded) and cancelling it with its bookings (fn_cancel_course).
function CourseChanges({ c, data, onNotice, onClose }: {
  c: CourseFigure; data: PopupData; onNotice: (n: Notice) => void; onClose: () => void;
}) {
  const sites = sitesOf(data.nodes);
  const current: CourseInput = {
    code: c.code, name: c.name, siteId: c.siteId, startDate: c.startDate, endDate: c.endDate,
    scheduled: c.scheduled, loaded: c.loaded, status: c.status === "CANCELLED" ? "REQUESTED" : c.status,
  };
  const [v, setV] = useState<CourseInput>(current);
  const [loaded, setLoaded] = useState(c.loaded);
  const update = useUpdateCourse(data.tenant);
  const updateLoaded = useUpdateLoaded(data.tenant);
  const cancel = useCancelCourse(data.tenant);
  const busy = update.isPending || updateLoaded.isPending || cancel.isPending;
  const error = update.error ?? updateLoaded.error ?? cancel.error;
  const cancelled = c.status === "CANCELLED";

  // Only what differs from the course as it is.
  const change: CourseChange = { id: c.courseId };
  const code = v.code.trim(), name = v.name.trim();
  if (code !== c.code) change.code = code;
  if (name !== c.name) change.name = name;
  if (v.siteId !== c.siteId) change.siteId = v.siteId;
  if (v.startDate !== c.startDate) change.startDate = v.startDate;
  if (v.endDate !== c.endDate) change.endDate = v.endDate;
  if (v.scheduled !== c.scheduled) change.scheduled = v.scheduled;
  if (v.status !== c.status) change.status = v.status;
  const changed = Object.keys(change).length > 1;

  const done = (n: Notice) => {
    onNotice(n);
    onClose();
  };

  return (
    <div className="av-changes">
      <h3>{cancelled ? "Reinstate" : "Change"}</h3>
      {cancelled && <p className="summary">This course is cancelled. Set a status and save to reinstate it; its bookings stay cancelled.</p>}
      <CourseFields value={v} onChange={setV} sites={sites} withLoaded={false} disabled={busy} />
      <div className="row end">
        <button type="button" className="btn" disabled={busy || !changed || !courseValid(v)}
                onClick={() => update.mutate(change, {
                  onSuccess: (r) => done({ text: `${code}: saved.`, warnings: r.warnings }),
                })}>
          {cancelled ? "Reinstate" : "Save changes"}
        </button>
      </div>

      {!cancelled && (
        <>
          <div className="row">
            <label className="av-field">
              Loaded (registered so far)
              <input type="number" min={0} max={9999} value={loaded} disabled={busy}
                     onChange={(e) => setLoaded(Math.max(0, Math.min(9999, Math.floor(Number(e.target.value)) || 0)))} />
            </label>
            <button type="button" className="btn" disabled={busy}
                    onClick={() => updateLoaded.mutate({ id: c.courseId, loaded }, {
                      onSuccess: (r) => done({
                        text: `${c.code}: ${r.loaded} loaded as of now.`,
                        warnings: r.loaded_above_scheduled ? [`${r.loaded} loaded is above ${c.scheduled} scheduled`] : [],
                      }),
                    })}>
              Update loaded
            </button>
          </div>
          <div className="row end">
            <button type="button" className="btn danger" disabled={busy}
                    onClick={() => {
                      if (window.confirm(`Cancel ${c.code} and its ${c.allocated} ${c.allocated === 1 ? "booking" : "bookings"}? They stay in the history as cancelled.`)) {
                        cancel.mutate(c.courseId, {
                          onSuccess: (r) => done({
                            text: `${c.code} cancelled, with ${r.allocations_cancelled} ${r.allocations_cancelled === 1 ? "booking" : "bookings"}.`,
                            warnings: [],
                          }),
                        });
                      }
                    }}>
              Cancel course
            </button>
          </div>
        </>
      )}
      {error && <p className="clash bad">Not saved: {error.message}</p>}
    </div>
  );
}

// From the warnings strip: a booking warning opens the booking if it's in the
// weeks loaded; otherwise the warning's own details.
function WarningPopup({ warning: w, data, onOpen, onNotice, onClose }: {
  warning: Warning; data: PopupData; onOpen: (p: Popup) => void; onNotice: (n: Notice) => void; onClose: () => void;
}) {
  const bar = w.allocationId !== null ? findBar(data.bars, w.allocationId) : undefined;
  if (bar) return <BookingPopup bar={bar} data={data} onOpen={onOpen} onNotice={onNotice} onClose={onClose} />;
  const c = w.courseId !== null ? data.figures.get(w.courseId) : undefined;
  return (
    <Dialog kind="Warning" title={w.message} onClose={onClose}
            actions={c && <button type="button" className="btn" onClick={() => onOpen({ kind: "course", courseId: c.courseId })}>Open course</button>}>
      <Facts rows={[
        ["Kind", titleCase(w.kind)],
        ["Severity", titleCase(w.severity)],
        ...(w.bedId !== null ? ([["Bed", pathOf(data.nodes, `bed:${w.bedId}`)]] as [string, ReactNode][]) : []),
        ...(w.startDate && w.endDate ? ([["Nights", stay(w.startDate, w.endDate)]] as [string, ReactNode][]) : []),
      ]} />
    </Dialog>
  );
}

// A selection from the grid (D8-D10): the beds, editable exact dates, every
// clash on those beds (fn_check_allocation), and the booking itself. Course
// booking here; "External booking" switches to that popup with the same beds and
// dates (D38). The database decides what is allowed: a clash whose rule is
// BLOCK says "Not allowed" (D30).
function NewAllocationPopup({ bedKeys, from, to, data, onOpen, onClose }: {
  bedKeys: string[]; from: string; to: string; data: PopupData; onOpen: (p: Popup) => void; onClose: () => void;
}) {
  const [first, setFirst] = useState(from);
  const [departure, setDeparture] = useState(to);
  const valid = first !== "" && departure !== "" && departure > first;

  const beds = bedKeys.map((k) => data.nodes.get(k)).filter((n): n is LocationNode => n !== undefined);
  const byId = new Map(beds.map((b) => [b.id, b]));

  // Courses to choose from: not cancelled, and running on at least one of the
  // selected nights (half-open dates, as in the database). Earliest first.
  const courses = valid
    ? [...data.figures.values()]
        .filter((c) => c.status !== "CANCELLED" && c.startDate < departure && first < c.endDate)
        .sort((a, b) => a.startDate.localeCompare(b.startDate) || a.code.localeCompare(b.code))
    : [];
  const [chosenId, setCourseId] = useState<number | null>(() => courses[0]?.courseId ?? null);
  // If the dates change so the chosen course no longer runs then, fall back to
  // the first course that does.
  const course = courses.find((c) => c.courseId === chosenId) ?? courses[0];
  const courseId = course?.courseId ?? null;

  // Clashes on the beds, plus (given the course) whether the nights go outside
  // its dates: both from the database.
  const clashes = useClashes(data.tenant, beds.map((b) => b.id), first, departure, valid, courseId);
  const outsideCourse = (clashes.data ?? []).find((c) => c.kind === "COURSE_DATES");
  const list = (clashes.data ?? []).filter((c) => c.kind !== "COURSE_DATES");
  const blocked = list.some((c) => c.blocks);

  const allocate = useAllocateCourse(data.tenant);
  const canAllocate = valid && course !== undefined && !clashes.isPending && !clashes.error && !blocked && !allocate.isPending;

  if (allocate.data) {
    return <AllocatedResult course={course} result={allocate.data} first={first} departure={departure} onClose={onClose} />;
  }

  return (
    <Dialog kind="New allocation" title={`${beds.length} ${beds.length === 1 ? "bed" : "beds"}`} onClose={onClose}
            actions={
              <button type="button" className="btn primary" disabled={!canAllocate}
                      onClick={() => course && allocate.mutate({ courseId: course.courseId, bedIds: beds.map((b) => b.id), from: first, to: departure })}>
                {allocate.isPending ? "Allocating…" : "Allocate"}
              </button>
            }>
      <SelectionModes current="new" bedKeys={bedKeys} from={first} to={departure} onOpen={onOpen} />

      <Facts rows={[["Beds", beds.map((b) => bedName(data.nodes, b)).join(", ")]]} />

      <label className="av-field">
        Course
        <select value={courseId ?? ""} disabled={courses.length === 0}
                onChange={(e) => setCourseId(Number(e.target.value))}>
          {courses.length === 0 && <option value="">No courses run on these nights</option>}
          {courses.map((c) => (
            <option key={c.courseId} value={c.courseId}>
              {c.code}: {c.name} ({ddmm(c.startDate)}–{ddmm(c.endDate)})
            </option>
          ))}
        </select>
      </label>
      {course && (
        <p className="summary">
          {course.allocated} allocated of {course.scheduled} scheduled, {course.loaded} loaded. Allocating beyond these is allowed.{" "}
          {(course.startDate !== first || course.endDate !== departure) && (
            <button type="button" className="link" onClick={() => { setFirst(course.startDate); setDeparture(course.endDate); }}>
              Use the course's dates ({ddmm(course.startDate)}–{ddmm(course.endDate)})
            </button>
          )}
        </p>
      )}

      <div className="dates">
        <label>First night<input type="date" value={first} onChange={(e) => setFirst(e.target.value)} /></label>
        <label>Departure<input type="date" value={departure} onChange={(e) => setDeparture(e.target.value)} /></label>
      </div>
      {valid ? <p className="summary">{stay(first, departure)}</p> : <p className="clash bad">Departure must be after the first night.</p>}
      {valid && (clashes.isPending ? <p className="summary">Checking for clashes…</p> :
        clashes.error ? <p className="clash bad">Could not check clashes: {clashes.error.message}</p> :
        list.length === 0 ? <p className="clash ok">No clashes on these beds for these nights.</p> : (
          <div className="clash bad">
            <strong>
              {blocked ? "Not allowed: " : ""}{list.length} {list.length === 1 ? "clash" : "clashes"}
            </strong>{" "}
            {blocked ? "(a clash rule is set to block)" : "(allowed with a warning)"}
            <ul className="av-list">
              {list.map((c, i) => {
                const bed = c.bed_id !== null ? byId.get(c.bed_id) : undefined;
                return (
                  <li key={i}>
                    {bed ? bedName(data.nodes, bed) : `Bed ${c.bed_id}`}: {c.kind === "BOOKING" ? c.ref : `out of action, ${c.ref}`} ·{" "}
                    {ddmm(c.start_date)}–{ddmm(c.end_date)}{c.blocks ? " · blocks" : ""}
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      {valid && outsideCourse && (
        <p className="clash bad">
          <WarnIcon /> These nights go outside {outsideCourse.ref}'s dates ({ddmm(outsideCourse.start_date)}–{ddmm(outsideCourse.end_date)}).
          Allowed with a warning.
        </p>
      )}
      {allocate.error && <p className="clash bad">Not saved: {allocate.error.message}</p>}
    </Dialog>
  );
}

// After a booking: what was written and the warnings the database returned.
function AllocatedResult({ course, result, first, departure, onClose }: {
  course: CourseFigure | undefined; result: Allocated[]; first: string; departure: string; onClose: () => void;
}) {
  const warnings = result.flatMap((a) => a.warnings);
  return (
    <Dialog kind="Allocated" title={`${course?.code ?? "Course"}: ${result.length} ${result.length === 1 ? "bed" : "beds"}`} onClose={onClose}>
      <p className="clash ok">Saved: {stay(first, departure)}.</p>
      {warnings.length > 0 && (
        <div className="clash bad">
          <strong>Saved with {warnings.length} {warnings.length === 1 ? "warning" : "warnings"}</strong>
          <ul className="av-list">{warnings.map((w, i) => <li key={i}><WarnIcon /> {w}</li>)}</ul>
        </div>
      )}
    </Dialog>
  );
}

// Course-first booking (D35): from a course, choose the dates and how many beds
// are needed; the database suggests beds (fn_candidate_beds: free, keeping the
// course together, filling rooms), the user adjusts, and the booking goes
// through the same fn_allocate_course as the grid. The suggestion only advises.
function BookCoursePopup({ courseId, data, onClose }: { courseId: number; data: PopupData; onClose: () => void }) {
  const c = data.figures.get(courseId);
  const [first, setFirst] = useState(c?.startDate ?? "");
  const [departure, setDeparture] = useState(c?.endDate ?? "");
  // Default: the larger of scheduled and loaded, less what is already allocated.
  const [need, setNeed] = useState(c ? Math.max(1, Math.max(c.scheduled, c.loaded) - c.allocated) : 1);
  // Beds ticked by hand, for the dates and quantity they were ticked under;
  // otherwise the suggestion is followed.
  const [ticked, setTicked] = useState<{ key: string; ids: Set<number> } | null>(null);
  const valid = first !== "" && departure !== "" && departure > first;
  const candidates = useCandidateBeds(data.tenant, courseId, first, departure, need, valid);
  const allocate = useAllocateCourse(data.tenant);
  if (!c) return null;

  const rows = candidates.data ?? [];
  const key = `${first}|${departure}|${need}`;
  const byHand = ticked !== null && ticked.key === key;
  const chosen = ticked !== null && ticked.key === key ? ticked.ids : new Set(rows.filter((b) => b.suggested).map((b) => b.bed_id));
  const toggle = (id: number) => {
    const next = new Set(chosen);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setTicked({ key, ids: next });
  };

  // Rooms in estate order, each with its beds.
  const rooms: { id: number; name: string; where: string; beds: CandidateBed[] }[] = [];
  for (const b of rows) {
    const last = rooms[rooms.length - 1];
    if (last && last.id === b.room_id) last.beds.push(b);
    else rooms.push({ id: b.room_id, name: b.room_name, where: `${b.block_name} › ${b.floor_name}`, beds: [b] });
  }
  const bedIds = rows.filter((b) => chosen.has(b.bed_id)).map((b) => b.bed_id); // estate order
  const canBook = valid && bedIds.length > 0 && !candidates.isPending && !candidates.error && !allocate.isPending;
  const offDates = c.startDate !== first || c.endDate !== departure;

  if (allocate.data) {
    return <AllocatedResult course={c} result={allocate.data} first={first} departure={departure} onClose={onClose} />;
  }

  return (
    <Dialog kind="Book beds" title={`${c.code}: ${c.name}`} onClose={onClose} wide
            actions={
              <button type="button" className="btn primary" disabled={!canBook}
                      onClick={() => allocate.mutate({ courseId, bedIds, from: first, to: departure })}>
                {allocate.isPending ? "Booking…" : `Book ${bedIds.length} ${bedIds.length === 1 ? "bed" : "beds"}`}
              </button>
            }>
      <p className="summary">
        {c.allocated} allocated of {c.scheduled} scheduled, {c.loaded} loaded. The suggested beds keep the course
        together and fill rooms; tick or untick beds as you like.
      </p>

      <div className="dates three">
        <label>First night<input type="date" value={first} onChange={(e) => setFirst(e.target.value)} /></label>
        <label>Departure<input type="date" value={departure} onChange={(e) => setDeparture(e.target.value)} /></label>
        <label>Beds needed
          <input type="number" min={0} max={99} value={need}
                 onChange={(e) => setNeed(Math.max(0, Math.min(99, Number(e.target.value) || 0)))} />
        </label>
      </div>
      {valid ? (
        <p className="summary">
          {stay(first, departure)}
          {offDates && (
            <>
              {" "}· Outside the course's dates ({ddmm(c.startDate)}–{ddmm(c.endDate)}): allowed with a warning.{" "}
              <button type="button" className="link" onClick={() => { setFirst(c.startDate); setDeparture(c.endDate); }}>
                Use the course's dates
              </button>
            </>
          )}
        </p>
      ) : <p className="clash bad">Departure must be after the first night.</p>}

      {valid && (candidates.isPending ? <p className="summary">Finding beds…</p> :
        candidates.error ? <p className="clash bad">Could not find beds: {candidates.error.message}</p> :
        rows.length === 0 ? <p className="clash bad">There are no beds on this course's site.</p> : (
          <>
            <div className="av-cands-head">
              <span className={bedIds.length >= need ? "ok" : "short"}>{bedIds.length} of {need} chosen</span>
              {byHand && <button type="button" className="link" onClick={() => setTicked(null)}>Back to the suggestion</button>}
            </div>
            <div className="av-cands">
              {rooms.map((r) => (
                <div key={r.id} className="room">
                  <div className="room-head">
                    <span className="name">{r.name}</span>
                    <span className="where">{r.where}</span>
                    {r.beds.some((b) => b.course_in_room) && <span className="tag">{c.code} is here</span>}
                  </div>
                  {r.beds.map((b) => (
                    <label key={b.bed_id} className={`cand${b.free ? "" : " clash"}`}>
                      <input type="checkbox" checked={chosen.has(b.bed_id)} disabled={b.blocks || allocate.isPending}
                             onChange={() => toggle(b.bed_id)} />
                      <span className="name">{b.bed_name}</span>
                      {b.suggested && <span className="tag">suggested</span>}
                      {b.warnings.length > 0 && (
                        <span className="warn"><WarnIcon /> {b.warnings.join("; ")}{b.blocks ? " · not allowed" : ""}</span>
                      )}
                    </label>
                  ))}
                </div>
              ))}
            </div>
          </>
        ))}
      {allocate.error && <p className="clash bad">Not saved: {allocate.error.message}</p>}
    </Dialog>
  );
}

// ------------------ External bookings and outages (D38) ------------------

// What a save wrote, and the warnings the database returned with it.
function SavedResult({ kind, title, saved, warnings, onClose }: {
  kind: string; title: string; saved: string; warnings: string[]; onClose: () => void;
}) {
  return (
    <Dialog kind={kind} title={title} onClose={onClose}>
      <p className="clash ok">Saved: {saved}.</p>
      {warnings.length > 0 && (
        <div className="clash bad">
          <strong>Saved with {warnings.length} {warnings.length === 1 ? "warning" : "warnings"}</strong>
          <ul className="av-list">{warnings.map((w, i) => <li key={i}><WarnIcon /> {w}</li>)}</ul>
        </div>
      )}
    </Dialog>
  );
}

// What to do with a grid selection: book a course, book it externally or put it
// out of action. Each is its own popup; switching keeps the beds and dates.
function SelectionModes({ current, bedKeys, from, to, onOpen }: {
  current: "new" | "newExternal" | "newOutage"; bedKeys: string[]; from: string; to: string; onOpen: (p: Popup) => void;
}) {
  const modes: [typeof current, string, Popup][] = [
    ["new", "Course booking", { kind: "new", bedKeys, from, to }],
    ["newExternal", "External booking", { kind: "newExternal", bedKeys, from, to }],
    ["newOutage", "Outage", { kind: "newOutage", bedKeys, from, to }],
  ];
  return (
    <div className="av-modes" role="group" aria-label="What to add">
      {modes.map(([kind, label, p]) => (
        <button key={kind} type="button" aria-pressed={kind === current}
                onClick={() => { if (kind !== current) onOpen(p); }}>{label}</button>
      ))}
    </div>
  );
}

// Defaults for a new booking or outage: next week's block, Monday to Sunday (D9).
const nextMonday = () => addDaysIso(iso(mondayOf(new Date())), 7);

// What fn_check_allocation found on one bed, in a few words.
const clashText = (c: Clash) =>
  (c.kind === "BOOKING" ? `booked: ${c.ref}` : `out of action: ${c.ref}`) +
  ` ${ddmm(c.start_date)}–${ddmm(c.end_date)}` + (c.blocks ? " · not allowed" : "");

// Book beds for someone outside the courses (fn_book_external): a reference, a
// name and the dates. From the New menu the beds are ticked on one site, each
// with what it clashes with; from a grid selection the beds are the ones
// selected, listed with their clashes like the course booking, with a switch
// back to it.
function NewExternalPopup({ bedKeys, from, to, data, onOpen, onClose }: {
  bedKeys?: string[]; from?: string; to?: string; data: PopupData; onOpen: (p: Popup) => void; onClose: () => void;
}) {
  const sites = sitesOf(data.nodes).sort((a, b) => a.sortOrder - b.sortOrder);
  const given = (bedKeys ?? []).map((k) => data.nodes.get(k)).filter((n): n is LocationNode => n !== undefined);
  const fixed = given.length > 0; // beds come from a grid selection
  const [ref, setRef] = useState("");
  const [name, setName] = useState("");
  const [first, setFirst] = useState(from ?? nextMonday());
  const [departure, setDeparture] = useState(to ?? addDaysIso(nextMonday(), 6));
  const [siteId, setSiteId] = useState<number | null>(
    () => (given[0] ? ancestorAt(data.nodes, given[0].key, "Site")?.id : undefined) ?? sites[0]?.id ?? null);
  const [chosen, setChosen] = useState<Set<number>>(() => new Set(given.map((b) => b.id)));
  const valid = first !== "" && departure !== "" && departure > first;

  const site = sites.find((s) => s.id === siteId);
  const beds = fixed ? given : site ? bedsUnder(site) : [];
  const clashes = useClashes(data.tenant, beds.map((b) => b.id), first, departure, valid);
  const clashesOn = new Map<number, Clash[]>();
  for (const c of clashes.data ?? []) if (c.bed_id !== null) clashesOn.set(c.bed_id, [...(clashesOn.get(c.bed_id) ?? []), c]);

  // Rooms in estate order, each with its beds.
  const rooms: { key: string; name: string; where: string; beds: LocationNode[] }[] = [];
  for (const b of beds) {
    const last = rooms[rooms.length - 1];
    if (last && last.key === b.parentKey) { last.beds.push(b); continue; }
    const room = b.parentKey ? data.nodes.get(b.parentKey) : undefined;
    const block = ancestorAt(data.nodes, b.key, "Block");
    const floor = ancestorAt(data.nodes, b.key, "Floor");
    rooms.push({ key: b.parentKey ?? b.key, name: room?.name ?? "", where: [block?.name, floor?.name].filter(Boolean).join(" › "), beds: [b] });
  }

  const toggle = (id: number) => {
    const next = new Set(chosen);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setChosen(next);
  };
  const bedIds = fixed ? given.map((b) => b.id) : beds.filter((b) => chosen.has(b.id)).map((b) => b.id); // this site, estate order
  const blocked = bedIds.some((id) => (clashesOn.get(id) ?? []).some((c) => c.blocks));
  const book = useBookExternal(data.tenant);
  const canBook = valid && ref.trim() !== "" && name.trim() !== "" && bedIds.length > 0 &&
    !clashes.isPending && !clashes.error && !blocked && !book.isPending;

  if (book.data) {
    return <SavedResult kind="External booking" title={`${ref.trim()}: ${book.data.length} ${book.data.length === 1 ? "bed" : "beds"}`}
                        saved={`${name.trim()}, ${stay(first, departure)}`} warnings={book.data.flatMap((a) => a.warnings)} onClose={onClose} />;
  }

  const bookButton = (
    <button type="button" className="btn primary" disabled={!canBook}
            onClick={() => book.mutate({ ref: ref.trim(), name: name.trim(), bedIds, from: first, to: departure })}>
      {book.isPending ? "Booking…" : `Book ${bedIds.length} ${bedIds.length === 1 ? "bed" : "beds"}`}
    </button>
  );
  const fields = (
    <>
      <div className="av-form">
        <label className="av-field">Reference<input type="text" maxLength={50} value={ref} placeholder="e.g. BK-4600"
                                                     disabled={book.isPending} onChange={(e) => setRef(e.target.value)} /></label>
        <label className="av-field">For<input type="text" maxLength={200} value={name} placeholder="e.g. Visiting assessors"
                                               disabled={book.isPending} onChange={(e) => setName(e.target.value)} /></label>
        <label className="av-field">First night<input type="date" value={first} disabled={book.isPending} onChange={(e) => setFirst(e.target.value)} /></label>
        <label className="av-field">Departure<input type="date" value={departure} disabled={book.isPending} onChange={(e) => setDeparture(e.target.value)} /></label>
      </div>
      {valid ? <p className="summary">{stay(first, departure)}</p> : <p className="clash bad">Departure must be after the first night.</p>}
    </>
  );

  // From a grid selection: the selected beds, their clashes, and the details.
  if (fixed) {
    const list = clashes.data ?? [];
    const byId = new Map(given.map((b) => [b.id, b]));
    return (
      <Dialog kind="New allocation" title={`${given.length} ${given.length === 1 ? "bed" : "beds"}`} onClose={onClose} actions={bookButton}>
        <SelectionModes current="newExternal" bedKeys={given.map((b) => b.key)} from={first} to={departure} onOpen={onOpen} />
        <Facts rows={[["Beds", given.map((b) => bedName(data.nodes, b)).join(", ")]]} />
        {fields}
        {valid && (clashes.isPending ? <p className="summary">Checking for clashes…</p> :
          clashes.error ? <p className="clash bad">Could not check clashes: {clashes.error.message}</p> :
          list.length === 0 ? <p className="clash ok">No clashes on these beds for these nights.</p> : (
            <div className="clash bad">
              <strong>{blocked ? "Not allowed: " : ""}{list.length} {list.length === 1 ? "clash" : "clashes"}</strong>{" "}
              {blocked ? "(a clash rule is set to block)" : "(allowed with a warning)"}
              <ul className="av-list">
                {list.map((c, i) => {
                  const bed = c.bed_id !== null ? byId.get(c.bed_id) : undefined;
                  return <li key={i}>{bed ? bedName(data.nodes, bed) : `Bed ${c.bed_id}`}: {clashText(c)}</li>;
                })}
              </ul>
            </div>
          ))}
        {book.error && <p className="clash bad">Not saved: {book.error.message}</p>}
      </Dialog>
    );
  }

  return (
    <Dialog kind="New external booking" title="Book beds for someone outside the courses" onClose={onClose} wide actions={bookButton}>
      {fields}

      {sites.length > 1 && (
        <label className="av-field">Site
          <select value={siteId ?? ""} onChange={(e) => setSiteId(Number(e.target.value))}>
            {sites.map((s) => <option key={s.key} value={s.id}>{s.name}</option>)}
          </select>
        </label>
      )}
      {valid && (clashes.isPending ? <p className="summary">Checking the beds…</p> :
        clashes.error ? <p className="clash bad">Could not check the beds: {clashes.error.message}</p> :
        beds.length === 0 ? <p className="clash bad">There are no beds on this site.</p> : (
          <>
            <div className="av-cands-head">
              <span className={bedIds.length > 0 ? "ok" : "short"}>{bedIds.length} {bedIds.length === 1 ? "bed" : "beds"} ticked</span>
              {blocked && <span className="short">A ticked bed is not allowed (a clash rule is set to block)</span>}
            </div>
            <div className="av-cands">
              {rooms.map((r) => (
                <div key={r.key} className="room">
                  <div className="room-head"><span className="name">{r.name}</span><span className="where">{r.where}</span></div>
                  {r.beds.map((b) => {
                    const list = clashesOn.get(b.id) ?? [];
                    const blocks = list.some((c) => c.blocks);
                    return (
                      <label key={b.id} className={`cand${list.length > 0 ? " clash" : ""}`}>
                        <input type="checkbox" checked={chosen.has(b.id)} disabled={(blocks && !chosen.has(b.id)) || book.isPending}
                               onChange={() => toggle(b.id)} />
                        <span className="name">{b.name}</span>
                        {list.length > 0 && <span className="warn"><WarnIcon /> {list.map(clashText).join("; ")}</span>}
                      </label>
                    );
                  })}
                </div>
              ))}
            </div>
            <p className="summary">Beds with a clash can be booked with a warning, unless the clash rule is set to block.</p>
          </>
        ))}
      {book.error && <p className="clash bad">Not saved: {book.error.message}</p>}
    </Dialog>
  );
}

// Put a site, building, block, floor, room or bed out of action
// (fn_add_outage). Shows the beds it covers and the bookings it would land on;
// saving is allowed, with those bookings as warnings (D38).
function NewOutagePopup({ nodeKey, bedKeys, from, to, data, onOpen, onClose }: {
  nodeKey?: string; bedKeys?: string[]; from?: string; to?: string; data: PopupData;
  onOpen: (p: Popup) => void; onClose: () => void;
}) {
  // Every location, in tree order, indented by depth.
  const options: { node: LocationNode; depth: number }[] = [];
  const walk = (list: LocationNode[], depth: number) => {
    for (const n of [...list].sort((a, b) => a.sortOrder - b.sortOrder)) {
      options.push({ node: n, depth });
      walk(n.children, depth + 1);
    }
  };
  walk([...data.nodes.values()].filter((n) => n.parentKey === null), 0);

  // From a grid selection: an outage is set on one place, so offer the places
  // that hold every selected bed, smallest first (the bed, its room, floor,
  // block, building, site). Default: the smallest that holds exactly those beds.
  const given = (bedKeys ?? []).map((k) => data.nodes.get(k)).filter((n): n is LocationNode => n !== undefined);
  const fixed = given.length > 0;
  const holders: LocationNode[] = [];
  if (fixed) {
    const ids = new Set(given.map((b) => b.id));
    for (let n: LocationNode | undefined = given[0]; n; n = n.parentKey ? data.nodes.get(n.parentKey) : undefined) {
      const under = new Set(bedsUnder(n).map((b) => b.id));
      if ([...ids].every((id) => under.has(id))) holders.push(n);
    }
  }
  const exact = holders.find((n) => bedsUnder(n).length === given.length);

  const [key, setKey] = useState(nodeKey ?? (exact ?? holders[0])?.key ?? "");
  const [first, setFirst] = useState(from ?? nextMonday());
  const [back, setBack] = useState(to ?? addDaysIso(nextMonday(), 7));
  const [reason, setReason] = useState("");
  const valid = first !== "" && back !== "" && back > first;

  const node = data.nodes.get(key);
  const beds = node ? bedsUnder(node) : [];
  const clashes = useClashes(data.tenant, beds.map((b) => b.id), first, back, valid && beds.length > 0);
  const bookings = (clashes.data ?? []).filter((c) => c.kind === "BOOKING");
  const already = (clashes.data ?? []).filter((c) => c.kind === "OUT_OF_ACTION");
  const byId = new Map(beds.map((b) => [b.id, b]));
  const add = useAddOutage(data.tenant);
  const canSave = valid && node !== undefined && reason.trim() !== "" && !add.isPending;

  if (add.data && node) {
    return <SavedResult kind="Outage added" title={`${node.name}: out of action`}
                        saved={`${dayLong(first)} until ${dayLong(back)}, ${reason.trim()}`} warnings={add.data.warnings} onClose={onClose} />;
  }

  const levelName = (n: LocationNode) => (n.level === "Bed" ? bedName(data.nodes, n) : n.name) +
    (n.level === "Site" || n.level === "Building" ? ` (${n.level.toLowerCase()})` : "");

  return (
    <Dialog kind="New outage" title={fixed ? `${given.length} ${given.length === 1 ? "bed" : "beds"}` : "Put a location out of action"}
            onClose={onClose} wide={!fixed}
            actions={
              <button type="button" className="btn primary" disabled={!canSave}
                      onClick={() => node && add.mutate({ level: node.level, locationId: node.id, from: first, to: back, reason: reason.trim() })}>
                {add.isPending ? "Saving…" : "Add outage"}
              </button>
            }>
      {fixed && (
        <>
          <SelectionModes current="newOutage" bedKeys={given.map((b) => b.key)} from={first} to={back} onOpen={onOpen} />
          <Facts rows={[["Beds", given.map((b) => bedName(data.nodes, b)).join(", ")]]} />
          <label className="av-field">Out of action
            <select value={key} disabled={add.isPending} onChange={(e) => setKey(e.target.value)}>
              {holders.map((n) => {
                const count = bedsUnder(n).length;
                return (
                  <option key={n.key} value={n.key}>
                    {levelName(n)} · {count} {count === 1 ? "bed" : "beds"}{count > given.length ? ` (${count - given.length} more than selected)` : ""}
                  </option>
                );
              })}
            </select>
          </label>
        </>
      )}
      {!fixed && <label className="av-field">Location
        <select value={key} disabled={add.isPending} onChange={(e) => setKey(e.target.value)}>
          <option value="">Choose a site, building, block, floor, room or bed</option>
          {options.map(({ node: n, depth }) => (
            <option key={n.key} value={n.key}>
              {"   ".repeat(depth)}{n.name}{n.level === "Site" || n.level === "Building" ? ` (${n.level.toLowerCase()})` : ""}
            </option>
          ))}
        </select>
      </label>}
      <div className="av-form">
        <label className="av-field">Out of action from<input type="date" value={first} disabled={add.isPending} onChange={(e) => setFirst(e.target.value)} /></label>
        <label className="av-field">Back in service on<input type="date" value={back} disabled={add.isPending} onChange={(e) => setBack(e.target.value)} /></label>
      </div>
      <label className="av-field">Reason<input type="text" maxLength={1000} value={reason} placeholder="e.g. Heating failure"
                                                disabled={add.isPending} onChange={(e) => setReason(e.target.value)} /></label>
      {!valid && <p className="clash bad">"Back in service" must be after the first day out of action.</p>}

      {node && valid && (
        <>
          <p className="summary">
            {pathOf(data.nodes, node.key)}: {beds.length} {beds.length === 1 ? "bed" : "beds"}, out of action
            for {dayIndex(first, back)} {dayIndex(first, back) === 1 ? "night" : "nights"}.
          </p>
          {clashes.isPending ? <p className="summary">Checking bookings…</p> :
            clashes.error ? <p className="clash bad">Could not check bookings: {clashes.error.message}</p> :
            bookings.length === 0 ? <p className="clash ok">No bookings on these beds then.</p> : (
              <div className="clash bad">
                <strong>{bookings.length} {bookings.length === 1 ? "booking" : "bookings"} would be in an out-of-action bed</strong>{" "}
                (allowed; they will show as warnings)
                <ul className="av-list">
                  {bookings.map((c, i) => {
                    const bed = c.bed_id !== null ? byId.get(c.bed_id) : undefined;
                    return <li key={i}>{bed ? bedName(data.nodes, bed) : `Bed ${c.bed_id}`}: {c.ref} · {ddmm(c.start_date)}–{ddmm(c.end_date)}</li>;
                  })}
                </ul>
              </div>
            )}
          {already.length > 0 && (
            <p className="summary">
              Already out of action then: {[...new Set(already.map((c) => `${c.ref} (${ddmm(c.start_date)}–${ddmm(c.end_date)})`))].join("; ")}.
            </p>
          )}
        </>
      )}
      {add.error && <p className="clash bad">Not saved: {add.error.message}</p>}
    </Dialog>
  );
}

// A booking dragged on the grid: confirm where it goes. The dates can still be
// adjusted; the clash check leaves the booking itself out (0018), and the
// database checks again when it saves (fn_move_allocation).
function MovePopup({ bar, bedKey, from, to, data, onClose }: {
  bar: BedBar; bedKey: string; from: string; to: string; data: PopupData; onClose: () => void;
}) {
  const target = data.nodes.get(bedKey);
  const current = data.nodes.get(`bed:${bar.bed_id}`);
  const [first, setFirst] = useState(from);
  const [departure, setDeparture] = useState(to);
  const valid = first !== "" && departure !== "" && departure > first;
  const ref = (bar.kind === "external" ? bar.external_ref : bar.course_code) ?? "Booking";
  const unchanged = target?.id === bar.bed_id && first === bar.start_date && departure === bar.end_date;

  const clashes = useClashes(data.tenant, target ? [target.id] : [], first, departure, valid && target !== undefined,
                             bar.course_id, bar.id);
  const outside = (clashes.data ?? []).find((c) => c.kind === "COURSE_DATES");
  const list = (clashes.data ?? []).filter((c) => c.kind !== "COURSE_DATES");
  const blocked = list.some((c) => c.blocks);
  const move = useMoveAllocation(data.tenant);
  const canMove = valid && target !== undefined && !unchanged && !clashes.isPending && !clashes.error && !blocked && !move.isPending;

  if (move.data && target) {
    return <SavedResult kind="Moved" title={`${ref}: moved`} saved={`${bedName(data.nodes, target)}, ${stay(first, departure)}`}
                        warnings={move.data.warnings} onClose={onClose} />;
  }

  return (
    <Dialog kind="Move booking" title={bar.kind === "external" ? `${ref} · ${bar.external_name ?? ""}` : ref} onClose={onClose}
            actions={
              <button type="button" className="btn primary" disabled={!canMove}
                      onClick={() => target && move.mutate({ id: bar.id, bedId: target.id, from: first, to: departure })}>
                {move.isPending ? "Moving…" : "Move"}
              </button>
            }>
      <Facts rows={[
        ["From", `${current ? bedName(data.nodes, current) : `Bed ${bar.bed_id}`}, ${stay(bar.start_date, bar.end_date)}`],
        ["To", target ? bedName(data.nodes, target) : "Unknown bed"],
      ]} />
      <div className="dates">
        <label>First night<input type="date" value={first} disabled={move.isPending} onChange={(e) => setFirst(e.target.value)} /></label>
        <label>Departure<input type="date" value={departure} disabled={move.isPending} onChange={(e) => setDeparture(e.target.value)} /></label>
      </div>
      {!valid ? <p className="clash bad">Departure must be after the first night.</p> :
        unchanged ? <p className="summary">That's where it is now.</p> : <p className="summary">{stay(first, departure)}</p>}
      {valid && (first !== bar.start_date || departure !== bar.end_date) && (
        <p className="clash bad" role="alert">
          <WarnIcon /> <strong>The dates change</strong>: was {stay(bar.start_date, bar.end_date)}, now {stay(first, departure)}.
        </p>
      )}
      {valid && !unchanged && (clashes.isPending ? <p className="summary">Checking for clashes…</p> :
        clashes.error ? <p className="clash bad">Could not check clashes: {clashes.error.message}</p> :
        list.length === 0 ? <p className="clash ok">No clashes there for these nights.</p> : (
          <div className="clash bad">
            <strong>{blocked ? "Not allowed: " : ""}{list.length} {list.length === 1 ? "clash" : "clashes"}</strong>{" "}
            {blocked ? "(a clash rule is set to block)" : "(allowed with a warning)"}
            <ul className="av-list">{list.map((c, i) => <li key={i}>{clashText(c)}</li>)}</ul>
          </div>
        ))}
      {valid && !unchanged && outside && (
        <p className="clash bad">
          <WarnIcon /> These nights go outside {outside.ref}'s dates ({ddmm(outside.start_date)}–{ddmm(outside.end_date)}). Allowed with a warning.
        </p>
      )}
      {move.error && <p className="clash bad">Not moved: {move.error.message}</p>}
    </Dialog>
  );
}

// "Room 101 Bed A"
function bedName(nodes: Map<string, LocationNode>, n: LocationNode) {
  const room = n.parentKey ? nodes.get(n.parentKey) : undefined;
  return room ? `${room.name} ${n.name}` : n.name;
}
