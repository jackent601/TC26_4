// Writes for the availability page (migration 0009, D30-D32). The database
// checks the rules, writes the audit log and returns warnings; the UI only
// calls and shows the result. After any write, everything shown is refetched.
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, tenantHeaders, unwrap } from "../../api/client";
import type { paths } from "../../api/schema";

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

// ------------------------- Courses (0013, D35) --------------------------

export interface CourseCreated {
  course_id: number;
  code: string;
}
export interface CourseUpdated {
  course_id: number;
  warnings: string[];
}
export interface LoadedUpdated {
  course_id: number;
  loaded: number;
  loaded_at: string;
  loaded_above_scheduled: boolean;
}
export interface CourseCancelled {
  course_id: number;
  allocations_cancelled: number;
}

export const COURSE_STATUSES = ["REQUESTED", "CONFIRMED"] as const;

// What the forms edit. Notes are in the API but not in course_figures, so not here.
export interface CourseInput {
  code: string;
  name: string;
  siteId: number | null;
  startDate: string; // first night
  endDate: string; // departure day, exclusive
  scheduled: number;
  loaded: number;
  status: string;
}

type CreateBody = paths["/rpc/fn_create_course"]["post"]["requestBody"]["content"]["application/json"];
type UpdateBody = paths["/rpc/fn_update_course"]["post"]["requestBody"]["content"]["application/json"];

export function useCreateCourse(tenant: string | null) {
  return useWrite(async (t, c: CourseInput) => {
    const body: CreateBody = {
      p_code: c.code, p_name: c.name, p_start_date: c.startDate, p_end_date: c.endDate,
      p_scheduled: c.scheduled, p_loaded: c.loaded, p_status: c.status,
      ...(c.siteId !== null ? { p_site_id: c.siteId } : {}),
    };
    const rows = await unwrap(api.POST("/rpc/fn_create_course", { body, headers: tenantHeaders(t) }));
    return (rows as unknown as CourseCreated[])[0];
  }, tenant);
}

// Only the fields given are changed; siteId null clears the site.
export type CourseChange = { id: number } & Partial<Omit<CourseInput, "loaded">>;

export function useUpdateCourse(tenant: string | null) {
  return useWrite(async (t, a: CourseChange) => {
    const body: UpdateBody = {
      p_course_id: a.id,
      ...(a.code !== undefined ? { p_code: a.code } : {}),
      ...(a.name !== undefined ? { p_name: a.name } : {}),
      ...(a.startDate !== undefined ? { p_start_date: a.startDate } : {}),
      ...(a.endDate !== undefined ? { p_end_date: a.endDate } : {}),
      ...(a.scheduled !== undefined ? { p_scheduled: a.scheduled } : {}),
      ...(a.status !== undefined ? { p_status: a.status } : {}),
      ...(a.siteId === null ? { p_clear_site: true } : a.siteId !== undefined ? { p_site_id: a.siteId } : {}),
    };
    const rows = await unwrap(api.POST("/rpc/fn_update_course", { body, headers: tenantHeaders(t) }));
    return (rows as unknown as CourseUpdated[])[0];
  }, tenant);
}

export function useUpdateLoaded(tenant: string | null) {
  return useWrite(async (t, a: { id: number; loaded: number }) => {
    const rows = await unwrap(
      api.POST("/rpc/fn_update_loaded", { body: { p_course_id: a.id, p_loaded: a.loaded }, headers: tenantHeaders(t) }),
    );
    return (rows as unknown as LoadedUpdated[])[0];
  }, tenant);
}

export function useCancelCourse(tenant: string | null) {
  return useWrite(async (t, id: number) => {
    const rows = await unwrap(api.POST("/rpc/fn_cancel_course", { body: { p_course_id: id }, headers: tenantHeaders(t) }));
    return (rows as unknown as CourseCancelled[])[0];
  }, tenant);
}
