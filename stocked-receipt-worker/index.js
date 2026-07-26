// index.js — Stocked Worker entry point (modular).
//
// Preserves the shipped app's contract exactly:
//   • X-Stocked-Key shared-secret gate
//   • POST "/" with a payload → the 7 legacy AI routes, response is the Anthropic
//     envelope with content[0].text (+ schemaVersion/route/workerVersion)
//   • /household/* and /crowd/* request/response shapes
// Adds: Durable Object household sync, native rate limiting, ctx.waitUntil,
// request IDs + structured logs, upstream timeout/breaker/fallback + output
// validation, new pathname AI endpoints, /recipes/discover, /daily-brief,
// short-lived Apple session auth, /content/* origin proxy with edge caching,
// sampled ops metrics, and a consistent { error, code, requestId } envelope.
// See MANUAL_STEPS.md for bindings/secrets.

import { corsHeadersFor, SECURITY_HEADERS, json, errJson, withCors, makeRequestId, logEvent, background } from "./src/util.js";
import { validateInput } from "./src/validation.js";
import { callAnthropicResilient, runValidatedRoute, extractText } from "./src/ai.js";
import { buildLegacyPrompt, buildRoutePrompt, PATH_ROUTES, ROUTE_SCHEMA } from "./src/routes.js";
import { handleHousehold } from "./src/household.js";
import { handleCrowd } from "./src/crowd.js";
import { handleDiscover } from "./src/discover.js";
import { handleDailyBrief, handleBriefQueue, handleScheduledBriefs, handleBriefContext } from "./src/dailybrief.js";
import { handleConfiguration, getRuntimeConfig, resolveMaxTokens, resolveModel } from "./src/config.js";
import { handleBarcodeResolve } from "./src/barcodes.js";
import { handleDiagnostics } from "./src/diagnostics.js";
import { handlePricesCompare } from "./src/prices.js";
import { handleContentRecipes, handleContentImage, contentOriginFor } from "./src/content.js";
import { handleFeatureRoute, checkAiQuota } from "./src/features.js";
import { handleSmartRoute } from "./src/smart.js";
import { recordMetrics, handleMetricsToday } from "./src/metrics.js";
import { sharedKeyOK, verifyAppleIdentityToken, issueSession, verifySession, verifyAttestation } from "./src/auth.js";
import { isLimited, limiterFor, rateSubject } from "./src/ratelimit.js";
import { handleQARoute } from "./src/qa.js";
import { HouseholdDO } from "./src/household-do.js";

export { HouseholdDO }; // Durable Object must be exported from the entry module.

const WORKER_VERSION = "2026-07-26.1";
const DEFAULT_MODEL = "claude-sonnet-5";
const FALLBACK_MODEL = "claude-haiku-4-5-20251001";
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const NO_STORE = { "Cache-Control": "no-store" };   // auth/session responses must never be cached

// Routes that require App Attest when enabled (expensive AI paths).
const EXPENSIVE_ROUTES = new Set(["receiptImage", "recipeGeneration", "recipeEnrich", "recipeBuildAround", "mealPlanOptimize"]);

function aiResultURL(key) { return "https://ai-cache.internal/" + encodeURIComponent(key); }

export default {
  async fetch(request, env, ctx) {
    const requestId = makeRequestId();
    const started = Date.now();
    const url = new URL(request.url);
    let route = "unknown", status = 200;
    // Capture the handler's real status, and stamp timing + request id on every response.
    const done = (resp) => {
      status = resp.status;
      try { resp.headers.set("Server-Timing", `worker;dur=${Date.now() - started}`); resp.headers.set("X-Request-Id", requestId); } catch {}
      return resp;
    };
    try {
      if (request.method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: { ...corsHeadersFor(request.headers.get("Origin"), env.CORS_ALLOW_ORIGINS), ...SECURITY_HEADERS },
        });
      }

      if (url.pathname === "/health") {
        const base = {
          ok: true, version: WORKER_VERSION,
          hasAnthropicKey: !!env.ANTHROPIC_API_KEY,
          hasSharedKey: !!env.STOCKED_SHARED_KEY,
          hasSessionKey: !!env.SESSION_SIGNING_KEY,
          hasHouseholdDO: !!env.HOUSEHOLD_DO,
          contentOrigin: contentOriginFor(env),
        };
        if (!url.searchParams.get("deep")) return json(base, 200);
        // Deep health: actually probe dependencies with timings.
        const checks = {};
        try { const t = Date.now(); await env.RATE_KV.put("hc:probe", "1", { expirationTtl: 60 }); const v = await env.RATE_KV.get("hc:probe"); checks.rateKV = { ok: v === "1", ms: Date.now() - t }; }
        catch (e) { checks.rateKV = { ok: false, error: String(e && e.message || e) }; }
        try { const t = Date.now(); const v = await env.CROWD.get("hc:probe"); checks.crowdKV = { ok: true, ms: Date.now() - t, present: v != null }; }
        catch (e) { checks.crowdKV = { ok: false, error: String(e && e.message || e) }; }
        checks.householdDO = { ok: !!env.HOUSEHOLD_DO };
        checks.featuresKV = { bound: !!env.FEATURES_KV };
        checks.mediaR2 = { bound: !!env.MEDIA };
        checks.analyticsD1 = { bound: !!env.DB };
        return json({ ...base, deep: true, checks }, 200);
      }

      if (url.pathname === "/version") {
        return json({
          ok: true, version: WORKER_VERSION, time: new Date().toISOString(),
          maintenance: env.MAINTENANCE === "1",
          capabilities: [
            "ai", "sessions", "household-sync", "crowd", "barcodes", "prices", "discover", "daily-brief",
            "config", "diagnostics", "content-feed", "proxy-keys", "recipe-fetch", "invite", "price-watch",
            "backup", "media", "analytics", "substitutions", "aasa", "units-convert", "recipe-scale",
            "pantry-match", "grocery-optimize", "nutrition-estimate", "expiry-estimate", "season", "meal-plan",
            "barcodes-batch", "temperature", "experiment", "deep-health", "server-timing",
          ],
        }, 200);
      }

      // Public, keyless route: Apple fetches the Universal Links file with no headers (#20).
      if (url.pathname === "/.well-known/apple-app-site-association") {
        route = "aasa";
        return done(await handleFeatureRoute(url, request, env, ctx, requestId));
      }

      // Global maintenance kill-switch (health / version / AASA above stay reachable).
      if (env.MAINTENANCE === "1") { status = 503; return errJson(503, "Temporarily down for maintenance", { code: "maintenance", requestId, retryAfter: 120 }); }

      // Coarse outer gate (shared secret still ships as a first filter).
      if (!sharedKeyOK(request, env)) { status = 401; return errJson(401, "Unauthorized", { code: "unauthorized", requestId }); }

      // Diagnostics echo (authed): reflect request shape for debugging clients.
      if (url.pathname === "/ops/echo") {
        return done(json({ ok: true, method: request.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), colo: (request.cf && request.cf.colo) || null,
          country: (request.cf && request.cf.country) || null, requestId, at: new Date().toISOString() }, 200));
      }

      // Rate-limit subject: a valid, non-guest session keys limits by its subject
      // (fairer behind NAT); otherwise the connecting IP.
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const sessionHeader = request.headers.get("X-Stocked-Session") || "";
      let session = null;
      if (sessionHeader) session = await verifySession(env, sessionHeader);
      const rlKey = rateSubject(session, ip);

      // ── Remote configuration (GET; kill switches / flags / maintenance) ──
      if (request.method === "GET" && url.pathname === "/configuration") {
        route = "configuration";
        return done(await handleConfiguration(request, env, ctx));
      }

      // ── Curated content proxy (GET; edge-cached, ETag/304) ──
      if (request.method === "GET" && url.pathname === "/content/recipes") {
        route = "contentRecipes";
        return done(await handleContentRecipes(request, env, ctx, requestId));
      }
      if (request.method === "GET" && url.pathname.startsWith("/content/img/")) {
        route = "contentImage";
        return done(await handleContentImage(request, env, ctx, requestId, url.pathname));
      }

      // ── Ops metrics rollup (GET; shared-key gated like everything else) ──
      if (request.method === "GET" && url.pathname === "/metrics/today") {
        route = "metricsToday";
        return done(await handleMetricsToday(env, requestId));
      }

      // ── Session issuance (Apple / guest) ──
      if (request.method === "POST" && url.pathname === "/session/apple") {
        route = "sessionApple";
        const b = await request.json().catch(() => ({}));
        const v = await verifyAppleIdentityToken(b.identityToken || "", env.APPLE_BUNDLE_ID);
        if (!v.ok) { status = 401; return errJson(401, "Apple token invalid", { code: "unauthorized", requestId, extra: { reason: v.reason } }); }
        const token = await issueSession(env, { sub: v.sub, guest: false, ttlSeconds: 3600 });
        return json({ session: token, expiresIn: 3600 }, 200, NO_STORE);
      }
      if (request.method === "POST" && url.pathname === "/session/guest") {
        route = "sessionGuest";
        const token = await issueSession(env, { sub: "guest", guest: true, ttlSeconds: 3600 });
        return json({ session: token, expiresIn: 3600, guest: true }, 200, NO_STORE);
      }

      // ── Household (Durable Object) ──
      if (url.pathname.startsWith("/household")) {
        route = "household";
        if (!env.HOUSEHOLD_DO) { status = 500; return errJson(500, "Server misconfigured (no HOUSEHOLD_DO)", { code: "internalError", requestId }); }
        // Only WRITES are rate-limited (matching the original worker). The app polls
        // pull/presence every ~6s — throttling reads stalls sync and surfaces as
        // "Too many requests". The DO serializes writes and has its own protection.
        if (url.pathname === "/household/push") {
          if (await isLimited(limiterFor(env, "household"), rlKey, "hh")) {
            status = 429; return errJson(429, "Too many changes; slow down", { code: "rateLimited", requestId });
          }
        }
        return done(await handleHousehold(url.pathname, request, env, requestId));
      }

      // ── Crowd DB ──
      if (url.pathname.startsWith("/crowd")) {
        route = "crowd";
        if (!env.CROWD) { status = 500; return errJson(500, "Server misconfigured (no CROWD KV)", { code: "internalError", requestId }); }
        if (await isLimited(limiterFor(env, "crowd"), rlKey, "crowd")) {
          status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId });
        }
        return done(await handleCrowd(url, request, env, ctx, requestId));
      }

      // Everything below is POST-only.
      if (request.method !== "POST") { status = 405; return errJson(405, "Method not allowed", { code: "methodNotAllowed", requestId }); }

      // ── Non-AI new endpoints ──
      if (url.pathname === "/recipes/discover") {
        route = "discover";
        if (await isLimited(limiterFor(env, "default"), rlKey, "disc")) { status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId }); }
        return done(await handleDiscover(request, env, ctx));
      }
      if (url.pathname === "/daily-brief/context") {
        route = "dailyBriefContext";
        if (await isLimited(limiterFor(env, "default"), ip, "briefctx")) { status = 429; return json({ error: "Rate limit exceeded", code: "rateLimited" }, 429); }
        return await handleBriefContext(request, env, ctx);
      }
      if (url.pathname === "/daily-brief/generate") {
        route = "dailyBrief";
        if (await isLimited(limiterFor(env, "default"), rlKey, "brief")) { status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId }); }
        return done(await handleDailyBrief(request, env, ctx, requestId));
      }
      if (url.pathname === "/barcodes/resolve") {
        route = "barcodeResolve";
        if (await isLimited(limiterFor(env, "default"), rlKey, "barc")) { status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId }); }
        return done(await handleBarcodeResolve(request, env, ctx, requestId));
      }
      // ── QA report bridge (companion app <-> main app App Health) ──
      // Sits after the blanket sharedKeyOK gate above, so these are key-gated
      // without a second check that could drift from the first.
      if (url.pathname === "/qa/reports" || url.pathname === "/qa/reports/latest") {
        route = "qaReports";
        const qa = await handleQARoute(url, request, env, requestId);
        if (qa) return done(qa);
      }

      if (url.pathname === "/support/diagnostics") {
        route = "diagnostics";
        return done(await handleDiagnostics(request, env, ctx, requestId));
      }
      if (url.pathname === "/prices/compare") {
        route = "priceCompare";
        if (await isLimited(limiterFor(env, "default"), rlKey, "price")) { status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId }); }
        return done(await handlePricesCompare(request, env, ctx, requestId));
      }

      // ── Consolidated feature routes (the "20 more" — proxy keys, recipe fetch, content
      //     packs, stores, nutrition, invite, price watch, backup, media, analytics,
      //     substitutions, AASA, realtime/push scaffolds). Returns null if not a feature. ──
      {
        const feat = await handleFeatureRoute(url, request, env, ctx, requestId);
        if (feat) { route = "feature"; return done(feat); }
      }

      // ── Smart culinary intelligence (units, scaling, pantry match, grocery optimize,
      //     nutrition, expiry, seasonality, meal plan, temperature, experiments…) ──
      {
        const s = await handleSmartRoute(url, request, env, ctx, requestId);
        if (s) { route = "smart"; return done(s); }
      }

      // ── Body read for AI routes ──
      const lenHeader = parseInt(request.headers.get("Content-Length") || "0", 10);
      if (lenHeader && lenHeader > MAX_BODY_BYTES) { status = 413; return errJson(413, "Payload too large", { code: "payloadTooLarge", requestId }); }
      let payload;
      try {
        const raw = await request.text();
        if (raw.length > MAX_BODY_BYTES) { status = 413; return errJson(413, "Payload too large", { code: "payloadTooLarge", requestId }); }
        payload = JSON.parse(raw);
      } catch { status = 400; return errJson(400, "Invalid JSON", { code: "invalidInput", requestId }); }

      // Resolve which prompt to build: new pathname endpoint, or legacy payload sniff.
      const pathRoute = PATH_ROUTES[url.pathname];
      const prompt = pathRoute ? buildRoutePrompt(pathRoute, payload) : buildLegacyPrompt(payload);
      if (!prompt) { status = 422; return errJson(422, "Unrecognized request", { code: "invalidInput", requestId }); }
      route = prompt.route;

      // Input validation with stable error codes (#7). Legacy routes are validated
      // against their known field schema; new routes rely on output validation.
      const vin = validateInput(prompt.route, payload);
      if (!vin.ok) { status = 422; return errJson(422, "Validation failed", { code: "invalidInput", requestId, extra: { errors: vin.errors } }); }

      // Route class → rate limiter.
      const kind = (prompt.route === "receiptImage" || prompt.route === "receiptText") ? "receipt" : "ai";
      if (await isLimited(limiterFor(env, kind), rlKey, kind)) { status = 429; return errJson(429, "Rate limit exceeded", { code: "rateLimited", requestId }); }

      // Per-user daily AI quota (#7; no-op until FEATURES_KV is bound).
      { const quota = await checkAiQuota(env, request.headers.get("X-Stocked-Session") || rlKey);
        if (!quota.ok) { status = 429; return errJson(429, "Daily AI limit reached", { code: "quotaExceeded", requestId, retryAfter: 3600 }); } }

      // App Attest gate for expensive routes (opt-in; no-op until enabled).
      if (EXPENSIVE_ROUTES.has(prompt.route)) {
        const att = await verifyAttestation(env, {
          keyId: request.headers.get("X-Stocked-Attest-Key") || "",
          assertion: request.headers.get("X-Stocked-Attest") || "",
          clientDataHash: request.headers.get("X-Stocked-Attest-Hash") || "",
          deviceKeyJwk: payload.__attestKey || null,
        });
        if (!att.ok) { status = 403; return errJson(403, "Attestation required", { code: "attestationFailed", requestId, extra: { reason: att.reason } }); }
      }
      delete payload.__attestKey;

      if (!env.ANTHROPIC_API_KEY) { status = 500; return errJson(500, "Worker is missing ANTHROPIC_API_KEY", { code: "internalError", requestId }); }

      // Edge cache for deterministic passthrough routes.
      const cacheKey = prompt.cacheKey ? aiResultURL(`${prompt.cacheKey}:${WORKER_VERSION}`) : null;
      if (cacheKey) { const hit = await caches.default.match(cacheKey); if (hit) return withCors(hit); }

      // Runtime config (#9): model + per-route max_tokens are KV-tunable
      // (config:current → aiModel / aiLimits) with the Haiku fallback preserved.
      const cfg = await getRuntimeConfig(env);
      const models = [resolveModel(cfg, env.ANTHROPIC_MODEL, DEFAULT_MODEL), FALLBACK_MODEL];
      const maxTokens = resolveMaxTokens(cfg, prompt.route, prompt.maxTokens);

      // Validated routes: parse+validate+repair, then hand the app clean JSON in content[0].text.
      if (prompt.validated) {
        const r = await runValidatedRoute({
          env, route: prompt.route, schemaVersion: prompt.schemaVersion, models,
          system: prompt.system, user: prompt.user, maxTokens, promptCache: true, requestId,
        });
        if (!r.ok) { status = 502; return errJson(502, "Assistant output invalid", { code: r.code || "upstreamError", requestId, extra: { errors: r.errors } }); }
        const envelope = {
          content: [{ type: "text", text: JSON.stringify(r.value) }],
          schemaVersion: prompt.schemaVersion, route: prompt.route, workerVersion: WORKER_VERSION,
          model: r.model, repaired: !!r.repaired, requestId,
        };
        logEvent({ requestId, route: prompt.route, status: 200, ms: Date.now() - started, model: r.model, repaired: !!r.repaired });
        return json(envelope, 200);
      }

      // Passthrough routes: return the Anthropic envelope unchanged (+ our fields).
      const res = await callAnthropicResilient({ env, models, system: prompt.system, user: prompt.user, maxTokens, promptCache: true, requestId });
      if (!res.ok) { status = 502; return errJson(502, "Assistant upstream error", { code: "upstreamError", requestId, extra: { upstreamStatus: res.status } }); }
      let envelope;
      try { envelope = JSON.parse(res.text); } catch { status = 502; return errJson(502, "Assistant returned invalid JSON envelope", { code: "upstreamError", requestId }); }
      envelope.schemaVersion = prompt.schemaVersion;
      envelope.route = prompt.route;
      envelope.workerVersion = WORKER_VERSION;
      envelope.requestId = requestId;
      const response = json(envelope, 200, prompt.cacheTTL ? { "Cache-Control": `max-age=${prompt.cacheTTL}` } : {});
      if (cacheKey && prompt.cacheTTL) background(ctx, caches.default.put(cacheKey, response.clone()));
      logEvent({ requestId, route: prompt.route, status: 200, ms: Date.now() - started, model: res.model });
      return response;
    } catch (e) {
      status = 500;
      logEvent({ requestId, route, event: "workerCrash", error: String((e && e.message) || e) });
      return errJson(500, "Worker threw: " + String((e && e.message) || e), { code: "workerCrash", requestId });
    } finally {
      if (route !== "unknown") logEvent({ requestId, route, status, ms: Date.now() - started, phase: "end" });
      recordMetrics(env, ctx, route, status);   // sampled, deferred, never throws
    }
  },

  // Cron Triggers → enqueue daily briefs.
  async scheduled(event, env, ctx) {
    ctx.waitUntil(handleScheduledBriefs(event, env, ctx));
  },

  // Queues consumer → generate/deliver briefs with retries + dead-letter.
  async queue(batch, env, ctx) {
    await handleBriefQueue(batch, env, ctx);
  },
};
