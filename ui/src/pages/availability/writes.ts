// Writes for the availability page (migration 0009, D30-D32). The database
// checks the rules, writes the audit log and returns warnings; the UI only
// calls and shows the result. After any write, everything shown is refetched.
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, tenantHeaders, unwrap } from "../../api/client";

// Function results aren't in PostgREST's OpenAPI; shapes from db/api-contract.txt.
export interface Allocated {
  allocation_id: number;
  bed_id: number;
  warnings: string[];
}
export interface Moved extends Allocated {
  start_date: string;
  end_date: string;
}
export interface StatusSet {
  allocation_id: number;
  status: string;
  checked_in_at: string | null;
  checked_out_at: string | null;
}

export const STATUSES = ["ALLOCATED", "BOOKED", "CHECKED_IN", "CHECKED_OUT", "NO_SHOW"] as const;

function useWrite<TArgs, TResult>(call: (tenant: string, args: TArgs) => Promise<TResult>, tenant: string | null) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (args: TArgs) => {
      if (!tenant) throw new Error("No tenant selected");
      return call(tenant, args);
    },
    // Bars, counts, warnings and figures may all have changed.
    onSuccess: () => queryClient.invalidateQueries(),
  });
}

export function useAllocateCourse(tenant: string | null) {
  return useWrite(async (t, a: { courseId: number; bedIds: number[]; from: string; to: string }) => {
    const rows = await unwrap(
      api.POST("/rpc/fn_allocate_course", {
        body: { p_course_id: a.courseId, p_bed_ids: a.bedIds, p_from: a.from, p_to: a.to },
        headers: tenantHeaders(t),
      }),
    );
    return rows as unknown as Allocated[];
  }, tenant);
}

export function useCancelAllocation(tenant: string | null) {
  return useWrite(async (t, id: number) => {
    await unwrap(api.POST("/rpc/fn_cancel_allocation", { body: { p_allocation_id: id }, headers: tenantHeaders(t) }));
  }, tenant);
}

export function useMoveAllocation(tenant: string | null) {
  return useWrite(async (t, a: { id: number; bedId: number; from: string; to: string }) => {
    const rows = await unwrap(
      api.POST("/rpc/fn_move_allocation", {
        body: { p_allocation_id: a.id, p_bed_id: a.bedId, p_from: a.from, p_to: a.to },
        headers: tenantHeaders(t),
      }),
    );
    return (rows as unknown as Moved[])[0];
  }, tenant);
}

export function useSetStatus(tenant: string | null) {
  return useWrite(async (t, a: { id: number; status: string }) => {
    const rows = await unwrap(
      api.POST("/rpc/fn_set_status", { body: { p_allocation_id: a.id, p_status: a.status }, headers: tenantHeaders(t) }),
    );
    return (rows as unknown as StatusSet[])[0];
  }, tenant);
}
