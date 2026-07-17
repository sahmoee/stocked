// ai.js — the resilient Anthropic call path (#9) plus output validation (#8).
// Responsibilities:
//   • per-route timeout with AbortController
//   • circuit breaker: stop hammering an unhealthy model for a cooldown window
//   • model fallback: primary → cheaper fallback
//   • extract text, parse JSON, validate the ACTUAL route output
//   • one constrained repair attempt, else a clear invalidModelOutput error
//
// State (breaker counters) lives in the Cache API — no KV writes, same trick the
// rate limiter uses.

import { validateAIOutput } from "./validation.js";
import { logEvent } from "./util.js";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

const DEFAULT_TIMEOUT_MS = 25000;
const BREAKER_THRESHOLD = 4;      // consecutive-ish failures before opening
const BREAKER_COOLDOWN_S = 60;    // seconds a model stays "open" (skipped)

function breakerURL(model) { return "https://breaker.internal/" + encodeURIComponent(model); }

async function breakerFailures(model) {
  try {
    const hit = await caches.default.match(breakerURL(model));
    if (!hit) return 0;
    const n = parseInt(await hit.text(), 10);
    return Number.isFinite(n) ? n : 0;
  } catch { return 0; }
}
async function breakerRecord(model, failed) {
  try {
    if (!failed) { await caches.default.delete(breakerURL(model)); return; }
    const cur = await breakerFailures(model);
    const resp = new Response(String(cur + 1), {
      headers: { "Cache-Control": "max-age=" + BREAKER_COOLDOWN_S, "Content-Type": "text/plain" },
    });
    await caches.default.put(breakerURL(model), resp);
  } catch { /* breaker is best-effort */ }
}
async function breakerOpen(model) { return (await breakerFailures(model)) >= BREAKER_THRESHOLD; }

/**
 * Prompt caching (#9): the system prompts are static per route and shared by
 * every user, so marking them with cache_control lets Anthropic cache the
 * prefix across the high-volume routes. Prompts below the model's minimum
 * cacheable length are simply processed uncached — the marker is harmless.
 * Pure (tested).
 */
export function systemBlocksFor(system, promptCache) {
  if (!promptCache || typeof system !== "string" || !system) return system;
  return [{ type: "text", text: system, cache_control: { type: "ephemeral" } }];
}

/** One raw Anthropic call with a hard timeout. Returns { ok, status, text }. */
async function callOnce({ apiKey, model, system, user, maxTokens, timeoutMs, promptCache, requestId }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs || DEFAULT_TIMEOUT_MS);
  try {
    const upstream = await fetch(ANTHROPIC_URL, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model,
        max_tokens: maxTokens || 1500,
        system: systemBlocksFor(system, promptCache),
        messages: [{ role: "user", content: user }],
      }),
    });
    const text = await upstream.text();
    return { ok: upstream.ok, status: upstream.status, text };
  } catch (e) {
    const aborted = e && (e.name === "AbortError");
    return { ok: false, status: aborted ? 504 : 502, text: "", aborted: !!aborted };
  } finally {
    clearTimeout(timer);
  }
}

/** Pull the assistant text out of an Anthropic messages envelope. */
export function extractText(envelopeText) {
  try {
    const env = JSON.parse(envelopeText);
    if (Array.isArray(env.content)) {
      const block = env.content.find((b) => b && b.type === "text");
      return block ? block.text : "";
    }
  } catch { /* fallthrough */ }
  return "";
}

/** Parse possibly-fenced JSON out of model text. */
export function parseModelJSON(text) {
  if (typeof text !== "string") return null;
  let t = text.trim();
  if (t.startsWith("```")) t = t.replace(/^```[a-zA-Z]*\n?/, "").replace(/```$/, "").trim();
  const first = t.indexOf("{"), firstArr = t.indexOf("[");
  const start = (firstArr !== -1 && (firstArr < first || first === -1)) ? firstArr : first;
  if (start > 0) t = t.slice(start);
  try { return JSON.parse(t); } catch { return null; }
}

/**
 * Resilient call with fallback + breaker. Returns the RAW Anthropic envelope text
 * (so passthrough routes keep working), plus which model answered.
 * models: [primary, fallback?]. Skips a model whose breaker is open.
 */
export async function callAnthropicResilient({ env, models, system, user, maxTokens, timeoutMs, promptCache, requestId }) {
  const apiKey = env.ANTHROPIC_API_KEY;
  let lastStatus = 502;
  for (const model of models.filter(Boolean)) {
    if (await breakerOpen(model)) { logEvent({ requestId, event: "breakerSkip", model }); continue; }
    const res = await callOnce({ apiKey, model, system, user, maxTokens, timeoutMs, promptCache, requestId });
    if (res.ok) {
      await breakerRecord(model, false);
      return { ok: true, text: res.text, model };
    }
    lastStatus = res.status;
    // 5xx / timeout counts against the breaker; 4xx (bad request/key) does not — retrying won't help.
    await breakerRecord(model, res.status >= 500);
    logEvent({ requestId, event: "upstreamFail", model, status: res.status, aborted: !!res.aborted });
    if (res.status >= 400 && res.status < 500) break; // don't fall back on a client-side error
  }
  return { ok: false, status: lastStatus };
}

/**
 * Full structured-route runner: call → extract → parse → validate → (repair once)
 * → return validated object. Use for routes with a strict schema. `passthrough`
 * routes (receipt/recipe text passthrough) should use callAnthropicResilient directly.
 */
export async function runValidatedRoute({ env, route, schemaVersion, models, system, user, maxTokens, timeoutMs, promptCache, requestId }) {
  const first = await callAnthropicResilient({ env, models, system, user, maxTokens, timeoutMs, promptCache, requestId });
  if (!first.ok) return { ok: false, status: first.status, code: "upstreamError" };

  let parsed = parseModelJSON(extractText(first.text));
  let check = validateAIOutput(route, parsed, schemaVersion);
  if (check.ok) return { ok: true, value: check.value, model: first.model };

  // One constrained repair attempt: hand the model its own output + the errors.
  logEvent({ requestId, event: "outputInvalid", route, errors: check.errors.map((e) => e.code) });
  const repairUser =
    "Your previous response did not satisfy the required schema. " +
    "Return ONLY corrected JSON (no prose, no fences). Problems: " +
    JSON.stringify(check.errors) + "\n\nYour previous output:\n" + extractText(first.text);
  const repair = await callAnthropicResilient({
    env, models, system, user: repairUser, maxTokens, timeoutMs, promptCache, requestId,
  });
  if (repair.ok) {
    parsed = parseModelJSON(extractText(repair.text));
    check = validateAIOutput(route, parsed, schemaVersion);
    if (check.ok) return { ok: true, value: check.value, model: repair.model, repaired: true };
  }
  return { ok: false, status: 502, code: "invalidModelOutput", errors: check.errors };
}
