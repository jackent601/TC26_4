// Data and view state for the Overview page (migration 0011).
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import { api, tenantHeaders, unwrap } from "../../api/client";

// api.fn_weekly_overview: one row per week (function results aren't in
// PostgREST's OpenAPI, so typed here to match db/api-contract.txt).
export interface WeekRow {
  week_start: string;
  busiest_night: string | null;
  beds_available: number;
  allocated: number;
  external: number;
  free: number;
  scheduled: number;
  loaded: number;
  courses: number;
}

export function useWeeklyOverview(tenant: string | null, start: string, weeks: number, siteIds: number[] | null) {
  return useQuery({
    queryKey: ["weekly_overview", tenant, start, weeks, siteIds],
    enabled: tenant !== null,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/fn_weekly_overview", {
          body: { p_from: start, p_weeks: weeks, ...(siteIds ? { p_site_ids: siteIds } : {}) },
          headers: tenantHeaders(tenant!),
        }),
      );
      return rows as unknown as WeekRow[];
    },
  });
}

// Which sites the Overview covers: null = all (so new sites appear). Per
// tenant, kept in this browser.
const sitesKey = (tenant: string) => `accomm.overview.sites.${tenant}`;
function readSites(tenant: string | null): number[] | null {
  if (!tenant) return null;
  try {
    const v = JSON.parse(localStorage.getItem(sitesKey(tenant)) ?? "null");
    return Array.isArray(v) ? v.filter((x): x is number => typeof x === "number") : null;
  } catch {
    return null;
  }
}

export function useSiteFilter(tenant: string | null) {
  const [state, setState] = useState(() => ({ tenant, sites: readSites(tenant) }));
  let sites = state.sites;
  if (state.tenant !== tenant) {
    sites = readSites(tenant);
    setState({ tenant, sites });
  }
  const set = useCallback(
    (next: number[] | null) => {
      setState({ tenant, sites: next });
      try {
        if (tenant) localStorage.setItem(sitesKey(tenant), JSON.stringify(next));
      } catch {
        // Storage blocked: lasts until the page is closed.
      }
    },
    [tenant],
  );
  return [sites, set] as const;
}
