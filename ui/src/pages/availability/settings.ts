// Per-user view settings (D28): kept in this browser only, never in the database.
// Collapsed tree nodes are kept per tenant, since location keys differ by tenant.
import { useCallback, useState } from "react";
import type { Basis } from "./types";

export interface ViewSettings {
  weeks: number;
  minDayWidth: number; // days widen to fill the window; never narrower than this
  basis: Basis;
  greenAt: number;
  redBelow: number;
}

export const LIMITS = {
  weeks: { min: 1, max: 26 }, // the database allows up to 52 (fn_week_summary)
  minDayWidth: { min: 10, max: 36 },
  greenAt: { min: 50, max: 150 },
  redBelow: { min: 0, max: 100 },
} as const;

const DEFAULTS: ViewSettings = { weeks: 6, minDayWidth: 16, basis: "scheduled", greenAt: 100, redBelow: 80 };
const SETTINGS_KEY = "accomm.availability.settings";
const collapsedKey = (tenant: string) => `accomm.availability.collapsed.${tenant}`;

function load<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
}

function save(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage blocked: settings last until the page is closed.
  }
}

const clamp = (n: number, { min, max }: { min: number; max: number }) => Math.min(max, Math.max(min, Math.round(n)));

// Keep stored values valid, whatever an older version or a hand edit left there.
function tidy(s: Partial<ViewSettings>): ViewSettings {
  const v = { ...DEFAULTS, ...s };
  const greenAt = clamp(Number(v.greenAt) || DEFAULTS.greenAt, LIMITS.greenAt);
  return {
    weeks: clamp(Number(v.weeks) || DEFAULTS.weeks, LIMITS.weeks),
    minDayWidth: clamp(Number(v.minDayWidth) || DEFAULTS.minDayWidth, LIMITS.minDayWidth),
    basis: v.basis === "loaded" ? "loaded" : "scheduled",
    greenAt,
    // The database refuses red above green; keep them ordered here.
    redBelow: Math.min(clamp(Number(v.redBelow) || 0, LIMITS.redBelow), greenAt),
  };
}

export function useViewSettings() {
  const [settings, setSettings] = useState<ViewSettings>(() => tidy(load<Partial<ViewSettings>>(SETTINGS_KEY) ?? {}));
  const update = useCallback((change: Partial<ViewSettings>) => {
    setSettings((prev) => {
      const next = tidy({ ...prev, ...change });
      save(SETTINGS_KEY, next);
      return next;
    });
  }, []);
  return [settings, update] as const;
}

export function useCollapsed(tenant: string | null) {
  const [state, setState] = useState<{ tenant: string | null; keys: Set<string> }>(() => ({
    tenant,
    keys: new Set(tenant ? load<string[]>(collapsedKey(tenant)) ?? [] : []),
  }));
  // Switching tenant loads that tenant's collapsed nodes.
  let keys = state.keys;
  if (state.tenant !== tenant) {
    keys = new Set(tenant ? load<string[]>(collapsedKey(tenant)) ?? [] : []);
    setState({ tenant, keys });
  }

  const set = useCallback(
    (next: Set<string>) => {
      setState({ tenant, keys: next });
      if (tenant) save(collapsedKey(tenant), [...next]);
    },
    [tenant],
  );
  return [keys, set] as const;
}

// Which blocks are shown (location keys as in api.locations, e.g. "block:2"):
// null means all, so new blocks appear without anyone ticking them. Per
// tenant, like collapsed rows.
export interface LocationFilter {
  blocks: string[] | null;
}
export const NO_FILTER: LocationFilter = { blocks: null };
const filterKey = (tenant: string) => `accomm.availability.filter.${tenant}.v2`;

export function useLocationFilter(tenant: string | null) {
  const read = (t: string | null): LocationFilter => {
    const v = t ? load<LocationFilter>(filterKey(t)) : null;
    return { blocks: Array.isArray(v?.blocks) ? v.blocks.filter((k): k is string => typeof k === "string") : null };
  };
  const [state, setState] = useState<{ tenant: string | null; filter: LocationFilter }>(() => ({ tenant, filter: read(tenant) }));
  // Switching tenant loads that tenant's filter.
  let filter = state.filter;
  if (state.tenant !== tenant) {
    filter = read(tenant);
    setState({ tenant, filter });
  }

  const set = useCallback(
    (next: LocationFilter) => {
      setState({ tenant, filter: next });
      if (tenant) save(filterKey(tenant), next);
    },
    [tenant],
  );
  return [filter, set] as const;
}
