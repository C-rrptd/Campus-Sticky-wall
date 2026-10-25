// Identity and database access for Edge Functions.
//
// Two database handles are used:
//   * service db  — secret key (Postgres role service_role). Only for the
//                   trusted SECURITY DEFINER functions; the caller's identity
//                   is passed explicitly as a parameter AFTER verification here.
//   * user db     — publishable key + the caller's JWT (role authenticated),
//                   so auth.uid() inside SQL is the caller. Used for admin and
//                   leaderboard functions that self-authorize in SQL.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.0";
import { HttpError, withErrors } from "./security.ts";

export type Handler = (req: Request, deps: Deps) => Promise<Response>;

/** Wrap a handler with CORS preflight + error mapping for the given deps. */
export function bind(handler: Handler, deps: Deps): (req: Request) => Promise<Response> {
  return withErrors((req) => handler(req, deps), deps.env);
}

/** Entry point used by every function's index.ts. */
export function serve(handler: Handler): void {
  Deno.serve((req) => {
    let deps: Deps;
    try {
      deps = defaultDeps();
    } catch (err) {
      console.error(err instanceof Error ? err.message : err);
      return new Response(JSON.stringify({ error: { code: "NOT_CONFIGURED", message: "Service is not configured." } }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      });
    }
    return bind(handler, deps)(req);
  });
}

export interface Db {
  rpc(fn: string, args: Record<string, unknown>): Promise<{
    data: unknown;
    error: { code?: string; message: string; hint?: string | null; details?: string | null } | null;
  }>;
}

export interface AuthUser {
  id: string;
  email?: string;
}

/** Minimal Storage surface (absent in tests that don't need it). */
export interface MediaStorage {
  remove(paths: string[]): Promise<void>;
}

export interface Deps {
  /** service_role database handle */
  db: Db;
  /** database handle that acts as the given user (JWT) */
  userDb: (jwt: string) => Db;
  /** verify a bearer token; return the user or null */
  verifyJwt: (jwt: string) => Promise<AuthUser | null>;
  fetch: typeof fetch;
  env: (key: string) => string | undefined;
  /** optional Supabase Auth admin hook (ban/unban); absent in tests */
  setUserBan?: (userId: string, banned: boolean) => Promise<void>;
  storage?: MediaStorage;
}

function firstKey(jsonDict: string | undefined): string | undefined {
  if (!jsonDict) return undefined;
  try {
    const parsed = JSON.parse(jsonDict) as Record<string, string>;
    return parsed["default"] ?? Object.values(parsed)[0];
  } catch {
    return undefined;
  }
}

/** Secret key: new-style SUPABASE_SECRET_KEYS JSON, falling back to legacy service_role key. */
export function secretKey(env: (k: string) => string | undefined): string | undefined {
  return firstKey(env("SUPABASE_SECRET_KEYS")) ?? env("SUPABASE_SECRET_KEY") ?? env("SUPABASE_SERVICE_ROLE_KEY");
}

export function publishableKey(env: (k: string) => string | undefined): string | undefined {
  return firstKey(env("SUPABASE_PUBLISHABLE_KEYS")) ?? env("SUPABASE_PUBLISHABLE_KEY") ?? env("SUPABASE_ANON_KEY");
}

let cached: Deps | undefined;

/** Adapt a supabase-js client to the minimal Db interface used by handlers. */
function toDb(client: SupabaseClient): Db {
  return {
    rpc: async (fn, args) => {
      const { data, error } = await client.rpc(fn, args);
      return { data, error };
    },
  };
}

/** Production dependencies built from the Edge Function environment. */
export function defaultDeps(): Deps {
  if (cached) return cached;
  const env = (k: string) => Deno.env.get(k);
  const url = env("SUPABASE_URL");
  const secret = secretKey(env);
  const publishable = publishableKey(env);
  if (!url || !secret || !publishable) {
    throw new Error("Supabase environment is not configured (SUPABASE_URL / secret / publishable keys).");
  }
  const admin: SupabaseClient = createClient(url, secret, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const deps: Deps = {
    db: toDb(admin),
    userDb: (jwt) =>
      toDb(createClient(url, publishable, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      })),
    verifyJwt: async (jwt) => {
      const { data, error } = await admin.auth.getUser(jwt);
      if (error || !data?.user) return null;
      return { id: data.user.id, email: data.user.email ?? undefined };
    },
    fetch: (...args) => fetch(...args),
    env,
    setUserBan: async (userId, banned) => {
      const { error } = await admin.auth.admin.updateUserById(userId, { ban_duration: banned ? "876000h" : "none" });
      if (error) throw new Error(error.message);
    },
    storage: {
      remove: async (paths) => {
        if (paths.length === 0) return;
        const { error } = await admin.storage.from("note-media").remove(paths);
        if (error) throw new Error(error.message);
      },
    },
  };
  cached = deps;
  return deps;
}

export function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) return null;
  const token = match[1].trim();
  // Publishable/secret keys are not JWTs; only a three-part token can be a session.
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  // A legacy anon-key JWT identifies no user: treat it as a guest. This only
  // ever lowers privileges, so reading the unverified claim is safe here.
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (payload?.role === "anon") return null;
  } catch {
    // Not decodable: fall through and let verification reject it.
  }
  return token;
}

/** Returns the verified user, or null for guests. A bad token is an error, not a guest. */
export async function optionalUser(req: Request, deps: Deps): Promise<{ user: AuthUser | null; jwt: string | null }> {
  const jwt = bearerToken(req);
  if (!jwt) return { user: null, jwt: null };
  const user = await deps.verifyJwt(jwt);
  if (!user) throw new HttpError(401, "INVALID_SESSION", "Your session has expired. Please sign in again.");
  return { user, jwt };
}

export async function requireUser(req: Request, deps: Deps): Promise<{ user: AuthUser; jwt: string }> {
  const { user, jwt } = await optionalUser(req, deps);
  if (!user || !jwt) throw new HttpError(401, "AUTH_REQUIRED", "Please sign in first.");
  return { user, jwt };
}
