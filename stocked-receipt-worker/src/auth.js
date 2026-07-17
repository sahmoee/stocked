// auth.js — layered auth (improvement #3).
//
// Model:
//   1. Sign in with Apple → verify Apple's identity JWT (JWKS + RS256).
//   2. Issue a SHORT-LIVED HMAC session token the app sends as X-Stocked-Session.
//      This replaces relying on the static X-Stocked-Key (which ships in the app
//      and can be extracted). The shared key remains a coarse first gate.
//   3. App Attest / DeviceCheck hook for expensive AI routes (verifyAttestation).
//   4. A restricted GUEST session for users who haven't signed in.
//
// The shared-secret check stays as a cheap outer filter; session tokens are the
// real per-user credential and expire quickly.

import { timingSafeEqual, sha256Hex } from "./util.js";

// ── base64url ────────────────────────────────────────────────────────────────
function b64urlEncode(bytes) {
  let bin = "";
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(str) {
  const pad = str.length % 4 ? "=".repeat(4 - (str.length % 4)) : "";
  const bin = atob(str.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function utf8(str) { return new TextEncoder().encode(str); }
function decodeJSONSegment(seg) { return JSON.parse(new TextDecoder().decode(b64urlToBytes(seg))); }

// ── Apple JWKS (cached in the Cache API) ─────────────────────────────────────
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const JWKS_CACHE_URL = "https://jwks.internal/apple";

async function appleJWKS() {
  try {
    const hit = await caches.default.match(JWKS_CACHE_URL);
    if (hit) return await hit.json();
  } catch {}
  const res = await fetch(APPLE_KEYS_URL);
  if (!res.ok) throw new Error("jwks fetch failed");
  const jwks = await res.json();
  try {
    await caches.default.put(JWKS_CACHE_URL, new Response(JSON.stringify(jwks), {
      headers: { "Cache-Control": "max-age=86400", "Content-Type": "application/json" },
    }));
  } catch {}
  return jwks;
}

/**
 * Verify a Sign in with Apple identity token. Returns { ok, sub, email } or { ok:false }.
 * `expectedAudience` is your app's bundle id (env.APPLE_BUNDLE_ID).
 */
export async function verifyAppleIdentityToken(idToken, expectedAudience) {
  try {
    const [h, p, s] = idToken.split(".");
    if (!h || !p || !s) return { ok: false, reason: "malformed" };
    const header = decodeJSONSegment(h);
    const payload = decodeJSONSegment(p);
    if (payload.iss !== "https://appleid.apple.com") return { ok: false, reason: "iss" };
    if (expectedAudience && payload.aud !== expectedAudience) return { ok: false, reason: "aud" };
    if (typeof payload.exp === "number" && payload.exp * 1000 < Date.now()) return { ok: false, reason: "expired" };

    const jwks = await appleJWKS();
    const jwk = (jwks.keys || []).find((k) => k.kid === header.kid && k.alg === (header.alg || "RS256"));
    if (!jwk) return { ok: false, reason: "kid" };
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64urlToBytes(s), utf8(`${h}.${p}`));
    if (!ok) return { ok: false, reason: "signature" };
    return { ok: true, sub: payload.sub, email: payload.email || null };
  } catch (e) {
    return { ok: false, reason: String((e && e.message) || e) };
  }
}

// ── Short-lived HMAC session tokens ──────────────────────────────────────────
async function hmacKey(secret) {
  return crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

/** Issue a session token. ttlSeconds default 1h; guest tokens are restricted. */
export async function issueSession(env, { sub, guest = false, ttlSeconds = 3600 }) {
  const secret = env.SESSION_SIGNING_KEY;
  if (!secret) throw new Error("SESSION_SIGNING_KEY not set");
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = { sub: sub || "guest", guest: !!guest, iat: now, exp: now + ttlSeconds };
  const unsigned = `${b64urlEncode(utf8(JSON.stringify(header)))}.${b64urlEncode(utf8(JSON.stringify(payload)))}`;
  const key = await hmacKey(secret);
  const sig = await crypto.subtle.sign("HMAC", key, utf8(unsigned));
  return `${unsigned}.${b64urlEncode(sig)}`;
}

/** Verify a session token. Returns { ok, sub, guest } or { ok:false }. */
export async function verifySession(env, token) {
  try {
    const secret = env.SESSION_SIGNING_KEY;
    if (!secret || !token) return { ok: false };
    const [h, p, s] = token.split(".");
    if (!h || !p || !s) return { ok: false };
    const key = await hmacKey(secret);
    const ok = await crypto.subtle.verify("HMAC", key, b64urlToBytes(s), utf8(`${h}.${p}`));
    if (!ok) return { ok: false };
    const payload = decodeJSONSegment(p);
    if (typeof payload.exp === "number" && payload.exp * 1000 < Date.now()) return { ok: false, reason: "expired" };
    return { ok: true, sub: payload.sub, guest: !!payload.guest };
  } catch { return { ok: false }; }
}

/**
 * App Attest / DeviceCheck gate for expensive routes.
 *
 * Full App Attest attestation validation (CBOR attestation object → X.509 chain
 * to Apple's App Attest root → nonce/keyId checks, then per-call assertion
 * signature verification) requires your Apple team id + app id and careful
 * review — see MANUAL_STEPS.md §Auth. This function verifies the ASSERTION
 * signature path when an attested public key has been registered for the device;
 * until you enable it, expensive routes still require a valid Apple-derived
 * session token, which already removes the static-key weakness.
 */
export async function verifyAttestation(env, { keyId, assertion, clientDataHash, deviceKeyJwk }) {
  if (!env.APP_ATTEST_ENABLED) return { ok: true, skipped: true }; // opt-in; off until configured
  try {
    if (!deviceKeyJwk || !assertion || !clientDataHash) return { ok: false, reason: "missingAttestation" };
    const key = await crypto.subtle.importKey("jwk", deviceKeyJwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key,
      b64urlToBytes(assertion), b64urlToBytes(clientDataHash));
    return { ok, reason: ok ? undefined : "assertion" };
  } catch (e) {
    return { ok: false, reason: String((e && e.message) || e) };
  }
}

/** Coarse outer gate: the shared key still ships as a first filter. */
export function sharedKeyOK(request, env) {
  const provided = request.headers.get("X-Stocked-Key") || "";
  return !!env.STOCKED_SHARED_KEY && timingSafeEqual(provided, env.STOCKED_SHARED_KEY);
}

/** Hash an invite token before storing it (never store the raw token). */
export async function hashInvite(token) { return sha256Hex(token); }
