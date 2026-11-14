// The selected tenant (D24). The list comes from api.tenants; the choice is a
// per-browser convenience kept in local storage. Every API call sends it as X-Tenant.
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./api/client";

type Tenant = Schemas["tenants"];

interface TenantState {
  tenants: Tenant[];
  code: string | null;
  isDemo: boolean;
  setCode: (code: string) => void;
  error: Error | null;
}

const TenantContext = createContext<TenantState | null>(null);
const STORAGE_KEY = "accomm.tenant";

function readStored(): string | null {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

function writeStored(code: string) {
  try {
    localStorage.setItem(STORAGE_KEY, code);
  } catch {
    // Storage blocked: the choice just isn't remembered.
  }
}

export function TenantProvider({ children }: { children: ReactNode }) {
  const tenantsQuery = useQuery({
    queryKey: ["tenants"],
    queryFn: () => unwrap(api.GET("/tenants", { params: { query: { order: "code.desc" } } })),
  });
  const tenants = tenantsQuery.data ?? [];
  const [code, setCodeState] = useState<string | null>(readStored);

  // Once the list arrives, keep a valid choice: the stored one, else the first
  // non-demo tenant (so nobody lands on sample data by accident).
  useEffect(() => {
    if (tenants.length === 0) return;
    if (code && tenants.some((t) => t.code === code)) return;
    const fallback = tenants.find((t) => t.is_demo !== "Y") ?? tenants[0];
    setCodeState(fallback.code ?? null);
  }, [tenants, code]);

  const setCode = (next: string) => {
    setCodeState(next);
    writeStored(next);
  };

  const current = tenants.find((t) => t.code === code);
  const value: TenantState = {
    tenants,
    code: current ? code : null,
    isDemo: current?.is_demo === "Y",
    setCode,
    error: tenantsQuery.error,
  };
  return <TenantContext.Provider value={value}>{children}</TenantContext.Provider>;
}

export function useTenant(): TenantState {
  const state = useContext(TenantContext);
  if (!state) throw new Error("useTenant must be used inside TenantProvider");
  return state;
}
