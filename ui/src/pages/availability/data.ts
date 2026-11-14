// Data for the availability page, all from the API (migration 0006). Every
// query is keyed by tenant, so switching tenant never shows another's data.
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { api, tenantHeaders, unwrap } from "../../api/client";
import { addDaysIso } from "./dates";
import type { BedBar, CourseFigure, Level, LocationNode, WeekSummary, WeekSummaryRow } from "./types";

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
