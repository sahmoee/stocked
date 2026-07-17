// metrics.js — lightweight ops metrics (improvement sweep #8).
//
// Daily per-route request + error counters in KV (RATE_KV, key metrics:YYYY-MM-DD).
// KV has strict write limits, so we SAMPLE 1-in-10 requests and add weight 10 per
// recorded hit — approximate counts, one deferred (waitUntil) write per sampled
// request, zero writes for the other nine. Metrics failures NEVER affect the
// request path: everything is wrapped and best-effort.
// Exposed via GET /metrics/today (shared-key gated).

import { json, background, logEvent } from "./util.js";

export const SAMPLE_RATE = 10;               // record 1 in N requests
const TTL_S = 3 * 24 * 3600;                 // keep a few days of rollups

export function metricsKey(now = new Date()) {
  return "metrics:" + now.toISOString().slice(0, 10);
}

/** Pure rollup increment. `weight` compensates for sampling. */
export function bumpRollup(rollup, route, status, weight = SAMPLE_RATE) {
  const r = rollup && typeof rollup === "object" ? rollup : {};
  r.sampleRate = SAMPLE_RATE;
  r.total = (r.total || 0) + weight;
  r.routes = r.routes || {};
  const name = route || "unknown";
  r.routes[name] = (r.routes[name] || 0) + weight;
  if (Number(status) >= 400) {
    r.errors = r.errors || {};
    r.errors.total = (r.errors.total || 0) + weight;
    const bucket = Number(status) >= 500 ? "5xx" : "4xx";
    r.errors[bucket] = (r.errors[bucket] || 0) + weight;
    r.errors.byRoute = r.errors.byRoute || {};
    r.errors.byRoute[name] = (r.errors.byRoute[name] || 0) + weight;
  }
  return r;
}

/** Best-effort sampled counter write. Never throws, never blocks the response. */
export function recordMetrics(env, ctx, route, status) {
  try {
    if (!env || !env.RATE_KV) return;
    if (Math.floor(Math.random() * SAMPLE_RATE) !== 0) return; // 1-in-10 sample
    background(ctx, (async () => {
      try {
        const key = metricsKey();
        const raw = await env.RATE_KV.get(key);
        let rollup = {};
        try { rollup = raw ? JSON.parse(raw) : {}; } catch {}
        bumpRollup(rollup, route, status);
        await env.RATE_KV.put(key, JSON.stringify(rollup), { expirationTtl: TTL_S });
      } catch (e) {
        logEvent({ event: "metricsWriteError", error: String((e && e.message) || e) });
      }
    })());
  } catch { /* metrics must never affect the request */ }
}

/** GET /metrics/today → the day's (approximate, sampled) rollup. */
export async function handleMetricsToday(env, requestId) {
  let rollup = {};
  try {
    const raw = env.RATE_KV ? await env.RATE_KV.get(metricsKey()) : null;
    rollup = raw ? JSON.parse(raw) : {};
  } catch {}
  return json({ date: metricsKey().slice("metrics:".length), sampleRate: SAMPLE_RATE, approximate: true, rollup, requestId });
}
