// crowd.js — anonymized crowd item database (CROWD KV). Behavior preserved from
// the original handler; secondary "popular"/"pair" writes are deferred with
// ctx.waitUntil so /report returns without waiting on them (improvement #6).

import { json, errJson, readBoundedJSON, background } from "./util.js";

const REPORT_MAX_BODY = 256 * 1024;   // bounded non-AI POST (hardening sweep)

const crowdNorm = (s) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

async function crowdGetAgg(env, key) {
  const raw = await env.CROWD.get("item:" + key);
  return raw ? JSON.parse(raw) : { count: 0, units: {}, containers: {}, categories: {}, qtySum: 0, qtyN: 0, shelfSum: 0, shelfN: 0 };
}
function crowdBump(map, k) { if (!k) return; k = String(k).toLowerCase(); map[k] = (map[k] || 0) + 1; }
function crowdTopKey(map) { let best = null, n = -1; for (const k in map) if (map[k] > n) { best = k; n = map[k]; } return best; }
async function crowdUpdatePopular(env, key) {
  const raw = await env.CROWD.get("popular");
  const pop = raw ? JSON.parse(raw) : {};
  pop[key] = (pop[key] || 0) + 1;
  const entries = Object.entries(pop).sort((a, b) => b[1] - a[1]).slice(0, 2000);
  await env.CROWD.put("popular", JSON.stringify(Object.fromEntries(entries)));
}

export async function handleCrowd(url, request, env, ctx, requestId) {
  const path = url.pathname.replace(/^\/crowd/, "") || "/";
  try {
    if (request.method === "POST" && path === "/report") {
      const read = await readBoundedJSON(request, REPORT_MAX_BODY);
      if (!read.ok) return errJson(read.status, read.message || "Bad request", { code: read.code, requestId });
      const body = read.value;
      const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
      for (const it of items) {
        const key = crowdNorm(it.name);
        if (!key || key.length < 2) continue;
        const agg = await crowdGetAgg(env, key);
        agg.count += 1;
        crowdBump(agg.units, it.unit);
        crowdBump(agg.containers, it.container);
        crowdBump(agg.categories, it.category);
        const q = Number(it.quantity);
        if (isFinite(q) && q > 0) { agg.qtySum += q; agg.qtyN += 1; }
        const sl = Number(it.shelfLifeDays);
        if (isFinite(sl) && sl > 0 && sl < 720) { agg.shelfSum = (agg.shelfSum || 0) + sl; agg.shelfN = (agg.shelfN || 0) + 1; }
        await env.CROWD.put("item:" + key, JSON.stringify(agg));
        // Popularity ranking is non-essential to the response → defer it.
        background(ctx, crowdUpdatePopular(env, key));
      }
      const basket = Array.isArray(body.basket) ? [...new Set(body.basket.map(crowdNorm).filter(Boolean))].slice(0, 60) : [];
      background(ctx, (async () => {
        for (const a of basket) {
          const raw = await env.CROWD.get("pair:" + a);
          const m = raw ? JSON.parse(raw) : {};
          for (const b of basket) if (a !== b) m[b] = (m[b] || 0) + 1;
          const top = Object.entries(m).sort((x, y) => y[1] - x[1]).slice(0, 40);
          await env.CROWD.put("pair:" + a, JSON.stringify(Object.fromEntries(top)));
        }
      })());
      return json({ ok: true, received: items.length });
    }

    if (request.method === "GET" && path === "/suggest") {
      const key = crowdNorm(url.searchParams.get("name"));
      if (!key) return errJson(400, "name required", { code: "invalidInput", requestId });
      const agg = await crowdGetAgg(env, key);
      return json({
        count: agg.count,
        topUnit: crowdTopKey(agg.units),
        topContainer: crowdTopKey(agg.containers),
        topCategory: crowdTopKey(agg.categories),
        avgQuantity: agg.qtyN ? +(agg.qtySum / agg.qtyN).toFixed(2) : null,
        avgShelfLifeDays: agg.shelfN ? +(agg.shelfSum / agg.shelfN).toFixed(1) : null,
      });
    }

    if (request.method === "GET" && path === "/autocomplete") {
      const prefix = crowdNorm(url.searchParams.get("prefix"));
      const limit = Math.min(20, Number(url.searchParams.get("limit")) || 10);
      const raw = await env.CROWD.get("popular");
      const pop = raw ? JSON.parse(raw) : {};
      const items = Object.entries(pop).filter(([k]) => !prefix || k.startsWith(prefix)).sort((a, b) => b[1] - a[1]).slice(0, limit).map(([k]) => k);
      return json({ items });
    }

    if (request.method === "GET" && path === "/pairings") {
      const key = crowdNorm(url.searchParams.get("name"));
      const raw = await env.CROWD.get("pair:" + key);
      const m = raw ? JSON.parse(raw) : {};
      const pairings = Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 20);
      return json({ pairings });
    }

    return errJson(404, "not found", { code: "notFound", requestId });
  } catch (e) {
    return errJson(500, String((e && e.message) || e), { code: "internalError", requestId });
  }
}
