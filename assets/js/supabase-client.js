// Browser Supabase client (publishable key only) plus thin, normalised wrappers
// for RPC and Edge Function calls. Errors become ApiError {code, message, status}.

import { config } from "./config.js";

let client = null;

export class ApiError extends Error {
  constructor(code, message, status = 0) {
    super(message || code);
    this.code = code;
    this.status = status;
  }
}

export function getClient() {
  if (client) return client;
  if (!window.supabase?.createClient) {
    throw new ApiError("CLIENT_MISSING", "The Supabase library failed to load. Check your connection and reload.");
  }
  client = window.supabase.createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: { flowType: "pkce", detectSessionInUrl: true, persistSession: true, autoRefreshToken: true },
  });
  return client;
}

function fromPostgrest(error) {
  if (!error) return null;
  if (typeof error.code === "string" && error.code.startsWith("CSW")) {
    return new ApiError(error.message, error.hint || error.message, 400);
  }
  if (error.code === "42501") return new ApiError("FORBIDDEN", "You are not allowed to do that.", 403);
  if (error.code === "23505") return new ApiError("DUPLICATE", "That was already done.", 409);
  if (error.message?.includes("Failed to fetch")) return new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
  return new ApiError("REQUEST_FAILED", "The request failed. Please try again.", 0);
}

/** Call a SQL function exposed to the browser (public/user functions only). */
export async function rpc(fn, args = {}) {
  const { data, error } = await getClient().rpc(fn, args);
  if (error) throw fromPostgrest(error);
  return data;
}

/** Run a PostgREST query builder and unwrap. */
export async function query(builder) {
  const { data, error } = await builder;
  if (error) throw fromPostgrest(error);
  return data;
}

/** Call an Edge Function with a JSON body. */
export async function invoke(name, body) {
  let result;
  try {
    result = await getClient().functions.invoke(name, { body });
  } catch {
    throw new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
  }
  const { data, error } = result;
  if (!error) return data;
  const response = error.context;
  if (response && typeof response.json === "function") {
    let payload = null;
    try {
      payload = await response.json();
    } catch {
      /* not JSON */
    }
    if (payload?.error) throw new ApiError(payload.error.code, payload.error.message, response.status);
    throw new ApiError("REQUEST_FAILED", "The request failed. Please try again.", response.status ?? 0);
  }
  throw new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
}

/** Public URL of a campaign creative stored in Supabase Storage. */
export function creativeUrl(path) {
  if (!path || !/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.(png|jpe?g|webp)$/.test(path)) return null;
  return `${config.supabaseUrl}/storage/v1/object/public/${config.creativeBucket}/${path}`;
}
