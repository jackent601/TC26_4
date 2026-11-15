// Typed client for the API (PostgREST serving the database's api schema).
// Types come from src/api/schema.d.ts, generated with: scripts/ui-npm.sh run gen:api
// The UI only calls the API; it never decides what is allowed (D26).
import createClient from "openapi-fetch";
import type { components, paths } from "./schema";

export type Schemas = components["schemas"];

// Same origin: Caddy (built image) or Vite (dev) forwards /api to PostgREST.
export const api = createClient<paths>({ baseUrl: "/api" });

// Who is acting, until logins exist: sent as X-User and recorded in the audit
// log by the database (I5). Set from the "Your name" box (src/user.tsx).
let apiUser = "";
export function setApiUser(name: string) {
  // Header values must be plain ASCII; anything else becomes "?".
  apiUser = name.trim().replace(/[^\x20-\x7E]/g, "?").slice(0, 100);
}

// Every request names its tenant (and the user, if set); the database's
// pre-request hook applies them.
export function tenantHeaders(tenant: string): Record<string, string> {
  return apiUser ? { "X-Tenant": tenant, "X-User": apiUser } : { "X-Tenant": tenant };
}

// PostgREST errors look like { code, message, details, hint }. Rule failures
// raised in SQL (errcode P0001) arrive as 400 with the rule's message.
function errorMessage(error: unknown, response: Response): string {
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") {
    return error.message;
  }
  return `${response.status} ${response.statusText}`;
}

// Resolve an openapi-fetch call to its data, or throw with the API's message.
export async function unwrap<T>(
  call: Promise<{ data?: T; error?: unknown; response: Response }>,
): Promise<T> {
  const { data, error, response } = await call;
  if (!response.ok) throw new Error(errorMessage(error, response));
  return data as T;
}
