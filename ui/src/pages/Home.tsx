import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, tenantHeaders, unwrap } from "../api/client";
import { useTenant } from "../tenant";

// api.reset_demo_data returns a table; PostgREST's OpenAPI doesn't describe
// function results, so the shape is written here (see db/api-contract.txt).
interface ResetResult {
  tenant: string;
  day0: string;
  beds: number;
  courses: number;
  allocations: number;
  outages: number;
}

const dateTime = new Intl.DateTimeFormat("en-GB", { dateStyle: "short", timeStyle: "medium" });

export function Home() {
  const { code, isDemo } = useTenant();
  const queryClient = useQueryClient();

  const health = useQuery({
    queryKey: ["health", code],
    enabled: code !== null,
    queryFn: () => unwrap(api.GET("/health", { headers: tenantHeaders(code!) })),
    select: (rows) => rows[0],
  });

  const reset = useMutation({
    mutationFn: async () => {
      const rows = await unwrap(
        api.POST("/rpc/reset_demo_data", { body: {}, headers: tenantHeaders(code!) }),
      );
      return (rows as unknown as ResetResult[])[0];
    },
    // Everything shown for this tenant may have changed.
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const confirmReset = () => {
    if (window.confirm(`Wipe and reload all data in ${code}?`)) reset.mutate();
  };

  if (!code) return <p>Loading tenants…</p>;

  return (
    <section className="card">
      <h1>API status</h1>
      {health.isPending && <p>Checking…</p>}
      {health.error && <p className="error">API not reachable: {health.error.message}</p>}
      {health.data && (
        <dl className="facts">
          <dt>Status</dt>
          <dd>{health.data.status}</dd>
          <dt>Tenant</dt>
          <dd>{health.data.tenant}</dd>
          <dt>Beds</dt>
          <dd>{health.data.bed_count}</dd>
          <dt>Checked</dt>
          <dd>{health.data.checked_at && dateTime.format(new Date(health.data.checked_at))}</dd>
        </dl>
      )}
      <button type="button" onClick={() => health.refetch()} disabled={health.isFetching}>
        Refresh
      </button>

      {isDemo && (
        <div className="reset">
          <h2>Demo data</h2>
          <button type="button" className="danger" onClick={confirmReset} disabled={reset.isPending}>
            {reset.isPending ? "Resetting…" : "Reset demo data"}
          </button>
          {reset.error && <p className="error">{reset.error.message}</p>}
          {reset.data && (
            <p>
              Reloaded {reset.data.beds} beds, {reset.data.courses} courses, {reset.data.allocations}{" "}
              allocations and {reset.data.outages} outages, starting {reset.data.day0}.
            </p>
          )}
        </div>
      )}
    </section>
  );
}
