// features.js — the "20 improvements" consolidated onto the Worker (cPanel abandoned).
//
// Every handler degrades gracefully: if a required secret/binding isn't set yet, it returns a
// clean {ok:false, code:"notConfigured", need:"…"} 501 instead of throwing, so the Worker always
// deploys and features light up as you add the secret/binding (see MANUAL_STEPS.md).
//
// Dispatch: index.js calls handleFeatureRoute(url, request, env, ctx, requestId); it returns a
// Response for a feature route, or null to let the normal routing continue.

import { json, errJson, withCors, background } from "./util.js";

const need = (what, requestId) =>
  json({ ok: false, code: "notConfigured", need: what, requestId }, 501);

const edgeCache = async (key, ttl, produce) => {
  try { const hit = await caches.default.match(key); if (hit) return hit; } catch {}
  const res = await produce();
  if (res && res.ok) {
    try {
      const copy = new Response(res.clone().body, res);
      copy.headers.set("Cache-Control", `max-age=${ttl}`);
      caches.default.put(key, copy).catch(() => {});
    } catch {}
  }
  return res;
};

// ── #1 API-key proxy — keep third-party keys server-side ─────────────────────
// /proxy/<service>/<upstream path…>?<query>  → forwards with the key injected, GET cached 1h.
const PROXY = {
  spoonacular: { base: "https://api.spoonacular.com", keyParam: "apiKey", secret: "SPOONACULAR_KEY" },
  usda:        { base: "https://api.nal.usda.gov",    keyParam: "api_key", secret: "USDA_KEY" },
  apininjas:   { base: "https://api.api-ninjas.com",  header: "X-Api-Key", secret: "API_NINJAS_KEY" },
  edamam:      { base: "https://api.edamam.com",      appIdParam: "app_id", keyParam: "app_key", secret: "EDAMAM_KEY", idSecret: "EDAMAM_ID" },
  rapidapi:    { base: null,                          header: "X-RapidAPI-Key", secret: "RAPIDAPI_KEY", hostFromQuery: true },
};
async function handleProxy(service, subpath, url, request, env, requestId) {
  const cfg = PROXY[service];
  if (!cfg) return errJson(404, "Unknown proxy", { code: "notFound", requestId });
  const key = env[cfg.secret];
  if (!key) return need(cfg.secret + " secret", requestId);
  let base = cfg.base;
  const q = new URLSearchParams(url.search);
  if (cfg.hostFromQuery) {
    const host = q.get("__host"); q.delete("__host");
    if (!host) return errJson(400, "rapidapi needs ?__host=", { code: "badInput", requestId });
    base = "https://" + host;
  }
  if (cfg.keyParam) q.set(cfg.keyParam, key);
  if (cfg.appIdParam && env[cfg.idSecret]) q.set(cfg.appIdParam, env[cfg.idSecret]);
  const target = base + "/" + subpath + (q.toString() ? "?" + q.toString() : "");
  const headers = { "User-Agent": "Stocked-Worker/1.0" };
  if (cfg.header) headers[cfg.header] = key;
  if (cfg.hostFromQuery) headers["X-RapidAPI-Host"] = new URL(base).host;
  const cacheKey = "https://proxy.internal/" + service + "/" + encodeURIComponent(target);
  return withCors(await edgeCache(cacheKey, 3600, () => fetch(target, { headers })));
}

// ── #2 Server-side recipe fetch/scrape ───────────────────────────────────────
// /recipes/fetch?url=…  → returns the page's JSON-LD recipe if present, else raw HTML. 12h cache.
async function handleRecipeFetch(url, env, requestId) {
  const target = url.searchParams.get("url");
  if (!target || !/^https?:\/\//.test(target)) return errJson(400, "url required", { code: "badInput", requestId });
  const cacheKey = "https://recipefetch.internal/" + encodeURIComponent(target);
  return withCors(await edgeCache(cacheKey, 12 * 3600, async () => {
    let html = "";
    try {
      const r = await fetch(target, { headers: { "User-Agent": "Mozilla/5.0 Stocked-Worker" } });
      if (!r.ok) return errJson(502, "Upstream " + r.status, { code: "upstreamError", requestId });
      html = await r.text();
    } catch (e) { return errJson(502, String(e && e.message || e), { code: "upstreamError", requestId }); }
    // Pull the first JSON-LD Recipe block if the site provides one.
    const blocks = [...html.matchAll(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi)];
    for (const b of blocks) {
      try {
        const data = JSON.parse(b[1].trim());
        const arr = Array.isArray(data) ? data : (data["@graph"] || [data]);
        const recipe = arr.find(x => x && (x["@type"] === "Recipe" || (Array.isArray(x["@type"]) && x["@type"].includes("Recipe"))));
        if (recipe) return json({ ok: true, recipe });
      } catch {}
    }
    return json({ ok: true, recipe: null, html: html.slice(0, 200000) });
  }));
}

// ── #17 Content packs (curated JSON collections) — served like the recipe feed ─
// /content/pack/<name>  → proxies <CONTENT_ORIGIN>/content/packs/<name>.json, 6h cache.
async function handleContentPack(name, env, requestId) {
  const safe = String(name).replace(/[^a-z0-9_-]/gi, "");
  if (!safe) return errJson(404, "Not found", { code: "notFound", requestId });
  const origin = (env.CONTENT_ORIGIN || "https://raw.githubusercontent.com/sahmoee/site-repo/master").replace(/\/+$/, "");
  const cacheKey = "https://pack.internal/" + safe;
  return withCors(await edgeCache(cacheKey, 6 * 3600, () =>
    fetch(origin + "/content/packs/" + safe + ".json", { headers: { "User-Agent": "Stocked-Worker/1.0" } })));
}

// ── #19 Store directory + search-link templates ──────────────────────────────
const STORES = [
  { id: "walmart",   name: "Walmart",     search: "https://www.walmart.com/search?q={q}" },
  { id: "target",    name: "Target",      search: "https://www.target.com/s?searchTerm={q}" },
  { id: "heb",       name: "H-E-B",       search: "https://www.heb.com/search/?q={q}" },
  { id: "kroger",    name: "Kroger",      search: "https://www.kroger.com/search?query={q}" },
  { id: "wholefoods",name: "Whole Foods", search: "https://www.wholefoodsmarket.com/search?text={q}" },
  { id: "publix",    name: "Publix",      search: "https://www.publix.com/search#criteria={q}" },
  { id: "costco",    name: "Costco",      search: "https://www.costco.com/CatalogSearch?keyword={q}" },
  { id: "traderjoes",name: "Trader Joe's",search: "https://www.traderjoes.com/home/search?q={q}" },
];
function handleStores() {
  return withCors(json({ ok: true, stores: STORES }, 200, { "Cache-Control": "max-age=86400" }));
}

// ── #18 Nutrition lookup (USDA-backed, key stays server-side) ─────────────────
async function handleNutrition(url, env, requestId) {
  if (!env.USDA_KEY) return need("USDA_KEY secret", requestId);
  const q = url.searchParams.get("q");
  if (!q) return errJson(400, "q required", { code: "badInput", requestId });
  const target = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${encodeURIComponent(q)}&pageSize=1&api_key=${env.USDA_KEY}`;
  const cacheKey = "https://nutrition.internal/" + encodeURIComponent(q.toLowerCase());
  return withCors(await edgeCache(cacheKey, 30 * 24 * 3600, () => fetch(target)));
}

// ── #20 Universal Links (AASA) ───────────────────────────────────────────────
function handleAASA(env) {
  const team = env.APPLE_TEAM_ID || "TEAMID";
  const appID = `${team}.${env.APPLE_BUNDLE_ID || "com.sowens.Stocked"}`;
  const body = { applinks: { apps: [], details: [{ appID, paths: ["/join/*", "/r/*", "/recipe/*", "/household/*"] }] } };
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "max-age=3600" } });
}

// ── #5 Household invite deep link (+ optional email) ─────────────────────────
async function handleInvite(request, env, requestId) {
  let b = {}; try { b = await request.json(); } catch {}
  const code = String(b.code || "").trim();
  if (!code) return errJson(400, "code required", { code: "badInput", requestId });
  const link = `https://sowensstudios.com/join/${encodeURIComponent(code)}`;
  const out = { ok: true, link, code };
  if (b.email) {
    const sent = await sendEmail(env, b.email, "You're invited to a Stocked household",
      `Tap to join: ${link}`);
    out.emailed = sent.ok; if (!sent.ok) out.emailNote = sent.note;
  }
  return withCors(json(out));
}

// ── #12/#17 Email via SMTP (Namecheap Private Email) or MailChannels ─────────
async function sendEmail(env, to, subject, text) {
  // Preferred: a small SMTP relay endpoint you host (env.SMTP_RELAY_URL + SMTP_RELAY_TOKEN).
  if (env.SMTP_RELAY_URL && env.SMTP_RELAY_TOKEN) {
    try {
      const r = await fetch(env.SMTP_RELAY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": "Bearer " + env.SMTP_RELAY_TOKEN },
        body: JSON.stringify({ to, from: env.SUPPORT_EMAIL || "support@sowensstudios.com", subject, text }),
      });
      return { ok: r.ok, note: r.ok ? "" : "relay " + r.status };
    } catch (e) { return { ok: false, note: String(e && e.message || e) }; }
  }
  return { ok: false, note: "email not configured (set SMTP_RELAY_URL + SMTP_RELAY_TOKEN)" };
}

// ── #6/#8 Price-drop watch (KV) ──────────────────────────────────────────────
async function handlePriceWatch(request, env, requestId) {
  if (!env.FEATURES_KV) return need("FEATURES_KV namespace", requestId);
  let b = {}; try { b = await request.json(); } catch {}
  const session = request.headers.get("X-Stocked-Session") || b.session || "anon";
  const item = String(b.item || "").trim();
  if (!item) return errJson(400, "item required", { code: "badInput", requestId });
  const key = `watch:${session}`;
  const cur = JSON.parse((await env.FEATURES_KV.get(key)) || "[]");
  const entry = { item, target: Number(b.targetPrice) || null, added: Date.now() };
  const next = cur.filter(x => x.item !== item).concat(entry);
  await env.FEATURES_KV.put(key, JSON.stringify(next.slice(-100)));
  return withCors(json({ ok: true, watching: next.length }));
}

// ── #16 Encrypted backup push/pull (KV; client encrypts before sending) ──────
async function handleBackup(method, request, env, requestId) {
  if (!env.FEATURES_KV) return need("FEATURES_KV namespace", requestId);
  const session = request.headers.get("X-Stocked-Session") || "anon";
  const key = `backup:${session}`;
  if (method === "GET") {
    const blob = await env.FEATURES_KV.get(key);
    return withCors(json({ ok: true, blob: blob || null }));
  }
  const body = await request.text();
  if (body.length > 2_000_000) return errJson(413, "Backup too large", { code: "tooLarge", requestId });
  await env.FEATURES_KV.put(key, body, { expirationTtl: 180 * 24 * 3600 });
  return withCors(json({ ok: true, bytes: body.length }));
}

// ── #11 Substitutions (crowd KV if present, else built-in table) ─────────────
const SUBS = {
  butter: ["margarine", "olive oil", "coconut oil"], egg: ["flax egg", "applesauce", "mashed banana"],
  milk: ["almond milk", "oat milk", "soy milk"], sugar: ["honey", "maple syrup", "stevia"],
  flour: ["almond flour", "oat flour", "gluten-free blend"], "sour cream": ["greek yogurt", "creme fraiche"],
  buttermilk: ["milk + lemon juice", "milk + vinegar"], "heavy cream": ["milk + butter", "coconut cream"],
};
function handleSubstitutions(url) {
  const name = (url.searchParams.get("name") || "").toLowerCase().trim();
  const list = SUBS[name] || Object.entries(SUBS).find(([k]) => name.includes(k) || k.includes(name))?.[1] || [];
  return withCors(json({ ok: true, name, substitutions: list }));
}

// ── #14 Analytics event (D1 if bound, else no-op accepted) ───────────────────
async function handleAnalytics(request, env, requestId) {
  let b = {}; try { b = await request.json(); } catch {}
  if (!env.DB) return withCors(json({ ok: true, stored: false, note: "D1 not bound" }));
  try {
    await env.DB.prepare("INSERT INTO events (ts, name, props) VALUES (?, ?, ?)")
      .bind(Date.now(), String(b.name || "event").slice(0, 64), JSON.stringify(b.props || {}).slice(0, 4000)).run();
    return withCors(json({ ok: true, stored: true }));
  } catch (e) { return withCors(json({ ok: true, stored: false, note: String(e && e.message || e) })); }
}

// ── #13/#15 Media upload to R2 (images mirror, feedback screenshots) ─────────
async function handleUpload(kind, request, env, requestId) {
  if (!env.MEDIA) return need("MEDIA R2 bucket", requestId);
  const name = request.headers.get("X-Filename") || `${kind}-${Date.now()}`;
  const safe = kind + "/" + name.replace(/[^a-z0-9._-]/gi, "");
  const body = await request.arrayBuffer();
  if (body.byteLength > 10_000_000) return errJson(413, "Too large", { code: "tooLarge", requestId });
  await env.MEDIA.put(safe, body, { httpMetadata: { contentType: request.headers.get("Content-Type") || "application/octet-stream" } });
  return withCors(json({ ok: true, key: safe, url: `/media/${safe}` }));
}
async function handleMediaGet(path, env, requestId) {
  if (!env.MEDIA) return need("MEDIA R2 bucket", requestId);
  const obj = await env.MEDIA.get(path);
  if (!obj) return errJson(404, "Not found", { code: "notFound", requestId });
  return withCors(new Response(obj.body, { headers: { "Content-Type": obj.httpMetadata?.contentType || "application/octet-stream", "Cache-Control": "max-age=2592000" } }));
}

// ── #3/#12 Realtime (WebSockets) + #4 Push (APNs) — scaffolds ────────────────
function handleRealtime(env, requestId) {
  // Needs a WebSocket handler on the HouseholdDO (hibernatable sockets). Scaffolded.
  return need("HouseholdDO WebSocket handler (see MANUAL_STEPS: realtime)", requestId);
}
function handlePush(env, requestId) {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return need("APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID secrets", requestId);
  // Real APNs JWT signing + /3/device push goes here once certs are set.
  return json({ ok: false, code: "notImplemented", note: "APNs signing scaffold — secrets present", requestId }, 501);
}

/** Per-user AI quota check (exported; call from the AI path). Returns {ok, remaining} or null. */
export async function checkAiQuota(env, session) {
  if (!env.FEATURES_KV || !session) return { ok: true, remaining: null };
  const limit = Number(env.AI_DAILY_LIMIT || 200);
  const day = new Date().toISOString().slice(0, 10);
  const key = `aiq:${session}:${day}`;
  const used = Number((await env.FEATURES_KV.get(key)) || 0);
  if (used >= limit) return { ok: false, remaining: 0 };
  await env.FEATURES_KV.put(key, String(used + 1), { expirationTtl: 2 * 24 * 3600 });
  return { ok: true, remaining: limit - used - 1 };
}

// ── Dispatcher ───────────────────────────────────────────────────────────────
export async function handleFeatureRoute(url, request, env, ctx, requestId) {
  const p = url.pathname, m = request.method;

  if (p === "/.well-known/apple-app-site-association") return handleAASA(env);
  if (m === "GET" && p === "/stores") return handleStores();
  if (m === "GET" && p === "/nutrition/lookup") return handleNutrition(url, env, requestId);
  if (m === "GET" && p === "/recipes/fetch") return handleRecipeFetch(url, env, requestId);
  if (m === "GET" && p === "/crowd/substitutions") return handleSubstitutions(url);
  if (m === "GET" && p.startsWith("/content/pack/")) return handleContentPack(p.slice("/content/pack/".length), env, requestId);
  if (m === "GET" && p.startsWith("/proxy/")) {
    const rest = p.slice("/proxy/".length); const slash = rest.indexOf("/");
    const svc = slash < 0 ? rest : rest.slice(0, slash);
    const sub = slash < 0 ? "" : rest.slice(slash + 1);
    return handleProxy(svc, sub, url, request, env, requestId);
  }
  if (m === "POST" && p === "/household/invite") return handleInvite(request, env, requestId);
  if (m === "POST" && p === "/prices/watch") return handlePriceWatch(request, env, requestId);
  if (p === "/backup") return handleBackup(m, request, env, requestId);
  if (m === "POST" && p === "/analytics/event") return handleAnalytics(request, env, requestId);
  if (m === "POST" && p === "/media/image") return handleUpload("images", request, env, requestId);
  if (m === "POST" && p === "/media/feedback") return handleUpload("feedback", request, env, requestId);
  if (m === "GET" && p.startsWith("/media/")) return handleMediaGet(p.slice("/media/".length), env, requestId);
  if (p === "/realtime/household") return handleRealtime(env, requestId);
  if (m === "POST" && p === "/push/register") return handlePush(env, requestId);

  return null; // not a feature route
}
