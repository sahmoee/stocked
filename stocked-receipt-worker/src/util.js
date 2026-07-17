// util.js — shared primitives: responses, CORS, auth compare, crypto codes,
// request IDs, and structured logging. No route logic lives here.

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, If-None-Match, X-Stocked-Key, X-Stocked-Session, X-Stocked-Attest",
};

// Standard security headers on every JSON response (hardening sweep). The API is
// non-credentialed ("*" CORS, no cookies), so these are safe and additive.
export const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

/**
 * Centralized CORS policy. With no allowlist configured (CORS_ALLOW_ORIGINS
 * unset/empty) we keep today's behavior: "*" for the non-credentialed API.
 * With an allowlist, we echo the request Origin ONLY when it is listed.
 */
export function corsHeadersFor(requestOrigin, allowlist) {
  const list = String(allowlist || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!list.length) return { ...CORS_HEADERS };
  const h = { ...CORS_HEADERS };
  if (requestOrigin && list.includes(requestOrigin)) {
    h["Access-Control-Allow-Origin"] = requestOrigin;
    h["Vary"] = "Origin";
  } else {
    delete h["Access-Control-Allow-Origin"];
  }
  return h;
}

export function json(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS, ...SECURITY_HEADERS, ...extraHeaders },
  });
}

// ── Consistent error envelope ────────────────────────────────────────────────
// Every non-2xx JSON body carries { error, code, requestId }. `codeForStatus`
// supplies a stable default code per status; callers may override.
const STATUS_CODE_MAP = Object.freeze({
  400: "invalidInput", 401: "unauthorized", 403: "forbidden", 404: "notFound",
  405: "methodNotAllowed", 409: "conflict", 413: "payloadTooLarge",
  422: "invalidInput", 429: "rateLimited", 500: "internalError",
  502: "upstreamError", 503: "unavailable", 504: "upstreamTimeout",
});
export function codeForStatus(status) {
  return STATUS_CODE_MAP[status] || (status >= 500 ? "upstreamError" : "requestFailed");
}

/**
 * Build a non-2xx JSON error response with the consistent envelope. Every 429
 * automatically carries a Retry-After header (seconds).
 */
export function errJson(status, message, { code, requestId, retryAfter, extra } = {}) {
  const headers = {};
  if (status === 429) headers["Retry-After"] = String(retryAfter || 30);
  const body = { error: message, code: code || codeForStatus(status), ...(extra || {}) };
  if (requestId) body.requestId = requestId;
  return json(body, status, headers);
}

/**
 * Read + JSON-parse a request body with a hard byte budget (hardening sweep:
 * non-AI POST endpoints get bounded bodies too). Returns
 * { ok:true, value, bytes } or { ok:false, status, code, message }.
 */
export async function readBoundedJSON(request, maxBytes) {
  const lenHeader = parseInt(request.headers.get("Content-Length") || "0", 10);
  if (lenHeader && lenHeader > maxBytes) return { ok: false, status: 413, code: "payloadTooLarge", message: "Payload too large" };
  let raw;
  try { raw = await request.text(); } catch { return { ok: false, status: 400, code: "invalidInput", message: "Unreadable body" }; }
  if (raw.length > maxBytes) return { ok: false, status: 413, code: "payloadTooLarge", message: "Payload too large" };
  try { return { ok: true, value: JSON.parse(raw), bytes: raw.length }; }
  catch { return { ok: false, status: 400, code: "invalidInput", message: "Invalid JSON" }; }
}

// ── ETag helpers (conditional GETs on /configuration and /content/*) ─────────
/** Strong ETag from a response body (SHA-256, quoted). Stable per byte-identical body. */
export async function strongETag(text) {
  return `"${(await sha256Hex(text)).slice(0, 32)}"`;
}

/** RFC 7232 If-None-Match check against a strong ETag (weak prefixes tolerated). */
export function etagMatches(ifNoneMatch, etag) {
  if (!ifNoneMatch || !etag) return false;
  const wanted = String(etag).replace(/^W\//, "");
  const values = String(ifNoneMatch).split(",").map((s) => s.trim());
  return values.includes("*") || values.some((v) => v.replace(/^W\//, "") === wanted);
}

export function withCors(response) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) headers.set(k, v);
  return new Response(response.body, { status: response.status, headers });
}

/** Constant-time string comparison so a wrong X-Stocked-Key can't be timing-probed. */
export function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

// ── Crypto-secure household codes (improvement #4) ────────────────────────────
// Uses Web Crypto (getRandomValues) rather than the predictable JS PRNG: invite
// codes must be unguessable so a third party can't enumerate a code to join a
// household. Rejection sampling keeps the alphabet perfectly uniform (no bias).
const HH_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 32 chars, no ambiguous 0/O/1/I
export function makeHouseholdCode(len = 8) {
  const n = HH_CODE_ALPHABET.length;            // 32 → a byte covers 8 codes exactly (256/32)
  const max = Math.floor(256 / n) * n;          // largest multiple of n ≤ 256 (256 here)
  let out = "";
  const buf = new Uint8Array(len * 2);
  while (out.length < len) {
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && out.length < len; i++) {
      if (buf[i] < max) out += HH_CODE_ALPHABET[buf[i] % n];
    }
  }
  return out;
}

/** A random hex token for hashed invitation tokens / session ids. */
export function randomToken(bytes = 16) {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return [...buf].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** SHA-256 hex of a string (for storing hashed invite tokens, never the raw value). */
export async function sha256Hex(input) {
  const data = new TextEncoder().encode(String(input));
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Short correlation id assigned per request; echoed in logs and error bodies. */
export function makeRequestId() {
  return randomToken(8);
}

// ── Structured, privacy-safe logging (improvement #10) ────────────────────────
// One JSON line per request. Never logs request bodies, secrets, PII, or model
// text — only shape/metadata fields. Cloudflare Workers Logs ingests these.
export function logEvent(fields) {
  try {
    console.log(JSON.stringify({ ts: Date.now(), ...fields }));
  } catch {
    // logging must never throw into the request path
  }
}

/** Run best-effort background work without blocking the response (improvement #6). */
export function background(ctx, promise) {
  try {
    if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(Promise.resolve(promise));
  } catch {
    // if the platform can't defer it, the work already started; swallow.
  }
}
