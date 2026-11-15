// Data for the availability page, all from the API (migration 0006). Every
// query is keyed by tenant, so switching tenant never shows another's data.
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { api, tenantHeaders, unwrap } from "../../api/client";
import { addDaysIso } from "./dates";
import type {
  AuditRequest, AuditRow, BedBar, CandidateBed, Clash, CourseFigure, Level, LocationNode, Warning, WeekSummary, WeekSummaryRow,
} from "./types";

// History of one booking, or of a course and its bookings (api.audit, D37),
// latest first. The sentences come from the database; the UI only lists them.
export function useAudit(tenant: string | null, filter: { courseId?: number; allocationId?: number }, limit = 30) {
  const { courseId, allocationId } = filter;
  return useQuery({
    queryKey: ["audit", tenant, courseId ?? null, allocationId ?? null, limit],
    enabled: tenant !== null && (courseId !== undefined || allocationId !== undefined),
    queryFn: () =>
      unwrap(
        api.GET("/audit", {
          params: {
            query: {
              ...(allocationId !== undefined ? { allocation_id: `eq.${allocationId}` } : { course_id: `eq.${courseId}` }),
              order: "changed_at.desc,audit_id.desc",
              limit: String(limit),
            },
          },
          headers: tenantHeaders(tenant!),
        }),
      ),
    select: (rows): AuditRow[] =>
      rows.map((r) => ({
        auditId: r.audit_id ?? 0,
        requestId: r.request_id ?? null,
        changedAt: r.changed_at ?? "",
        changedBy: r.changed_by ?? "",
        tableName: r.table_name ?? "",
        recordId: r.record_id ?? 0,
        courseId: r.course_id ?? null,
        courseCode: r.course_code ?? "",
        allocationId: r.allocation_id ?? null,
        bedId: r.bed_id ?? null,
        siteId: r.site_id ?? null,
        action: r.action ?? "",
        summary: r.summary ?? "",
        warnings: r.warnings ?? [],
      })),
  });
}

// The latest changes, one line per request (api.audit_requests), for the
// chosen sites: the Overview's History tab.
export function useAuditRequests(tenant: string | null, siteIds: number[] | null, limit = 100) {
  return useQuery({
    queryKey: ["audit_requests", tenant, siteIds, limit],
    enabled: tenant !== null,
    placeholderData: keepPreviousData,
    queryFn: () =>
      unwrap(
        api.GET("/audit_requests", {
          params: {
            query: {
              ...(siteIds ? { site_id: `in.(${siteIds.join(",")})` } : {}),
              order: "changed_at.desc",
              limit: String(limit),
            },
          },
          headers: tenantHeaders(tenant!),
        }),
      ),
    select: (rows): AuditRequest[] =>
      rows.map((r) => ({
        requestKey: r.request_key ?? "",
        changedAt: r.changed_at ?? "",
        changedBy: r.changed_by ?? "",
        changes: r.changes ?? 1,
        courseId: r.course_id ?? null,
        courseCode: r.course_code ?? null,
        siteId: r.site_id ?? null,
        summary: r.summary ?? "",
        hasWarnings: r.has_warnings ?? false,
      })),
  });
}

// Beds a course could be booked into for some nights, with the database's
// suggestion of `beds` of them (api.fn_candidate_beds, D35). No placeholder
// data: a stale list must not be booked.
export function useCandidateBeds(tenant: string | null, courseId: number, from: string, to: string, beds: number,
                                 enabled = true) {
  return useQuery({
    queryKey: ["candidate_beds", tenant, courseId, from, to, beds],
    enabled: enabled && tenant !== null,
    queryFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/fn_candidate_beds", {
          body: { p_course_id: courseId, p_from: from, p_to: to, p_beds: beds },
          headers: tenantHeaders(tenant!),
        }),
      );
      return rows as unknown as CandidateBed[];
    },
  });
}

// Bookings and outages on some beds over some nights (api.fn_check_allocation).
// Used by the outage popup to list the bookings an outage affects.
// Given a course, it also says whether the nights go outside the course's dates (0010).
export function useClashes(tenant: string | null, bedIds: number[], from: string, to: string, enabled = true,
                           courseId: number | null = null) {
  return useQuery({
    queryKey: ["clashes", tenant, bedIds, from, to, courseId],
    enabled: enabled && tenant !== null && bedIds.length > 0,
    queryFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/fn_check_allocation", {
          body: { p_bed_ids: bedIds, p_from: from, p_to: to, ...(courseId !== null ? { p_course_id: courseId } : {}) },
          headers: tenantHeaders(tenant!),
        }),
      );
      return rows as unknown as Clash[];
    },
  });
}

// Warnings strip: api.warnings that haven't ended before the first night shown
// (end dates are departure days, so end_date > start), earliest first. No upper
// limit, so problems beyond the weeks on screen still show. Independent of the
// colour basis (D14). The filter runs in the database (PostgREST query filter).
//
// Optionally also before `to` (start_date < to) and within some sites: the
// Overview uses both (0011 added site_id).
export function useWarnings(tenant: string | null, start: string, to: string | null = null, siteIds: number[] | null = null) {
  return useQuery({
    queryKey: ["warnings", tenant, start, to, siteIds],
    enabled: tenant !== null,
    placeholderData: keepPreviousData,
    queryFn: () =>
      unwrap(
        api.GET("/warnings", {
          params: {
            query: {
              end_date: `gt.${start}`,
              ...(to ? { start_date: `lt.${to}` } : {}),
              ...(siteIds ? { site_id: `in.(${siteIds.join(",")})` } : {}),
              order: "start_date,kind",
            },
          },
          headers: tenantHeaders(tenant!),
        }),
      ),
    select: (rows): Warning[] =>
      rows.map((r) => ({
        kind: r.kind ?? "",
        severity: r.severity ?? "WARNING",
        message: r.message ?? "",
        courseId: r.course_id ?? null,
        allocationId: r.allocation_id ?? null,
        bedId: r.bed_id ?? null,
        startDate: r.start_date ?? null,
        endDate: r.end_date ?? null,
        siteId: r.site_id ?? null,
      })),
  });
}

// Build the tree from api.locations' flat rows; siblings by sort_order, then name.
function buildTree(rows: Awaited<ReturnType<typeof fetchLocations>>): LocationNode[] {
  const nodes = new Map<string, LocationNode>();
  for (const r of rows) {
    if (!r.key) continue;
    nodes.set(r.key, {
      key: r.key,
      parentKey: r.parent_key ?? null,
      level: (r.level ?? "Bed") as Level,
      id: r.id ?? 0,
      name: r.name ?? "",
      sortOrder: r.sort_order ?? 0,
      bedCount: r.bed_count ?? 0,
      children: [],
    });
  }
  const roots: LocationNode[] = [];
  for (const n of nodes.values()) {
    const parent = n.parentKey ? nodes.get(n.parentKey) : undefined;
    (parent ? parent.children : roots).push(n);
  }
  const sort = (list: LocationNode[]) => {
    list.sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
    list.forEach((n) => sort(n.children));
  };
  sort(roots);
  return roots;
}

function fetchLocations(tenant: string) {
  return unwrap(api.GET("/locations", { headers: tenantHeaders(tenant) }));
}

export function useLocations(tenant: string | null) {
  return useQuery({
    queryKey: ["locations", tenant],
    enabled: tenant !== null,
    queryFn: () => fetchLocations(tenant!),
    select: buildTree,
  });
}

export function useCourseFigures(tenant: string | null) {
  return useQuery({
    queryKey: ["course_figures", tenant],
    enabled: tenant !== null,
    queryFn: () => unwrap(api.GET("/course_figures", { headers: tenantHeaders(tenant!) })),
    select: (rows) =>
      new Map<number, CourseFigure>(
        rows.map((r) => [
          r.course_id ?? 0,
          {
            courseId: r.course_id ?? 0,
            code: r.code ?? "",
            name: r.name ?? "",
            startDate: r.start_date ?? "",
            endDate: r.end_date ?? "",
            status: r.status ?? "",
            pctScheduled: r.pct_scheduled ?? null,
            pctLoaded: r.pct_loaded ?? null,
            siteId: r.site_id ?? null,
            scheduled: r.scheduled ?? 0,
            loaded: r.loaded ?? 0,
            loadedAt: r.loaded_at ?? null,
            allocated: r.allocated ?? 0,
            loadedAboveScheduled: r.loaded_above_scheduled ?? false,
          },
        ]),
      ),
  });
}

// Bars per bed for the nights shown, grouped by bed_id.
export function useBedBars(tenant: string | null, start: string, weeks: number) {
  const to = addDaysIso(start, weeks * 7);
  return useQuery({
    queryKey: ["bed_bars", tenant, start, to],
    enabled: tenant !== null,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/fn_bed_bars", { body: { p_from: start, p_to: to }, headers: tenantHeaders(tenant!) }),
      );
      return rows as unknown as BedBar[];
    },
    select: (rows) => {
      const byBed = new Map<number, BedBar[]>();
      for (const b of rows) {
        const list = byBed.get(b.bed_id);
        if (list) list.push(b);
        else byBed.set(b.bed_id, [b]);
      }
      return byBed;
    },
  });
}

// Collapsed-row facts, gathered per "<location key>|<week start>". No basis or
// thresholds: courses are banded in the UI (D29), so changing them needs no request.
export function useWeekSummary(tenant: string | null, start: string, weeks: number) {
  return useQuery({
    queryKey: ["week_summary", tenant, start, weeks],
    enabled: tenant !== null,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/fn_week_summary", {
          body: { p_from: start, p_weeks: weeks },
          headers: tenantHeaders(tenant!),
        }),
      );
      return rows as unknown as WeekSummaryRow[];
    },
    select: (rows) => {
      const byWeek = new Map<string, WeekSummary>();
      for (const r of rows) {
        const id = `${r.key}|${r.week_start}`;
        let w = byWeek.get(id);
        if (!w) {
          w = { busiestNight: r.busiest_night, free: 0, outOfAction: 0, external: 0, courses: [] };
          byWeek.set(id, w);
        }
        if (r.category === "free") w.free += r.beds;
        else if (r.category === "out_of_action") w.outOfAction += r.beds;
        else if (r.category === "external") w.external += r.beds;
        else if (r.course_id !== null) w.courses.push({ courseId: r.course_id, beds: r.beds });
      }
      return byWeek;
    },
  });
}
