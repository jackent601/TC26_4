// Popups (phase 2 step 4, writes from phase 3). What's shown comes from data the
// page already has, except clashes (fn_check_allocation). Course allocations
// can be booked, moved, cancelled and have their status set (0009); other edit
// forms come later.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { format, parseISO } from "date-fns";
import { useClashes } from "./data";
import { dayIndex, dayLong, ddmm } from "./dates";
import { basisOf, courseColour, OverIcon, STATE_NAMES, STATE_ORDER, WarnIcon } from "./look";
import type { ViewSettings } from "./settings";
import { weekCounts } from "./TimelineGrid";
import type { BedBar, CourseFigure, Level, LocationNode, Popup, Warning, WeekSummary } from "./types";
import { STATUSES, useAllocateCourse, useCancelAllocation, useMoveAllocation, useSetStatus } from "./writes";

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
    case "course": return <CoursePopup courseId={popup.courseId} data={data} onClose={onClose} />;
    case "warning": return <WarningPopup warning={popup.warning} data={data} onOpen={onOpen} onNotice={onNotice} onClose={onClose} />;
    case "new": return <NewAllocationPopup bedKeys={popup.bedKeys} from={popup.from} to={popup.to} data={data} onClose={onClose} />;
  }
}

// ------------------------------- Pieces --------------------------------

// A modal dialog (native <dialog>: focus stays inside, Esc closes, focus returns).
function Dialog(p: { kind: string; title: string; onClose: () => void; children: ReactNode; actions?: ReactNode }) {
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
    <dialog ref={ref} className="av-dialog" aria-labelledby="av-dialog-title"
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

function CoursePopup({ courseId, data, onClose }: { courseId: number; data: PopupData; onClose: () => void }) {
  const c = data.figures.get(courseId);
  if (!c) return null;
  const warnings = data.warnings.filter((w) => w.courseId === courseId && w.allocationId === null);
  return (
    <Dialog kind="Course" title={`${c.code}: ${c.name}`} onClose={onClose}>
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
      <Later what="Editing the course (dates, figures, attributes)" />
    </Dialog>
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
// booking first (D32); one-off bookings come later. The database decides what
// is allowed: a clash whose rule is BLOCK says "Not allowed" (D30).
function NewAllocationPopup({ bedKeys, from, to, data, onClose }: {
  bedKeys: string[]; from: string; to: string; data: PopupData; onClose: () => void;
}) {
  const [first, setFirst] = useState(from);
  const [departure, setDeparture] = useState(to);
  const valid = first !== "" && departure !== "" && departure > first;

  const beds = bedKeys.map((k) => data.nodes.get(k)).filter((n): n is LocationNode => n !== undefined);
  const byId = new Map(beds.map((b) => [b.id, b]));
  const clashes = useClashes(data.tenant, beds.map((b) => b.id), first, departure, valid);
  const list = clashes.data ?? [];
  const blocked = list.some((c) => c.blocks);

  // Courses to choose from: not cancelled; those running on these nights first.
  const courses = [...data.figures.values()]
    .filter((c) => c.status !== "CANCELLED")
    .map((c) => ({ c, overlaps: c.startDate < departure && first < c.endDate }))
    .sort((a, b) => Number(b.overlaps) - Number(a.overlaps) || a.c.startDate.localeCompare(b.c.startDate));
  const [courseId, setCourseId] = useState<number | null>(() => courses.find((x) => x.overlaps)?.c.courseId ?? null);
  const course = courseId !== null ? data.figures.get(courseId) : undefined;

  const allocate = useAllocateCourse(data.tenant);
  const canAllocate = valid && course !== undefined && !clashes.isPending && !clashes.error && !blocked && !allocate.isPending;

  // After saving: what was written and the warnings the database returned.
  if (allocate.data) {
    const warnings = allocate.data.flatMap((a) => a.warnings);
    return (
      <Dialog kind="Allocated" title={`${course?.code ?? "Course"}: ${allocate.data.length} ${allocate.data.length === 1 ? "bed" : "beds"}`} onClose={onClose}>
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

  return (
    <Dialog kind="New allocation" title={`${beds.length} ${beds.length === 1 ? "bed" : "beds"}`} onClose={onClose}
            actions={
              <button type="button" className="btn primary" disabled={!canAllocate}
                      onClick={() => course && allocate.mutate({ courseId: course.courseId, bedIds: beds.map((b) => b.id), from: first, to: departure })}>
                {allocate.isPending ? "Allocating…" : "Allocate"}
              </button>
            }>
      <div className="av-modes" role="group" aria-label="Kind of booking">
        <button type="button" aria-pressed="true">Course booking</button>
        <button type="button" aria-pressed="false" disabled title="Comes later (D32)">One-off booking</button>
      </div>

      <Facts rows={[["Beds", beds.map((b) => bedName(data.nodes, b)).join(", ")]]} />

      <label className="av-field">
        Course
        <select value={courseId ?? ""} onChange={(e) => setCourseId(e.target.value ? Number(e.target.value) : null)}>
          <option value="">Choose a course…</option>
          {courses.map(({ c, overlaps }) => (
            <option key={c.courseId} value={c.courseId}>
              {c.code}: {c.name} ({ddmm(c.startDate)}–{ddmm(c.endDate)}){overlaps ? "" : " · not on these nights"}
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
                const bed = byId.get(c.bed_id);
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
      {allocate.error && <p className="clash bad">Not saved: {allocate.error.message}</p>}
    </Dialog>
  );
}

// "Room 101 Bed A"
function bedName(nodes: Map<string, LocationNode>, n: LocationNode) {
  const room = n.parentKey ? nodes.get(n.parentKey) : undefined;
  return room ? `${room.name} ${n.name}` : n.name;
}
