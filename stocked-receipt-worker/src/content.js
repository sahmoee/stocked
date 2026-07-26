// content.js — GET /content/recipes and GET /content/img/* (Task: move curated
// content behind the worker).
//
// The app used to pull curated recipe JSON straight from cheap cPanel hosting.
// Now the worker fronts that origin (env.CONTENT_ORIGIN, default the cPanel
// host):
//   • /content/recipes — 6h edge cache + long-lived stale copy served when the
//     origin is down (stale-on-error), strong ETag (origin's, else SHA-256 of
//     the body) with If-None-Match → 304.
//   • /content/img/*   — passthrough image proxy with a 30-day edge cache so
//     images can move behind the same domain later.
// Both formats the app parses — wrapped {version,recipes:[…]} or a bare array —
// are accepted from origin and returned byte-for-byte unchanged.

import { json, errJson, withCors, strongETag, etagMatches, background, logEvent } from "./util.js";

// cPanel is abandoned — the worker now serves recipes straight from the GitHub repo that
// Recipe Studio pushes to (site-repo/master), cached at the edge. Override with env.CONTENT_ORIGIN.
export const DEFAULT_CONTENT_ORIGIN = "https://raw.githubusercontent.com/sahmoee/site-repo/master";
const RECIPES_PATH = "/content/recipes.json";
const RECIPES_TTL_S = 6 * 3600;          // fresh edge cache
const RECIPES_STALE_TTL_S = 7 * 24 * 3600; // stale-on-error fallback copy
const IMG_TTL_S = 30 * 24 * 3600;
const ORIGIN_TIMEOUT_MS = 8000;

const FRESH_URL = "https://content.internal/recipes";
const STALE_URL = "https://content-stale.internal/recipes";
const imgCacheURL = (path) => "https://content.internal" + path;

export function contentOriginFor(env) {
  const o = (env && env.CONTENT_ORIGIN) || DEFAULT_CONTENT_ORIGIN;
  return String(o).replace(/\/+$/, "");
}

/** The app parses either the wrapped or the bare-array shape; accept both. */
export function isRecipesPayload(parsed) {
  if (Array.isArray(parsed)) return true;
  return !!(parsed && typeof parsed === "object" && Array.isArray(parsed.recipes));
}

/** Use the origin's strong ETag when it sent one; otherwise hash the body. */
export async function etagForContent(originETag, bodyText) {
  if (typeof originETag === "string" && originETag.trim() && !originETag.trim().startsWith("W/")) {
    return originETag.trim();
  }
  return strongETag(bodyText);
}

async function timedFetch(url) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ORIGIN_TIMEOUT_MS);
  try { return await fetch(url, { signal: c.signal, headers: { "User-Agent": "Stocked-Worker/1.0" } }); }
  finally { clearTimeout(t); }
}

function recipesResponse(text, etag, { stale = false } = {}) {
  const headers = {
    "Content-Type": "application/json",
    "ETag": etag,
    "Cache-Control": `max-age=${RECIPES_TTL_S}`,
  };
  if (stale) headers["X-Stocked-Stale"] = "1";
  return new Response(text, { status: 200, headers });
}

function maybe304(request, etag) {
  if (etagMatches(request.headers.get("If-None-Match"), etag)) {
    return new Response(null, { status: 304, headers: { "ETag": etag } });
  }
  return null;
}

/** GET /content/recipes */
export async function handleContentRecipes(request, env, ctx, requestId) {
  // 1. Fresh edge cache.
  try {
    const hit = await caches.default.match(FRESH_URL);
    if (hit) {
      const etag = hit.headers.get("ETag") || "";
      return withCors(maybe304(request, etag) || hit);
    }
  } catch {}

  // 2. Origin fetch.
  const origin = contentOriginFor(env);
  let originError = null;
  try {
    const res = await timedFetch(origin + RECIPES_PATH);
    if (res.ok) {
      const text = await res.text();
      let parsed = null;
      try { parsed = JSON.parse(text); } catch {}
      if (isRecipesPayload(parsed)) {
        const etag = await etagForContent(res.headers.get("ETag"), text);
        const fresh = recipesResponse(text, etag);
        const freshCopy = recipesResponse(text, etag);              // separate body for the cache
        const staleCopy = recipesResponse(text, etag);
        const h = new Headers(staleCopy.headers);
        h.set("Cache-Control", `max-age=${RECIPES_STALE_TTL_S}`);
        background(ctx, (async () => {
          try {
            await caches.default.put(FRESH_URL, freshCopy);
            await caches.default.put(STALE_URL, new Response(text, { status: 200, headers: h }));
          } catch {}
        })());
        return withCors(maybe304(request, etag) || fresh);
      }
      originError = "invalidPayload";
    } else {
      originError = "status " + res.status;
    }
  } catch (e) {
    originError = String((e && e.message) || e);
  }

  // 3. Stale-on-error fallback.
  logEvent({ requestId, event: "contentOriginError", error: originError });
  try {
    const stale = await caches.default.match(STALE_URL);
    if (stale) {
      const etag = stale.headers.get("ETag") || "";
      const cached304 = maybe304(request, etag);
      if (cached304) return withCors(cached304);
      const h = new Headers(stale.headers);
      h.set("X-Stocked-Stale", "1");
      return withCors(new Response(stale.body, { status: 200, headers: h }));
    }
  } catch {}
  return errJson(502, "Content origin unavailable", { code: "upstreamError", requestId });
}

/** GET /content/img/* — passthrough proxy with a long edge cache. */
export async function handleContentImage(request, env, ctx, requestId, pathname) {
  if (!pathname.startsWith("/content/img/") || pathname.includes("..")) {
    return errJson(404, "Not found", { code: "notFound", requestId });
  }
  const cacheKey = imgCacheURL(pathname);
  try {
    const hit = await caches.default.match(cacheKey);
    if (hit) return withCors(hit);
  } catch {}

  let res;
  try { res = await timedFetch(contentOriginFor(env) + pathname); }
  catch { return errJson(502, "Content origin unavailable", { code: "upstreamError", requestId }); }
  if (!res.ok) {
    if (res.status === 404) return errJson(404, "Image not found", { code: "notFound", requestId });
    return errJson(502, "Content origin error", { code: "upstreamError", requestId, extra: { upstreamStatus: res.status } });
  }
  const body = await res.arrayBuffer();
  const headers = {
    "Content-Type": res.headers.get("Content-Type") || "application/octet-stream",
    "Cache-Control": `max-age=${IMG_TTL_S}`,
  };
  const out = new Response(body, { status: 200, headers });
  const copy = new Response(body.slice(0), { status: 200, headers });
  background(ctx, (async () => { try { await caches.default.put(cacheKey, copy); } catch {} })());
  return withCors(out);
}
