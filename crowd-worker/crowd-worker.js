// crowd-worker.js — Stocked shared "crowd" item database (Cloudflare Worker + KV).
//
// Anonymized and opt-in: the app reports only item facts (name, category, unit, container,
// quantity) — NEVER user identity, location, or account data. In return the app gets smarter
// defaults for everyone: the typical unit/container/quantity for an item, category guesses,
// autocomplete of common items, and ingredient pairings (items frequently used together).
//
// Setup:
//   1. Create a KV namespace, bind it as CROWD (wrangler.toml kv_namespaces).
//   2. Set a secret CROWD_KEY (wrangler secret put CROWD_KEY) — the app sends it as X-Stocked-Key.
//   3. Deploy:  npx wrangler deploy
//
// Endpoints (all require header  X-Stocked-Key: <CROWD_KEY>):
//   POST /report      { items: [{name, category, unit, container, quantity}], basket?: [names] }
//   GET  /suggest?name=milk         -> { count, topUnit, topContainer, topCategory, avgQuantity }
//   GET  /autocomplete?prefix=ch    -> { items: ["cheese","chicken",...] }
//   GET  /pairings?name=pasta       -> { pairings: [["tomato",210],["garlic",190],...] }

const norm = (s) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });

async function getAgg(env, key) {
  const raw = await env.CROWD.get("item:" + key);
  return raw ? JSON.parse(raw) : { count: 0, units: {}, containers: {}, categories: {}, qtySum: 0, qtyN: 0 };
}

function bump(map, k) { if (!k) return; k = String(k).toLowerCase(); map[k] = (map[k] || 0) + 1; }
function topKey(map) { let best = null, n = -1; for (const k in map) if (map[k] > n) { best = k; n = map[k]; } return best; }

async function updatePopular(env, key) {
  const raw = await env.CROWD.get("popular");
  const pop = raw ? JSON.parse(raw) : {};
  pop[key] = (pop[key] || 0) + 1;
  const entries = Object.entries(pop).sort((a, b) => b[1] - a[1]).slice(0, 2000);
  await env.CROWD.put("popular", JSON.stringify(Object.fromEntries(entries)));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type,X-Stocked-Key",
        },
      });
    }

    if ((request.headers.get("X-Stocked-Key") || "") !== env.CROWD_KEY) {
      return json({ error: "unauthorized" }, 401);
    }

    try {
      if (request.method === "POST" && url.pathname === "/report") {
        const body = await request.json();
        const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
        for (const it of items) {
          const key = norm(it.name);
          if (!key || key.length < 2) continue;
          const agg = await getAgg(env, key);
          agg.count += 1;
          bump(agg.units, it.unit);
          bump(agg.containers, it.container);
          bump(agg.categories, it.category);
          const q = Number(it.quantity);
          if (isFinite(q) && q > 0) { agg.qtySum += q; agg.qtyN += 1; }
          await env.CROWD.put("item:" + key, JSON.stringify(agg));
          await updatePopular(env, key);
        }
        const basket = Array.isArray(body.basket)
          ? [...new Set(body.basket.map(norm).filter(Boolean))].slice(0, 60) : [];
        for (const a of basket) {
          const raw = await env.CROWD.get("pair:" + a);
          const m = raw ? JSON.parse(raw) : {};
          for (const b of basket) if (a !== b) m[b] = (m[b] || 0) + 1;
          const top = Object.entries(m).sort((x, y) => y[1] - x[1]).slice(0, 40);
          await env.CROWD.put("pair:" + a, JSON.stringify(Object.fromEntries(top)));
        }
        return json({ ok: true, received: items.length });
      }

      if (request.method === "GET" && url.pathname === "/suggest") {
        const key = norm(url.searchParams.get("name"));
        if (!key) return json({ error: "name required" }, 400);
        const agg = await getAgg(env, key);
        return json({
          count: agg.count,
          topUnit: topKey(agg.units),
          topContainer: topKey(agg.containers),
          topCategory: topKey(agg.categories),
          avgQuantity: agg.qtyN ? +(agg.qtySum / agg.qtyN).toFixed(2) : null,
        });
      }

      if (request.method === "GET" && url.pathname === "/autocomplete") {
        const prefix = norm(url.searchParams.get("prefix"));
        const limit = Math.min(20, Number(url.searchParams.get("limit")) || 10);
        const raw = await env.CROWD.get("popular");
        const pop = raw ? JSON.parse(raw) : {};
        const items = Object.entries(pop)
          .filter(([k]) => !prefix || k.startsWith(prefix))
          .sort((a, b) => b[1] - a[1]).slice(0, limit).map(([k]) => k);
        return json({ items });
      }

      if (request.method === "GET" && url.pathname === "/pairings") {
        const key = norm(url.searchParams.get("name"));
        const raw = await env.CROWD.get("pair:" + key);
        const m = raw ? JSON.parse(raw) : {};
        const pairings = Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 20);
        return json({ pairings });
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String((e && e.message) || e) }, 500);
    }
  },
};
