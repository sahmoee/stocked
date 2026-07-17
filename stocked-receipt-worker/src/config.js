// config.js — GET /configuration (new function).
//
// Remotely managed app config so you can change behavior WITHOUT an App Store
// update: feature flags, min supported version, disabled recipe sources, request
// limits, a maintenance message, AI model selection + per-route token limits,
// rollout %, and emergency kill switches. Stored in KV under "config:current":
//     wrangler kv key put --binding=RATE_KV config:current '{"...":"..."}'
// No redeploy needed. Served over the authenticated (X-Stocked-Key) + TLS channel
// and cached briefly. Sends a strong ETag (SHA-256 of the config JSON) and honors
// If-None-Match with 304 so the app's frequent polls are nearly free.

import { json, sha256Hex, strongETag, etagMatches } from "./util.js";

const KV_KEY = "config:current";
const CACHE_URL = "https://config.internal/current";
const CACHE_TTL_S = 60;

// Safe defaults if nothing is in KV yet — nothing disabled, no maintenance.
const DEFAULT_CONFIG = Object.freeze({
  schemaVersion: 1,
  minSupportedVersion: "0.0.0",
  maintenance: { active: false, message: "" },
  featureFlags: {},              // e.g. { "cookNowV2": true }
  disabledRecipeSources: [],     // e.g. ["Spoonacular"]
  killSwitches: {},              // e.g. { "aiRecipeGeneration": false }
  aiModel: null,                 // null → worker uses its default
  aiLimits: {},                  // e.g. { "recipeGeneration": 3000 } — per-route max_tokens
  requestLimits: {},             // advisory limits the app can honor
  rollout: {},                   // e.g. { "newDashboard": 25 } (percent)
});

export async function loadConfig(env) {
  try {
    const raw = env.RATE_KV ? await env.RATE_KV.get(KV_KEY) : null;
    if (!raw) return DEFAULT_CONFIG;
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_CONFIG, ...parsed };
  } catch {
    return DEFAULT_CONFIG;
  }
}

/**
 * Config as seen by the worker itself (AI model/limits). Edge-cached ~60s so hot
 * AI routes don't add a KV read per request. Falls back to a direct KV read when
 * the Cache API is unavailable (tests).
 */
export async function getRuntimeConfig(env) {
  const RUNTIME_URL = "https://config.internal/runtime";
  try {
    const hit = await caches.default.match(RUNTIME_URL);
    if (hit) return await hit.json();
  } catch {}
  const config = await loadConfig(env);
  try {
    await caches.default.put(RUNTIME_URL, new Response(JSON.stringify(config), {
      headers: { "Cache-Control": `max-age=${CACHE_TTL_S}`, "Content-Type": "application/json" },
    }));
  } catch {}
  return config;
}

/** Per-route max_tokens override from config (aiLimits), bounded to sane values. */
export function resolveMaxTokens(config, route, fallback) {
  const v = config && config.aiLimits ? Number(config.aiLimits[route]) : NaN;
  return Number.isFinite(v) && v >= 100 && v <= 16000 ? Math.floor(v) : fallback;
}

/** Primary model: config override → env.ANTHROPIC_MODEL → worker default. */
export function resolveModel(config, envModel, defaultModel) {
  const m = config && typeof config.aiModel === "string" && config.aiModel.trim() ? config.aiModel.trim() : null;
  return m || envModel || defaultModel;
}

/** GET /configuration → signed, cached config with ETag/If-None-Match support. */
export async function handleConfiguration(request, env, _ctx) {
  const ifNoneMatch = request.headers.get("If-None-Match");

  // Serve from edge cache when warm (config changes are infrequent).
  try {
    const hit = await caches.default.match(CACHE_URL);
    if (hit) {
      const etag = hit.headers.get("ETag") || "";
      if (etagMatches(ifNoneMatch, etag)) return new Response(null, { status: 304, headers: { "ETag": etag } });
      return hit;
    }
  } catch {}

  const config = await loadConfig(env);
  const body = JSON.stringify(config);
  // Strong ETag over the config JSON itself (stable until the config changes).
  const etag = await strongETag(body);
  // Best-effort integrity tag. TLS already protects transport; this lets the app
  // detect a stale/edited cached copy if it ever wants to (see MANUAL_STEPS §config).
  const sig = env.SESSION_SIGNING_KEY ? await sha256Hex(body + env.SESSION_SIGNING_KEY) : null;

  const headers = { "Cache-Control": `max-age=${CACHE_TTL_S}`, "ETag": etag };
  const response = json({ config, sig, servedAt: Date.now() }, 200, headers);
  try { await caches.default.put(CACHE_URL, response.clone()); } catch {}
  if (etagMatches(ifNoneMatch, etag)) return new Response(null, { status: 304, headers: { "ETag": etag } });
  return response;
}
