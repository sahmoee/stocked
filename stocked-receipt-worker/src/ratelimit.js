// ratelimit.js — rate limiting (improvement #2).
//
// Prefers Cloudflare's native Rate Limiting bindings, which are ATOMIC (no
// read-then-write race like the old Cache-API counter). Separate limiters for
// different cost classes. If a binding isn't configured yet, we fall back to the
// old Cache-API counter so the Worker keeps working during rollout.

// Best-effort safety net used only if a native binding is missing/errors. Kept
// generous so it never throttles legitimate traffic (e.g. household 6s polling).
const FALLBACK_PER_MINUTE = 120;

function counterURL(key) { return "https://rate-limit.internal/" + encodeURIComponent(key); }
async function cacheGet(key) {
  try { const h = await caches.default.match(counterURL(key)); return h ? (parseInt(await h.text(), 10) || 0) : 0; }
  catch { return 0; }
}
async function cacheBump(key, ttl) {
  try {
    const cur = await cacheGet(key);
    await caches.default.put(counterURL(key), new Response(String(cur + 1), {
      headers: { "Cache-Control": "max-age=" + ttl, "Content-Type": "text/plain" },
    }));
  } catch {}
}

/**
 * Check a named limiter. `binding` is the env key of a native rate-limit binding
 * (e.g. env.RL_AI). `key` scopes it (per-IP, per-household, per-user). Returns
 * true when the request is OVER the limit and should be rejected.
 */
export async function isLimited(binding, key, fallbackKeyPrefix) {
  if (binding && typeof binding.limit === "function") {
    try {
      const { success } = await binding.limit({ key: String(key) });
      return !success;
    } catch {
      // fall through to the cache fallback on binding error
    }
  }
  // Fallback: coarse per-minute cache counter (best-effort, non-atomic).
  const bucket = `${fallbackKeyPrefix || "rl"}:${key}:${Math.floor(Date.now() / 60000)}`;
  const count = await cacheGet(bucket);
  if (count >= FALLBACK_PER_MINUTE) return true;
  await cacheBump(bucket, 120);
  return false;
}

/**
 * Session-aware rate-limit subject (fairness behind NAT): a VALID, non-guest
 * X-Stocked-Session keys limits by its subject; otherwise fall back to the IP.
 * Guest sessions all share sub "guest", so they stay IP-keyed on purpose.
 * `session` is the result of auth.verifySession ({ ok, sub, guest }).
 */
export function rateSubject(session, ip) {
  if (session && session.ok && session.sub && !session.guest) return "s:" + session.sub;
  return "ip:" + (ip || "unknown");
}

/** Pick the right limiter binding for a route class. Names match wrangler.toml. */
export function limiterFor(env, kind) {
  switch (kind) {
    case "ai":        return env.RL_AI || null;
    case "receipt":   return env.RL_RECEIPT || null;
    case "household": return env.RL_HOUSEHOLD || null;
    case "crowd":     return env.RL_CROWD || null;
    default:          return env.RL_DEFAULT || null;
  }
}
