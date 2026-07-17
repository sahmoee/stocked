// diagnostics.js — POST /support/diagnostics (new function).
//
// Accepts a diagnostic payload from the app and returns a support reference the
// user can quote. Privacy by WHITELIST: only known-safe fields are kept; anything
// else (inventory names, receipt contents, account tokens, emails, etc.) is
// dropped before storage, even if the app sends it by mistake.

import { json, errJson, readBoundedJSON, randomToken, logEvent } from "./util.js";
import { validateDiagnostics, DIAG_MAX_BYTES } from "./validation.js";

const TTL_S = 30 * 24 * 3600;

// Only these fields are ever stored. Everything else is discarded.
const ALLOWED = new Set([
  "appVersion", "buildNumber", "workerVersion", "osVersion", "deviceModel",
  "recentFailures",       // [{ route, status, code, ts }] — codes/statuses only
  "cacheState",           // { entries, bytes } style counters
  "syncRevision", "migrationVersion",
  "deviceFlags",          // { lowPowerMode, reducedMotion, ... } booleans
  "connectivity", "locale", "timezone",
]);

/** Keep only whitelisted, primitive/shallow fields. Strings are length-capped. */
export function scrub(payload) {
  const out = {};
  if (!payload || typeof payload !== "object") return out;
  for (const key of Object.keys(payload)) {
    if (!ALLOWED.has(key)) continue;
    const v = payload[key];
    if (v == null) continue;
    if (typeof v === "string") out[key] = v.trim().slice(0, 200);
    else if (typeof v === "number" || typeof v === "boolean") out[key] = v;
    else if (key === "recentFailures" && Array.isArray(v)) {
      out[key] = v.slice(0, 20).map((f) => ({
        route: typeof f?.route === "string" ? f.route.slice(0, 40) : null,
        status: Number.isFinite(f?.status) ? f.status : null,
        code: typeof f?.code === "string" ? f.code.slice(0, 40) : null,
        ts: Number.isFinite(f?.ts) ? f.ts : null,
      }));
    } else if ((key === "deviceFlags" || key === "cacheState") && typeof v === "object") {
      const shallow = {};
      for (const k of Object.keys(v).slice(0, 30)) {
        const vv = v[k];
        if (typeof vv === "number" || typeof vv === "boolean") shallow[k] = vv;
        else if (typeof vv === "string") shallow[k] = vv.trim().slice(0, 60);
      }
      out[key] = shallow;
    }
  }
  return out;
}

export async function handleDiagnostics(request, env, _ctx, requestId) {
  const read = await readBoundedJSON(request, DIAG_MAX_BYTES);
  if (!read.ok) return errJson(read.status, read.message || "Bad request", { code: read.code, requestId });
  const body = read.value;
  const v = validateDiagnostics(body, read.bytes);
  if (!v.ok) return errJson(422, "Validation failed", { code: "invalidInput", requestId, extra: { errors: v.errors } });
  const clean = scrub(body);
  const reference = "STK-" + randomToken(5).toUpperCase();
  const record = { reference, receivedAt: Date.now(), diagnostics: clean };
  try {
    if (env.RATE_KV) await env.RATE_KV.put("diag:" + reference, JSON.stringify(record), { expirationTtl: TTL_S });
  } catch (e) {
    logEvent({ event: "diagStoreError", error: String((e && e.message) || e) });
    return errJson(503, "Could not store diagnostics", { code: "unavailable", requestId, extra: { reference: null } });
  }
  logEvent({ event: "diagStored", reference, keptFields: Object.keys(clean).length });
  return json({ reference, keptFields: Object.keys(clean) });
}
