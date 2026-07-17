// discover.js — server-side recipe-source coordinator (new function #9).
//
// Instead of the iOS app fanning out to many recipe APIs every time the Recipes
// tab opens, the Worker queries approved sources in parallel, normalizes and
// dedupes them, tracks per-source health with circuit breakers, and caches the
// normalized summary. The app makes ONE request.

import { json, background, logEvent } from "./util.js";

const CACHE_TTL_S = 900;                 // 15-min fresh window
const CACHE_STORE_S = 3 * 3600;          // entries live 3h so stale copies can be served-while-revalidating
const SOURCE_TIMEOUT_MS = 6000;
const SOURCE_BREAKER_FAILS = 3;
const SOURCE_BREAKER_COOLDOWN_S = 120;

function cacheURL(q) { return "https://discover.internal/" + encodeURIComponent(q); }
function breakerURL(src) { return "https://src-breaker.internal/" + encodeURIComponent(src); }

async function breakerOpen(src) {
  try { const h = await caches.default.match(breakerURL(src)); return h ? (parseInt(await h.text(), 10) || 0) >= SOURCE_BREAKER_FAILS : false; }
  catch { return false; }
}
async function breakerRecord(src, failed) {
  try {
    if (!failed) { await caches.default.delete(breakerURL(src)); return; }
    const cur = await (async () => { const h = await caches.default.match(breakerURL(src)); return h ? (parseInt(await h.text(), 10) || 0) : 0; })();
    await caches.default.put(breakerURL(src), new Response(String(cur + 1), { headers: { "Cache-Control": "max-age=" + SOURCE_BREAKER_COOLDOWN_S } }));
  } catch {}
}

async function timedFetch(url, opts) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), SOURCE_TIMEOUT_MS);
  try { return await fetch(url, { ...opts, signal: c.signal }); }
  finally { clearTimeout(t); }
}

// Normalizers → a single OnlineRecipe-like summary shape.
function normMealDB(m) {
  return {
    id: "mealdb:" + m.idMeal, title: m.strMeal, source: "TheMealDB",
    area: m.strArea || "", category: m.strCategory || "", image: m.strMealThumb || "",
  };
}
function normCocktail(c) {
  return {
    id: "cocktaildb:" + c.idDrink, title: c.strDrink, source: "CocktailDB",
    area: "", category: c.strCategory || "Drink", image: c.strDrinkThumb || "",
  };
}

async function fromMealDB(query) {
  const src = "TheMealDB";
  if (await breakerOpen(src)) return { src, ok: false, recipes: [] };
  try {
    const url = query
      ? "https://www.themealdb.com/api/json/v1/1/search.php?s=" + encodeURIComponent(query)
      : "https://www.themealdb.com/api/json/v1/1/search.php?f=" + "abcdefghijklmnopqrstuvw"[Math.floor(Math.random() * 22)];
    const res = await timedFetch(url);
    if (!res.ok) throw new Error("status " + res.status);
    const data = await res.json();
    await breakerRecord(src, false);
    return { src, ok: true, recipes: (data.meals || []).map(normMealDB) };
  } catch (e) { await breakerRecord(src, true); return { src, ok: false, recipes: [], error: String(e) }; }
}

async function fromCocktailDB(query) {
  const src = "CocktailDB";
  if (await breakerOpen(src)) return { src, ok: false, recipes: [] };
  try {
    const url = "https://www.thecocktaildb.com/api/json/v1/1/search.php?s=" + encodeURIComponent(query || "margarita");
    const res = await timedFetch(url);
    if (!res.ok) throw new Error("status " + res.status);
    const data = await res.json();
    await breakerRecord(src, false);
    return { src, ok: true, recipes: (data.drinks || []).map(normCocktail) };
  } catch (e) { await breakerRecord(src, true); return { src, ok: false, recipes: [], error: String(e) }; }
}

/** Normalized cache key input: lowercase, trimmed, length-capped. Pure (tested). */
export function normalizeDiscoverQuery(q) {
  return typeof q === "string" ? q.trim().toLowerCase().slice(0, 80) : "";
}

/** Is a cached entry past its fresh window (but still usable as stale)? Pure (tested). */
export function isStale(storedAtMs, nowMs, freshSeconds = CACHE_TTL_S) {
  const stored = Number(storedAtMs);
  if (!Number.isFinite(stored) || stored <= 0) return true;
  return nowMs - stored > freshSeconds * 1000;
}

/** Query the sources, assemble + dedupe the feed, and cache it. */
async function assembleAndCache(query, wantDrinks, cacheKey) {
  const tasks = [fromMealDB(query)];
  if (wantDrinks) tasks.push(fromCocktailDB(query));
  const settled = await Promise.all(tasks);

  const health = {};
  const seen = new Set();
  const recipes = [];
  for (const r of settled) {
    health[r.src] = r.ok ? "ok" : "degraded";
    for (const rec of r.recipes) {
      const key = rec.title.toLowerCase().trim();
      if (rec.title && !seen.has(key)) { seen.add(key); recipes.push(rec); }
    }
  }
  const payload = { schemaVersion: 1, query, count: recipes.length, sourceHealth: health, recipes: recipes.slice(0, 60) };
  logEvent({ event: "discover", query, count: recipes.length, health });

  try {
    await caches.default.put(cacheKey, new Response(JSON.stringify(payload), {
      headers: {
        "Cache-Control": "max-age=" + CACHE_STORE_S,
        "Content-Type": "application/json",
        "X-Stored-At": String(Date.now()),
      },
    }));
  } catch {}
  return payload;
}

export async function handleDiscover(request, env, ctx) {
  let body; try { body = await request.json(); } catch { body = {}; }
  const query = typeof body.query === "string" ? body.query.trim().slice(0, 80) : "";
  const wantDrinks = body.includeDrinks !== false;

  // Stale-while-revalidate: entries are stored for CACHE_STORE_S; within the
  // first CACHE_TTL_S they're served as fresh, after that we serve the stale
  // copy immediately and refresh in the background via ctx.waitUntil.
  const cacheKey = cacheURL(`${normalizeDiscoverQuery(query)}|${wantDrinks}`);
  try {
    const hit = await caches.default.match(cacheKey);
    if (hit) {
      const stale = isStale(hit.headers.get("X-Stored-At"), Date.now());
      const data = await hit.json();
      if (stale) background(ctx, assembleAndCache(query, wantDrinks, cacheKey));
      return json({ ...data, cached: true, ...(stale ? { stale: true } : {}) });
    }
  } catch {}

  return json(await assembleAndCache(query, wantDrinks, cacheKey));
}
