// src/qa.js
// ─────────────────────────────────────────────────────────────────────────────
// QA report bridge (/qa/reports*) — the two-way channel between the Stocked QA
// companion app and the main Stocked app's App Health screen.
//
// Both sides POST the same `stocked-qa-report/v1` envelope and GET the other
// side's latest. That is the whole feature: a shared mailbox with two slots.
//
// GATING: these routes sit AFTER index.js's blanket `sharedKeyOK` gate, so the
// X-Stocked-Key check the spec requires is already applied before anything here
// runs. No new secret, and no second key check to drift out of sync with the
// first one.
//
// STORAGE: KV, preferring a dedicated `QA_KV` binding when one exists and
// falling back to `CROWD` when it does not. That is the same graceful-degrade
// pattern the optional bindings in wrangler.toml already use, so the routes
// work the moment they deploy with zero infrastructure changes, and can be
// moved onto their own namespace later by binding QA_KV and redeploying.
// Everything is written under a `qa:` prefix, which cannot collide with
// crowd.js's `item:` / `pair:` / `popular` keys.
// ─────────────────────────────────────────────────────────────────────────────

import { json, errJson, readBoundedJSON } from "./util.js";

const SCHEMA = "stocked-qa-report/v1";
const SOURCES = Object.freeze(["stocked-qa", "stocked-app"]);
const MAX_BYTES = 256 * 1024;         // 256 KB, per spec
const REPORT_TTL = 60 * 60 * 24 * 30; // 30 days
const LIST_DEFAULT = 10;
const LIST_MAX = 50;

/** The KV namespace to use, or null when none is bound. */
function store(env) {
  return env.QA_KV || env.CROWD || null;
}

const latestKey = (source) => `qa:latest:${source}`;
const reportKey = (source, generatedAt) => `qa:report:${source}:${generatedAt}`;

/**
 * Validate the envelope. Returns null when valid, or a short reason string.
 * Deliberately permissive about the OPTIONAL members (suites, checklists,
 * health): the two apps ship independently and one adding a field must never
 * 400 against a worker that has not heard of it yet.
 */
function invalidReason(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "body must be a JSON object";
  if (body.schema !== SCHEMA) return `schema must be ${SCHEMA}`;
  if (!SOURCES.includes(body.source)) return `source must be one of ${SOURCES.join(", ")}`;
  if (body.generatedAt !== undefined && typeof body.generatedAt !== "string") {
    return "generatedAt must be an ISO string when present";
  }
  return null;
}

/** ISO timestamp for keying. Falls back to now when the client omits it. */
function stampOf(body) {
  const raw = typeof body.generatedAt === "string" ? body.generatedAt.trim() : "";
  if (raw) {
    const t = Date.parse(raw);
    if (!Number.isNaN(t)) return new Date(t).toISOString();
  }
  return new Date().toISOString();
}

// ── POST /qa/reports ─────────────────────────────────────────────────────────

async function postReport(request, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const read = await readBoundedJSON(request, MAX_BYTES);
  if (!read.ok) {
    // readBoundedJSON returns its own code ("payloadTooLarge"); the companion
    // app's suite asserts the spec's `report_too_large` for oversize bodies, so
    // map that one case and pass everything else through unchanged.
    const code = read.status === 413 ? "report_too_large" : read.code;
    return errJson(read.status, read.message, { code, requestId });
  }

  const body = read.value;
  const reason = invalidReason(body);
  if (reason) return errJson(400, reason, { code: "bad_report", requestId });

  const source = body.source;
  const generatedAt = stampOf(body);
  // Stamp arrival server-side so a client with a wrong clock is still orderable
  // against other reports, without discarding what the client claimed.
  const stored = { ...body, generatedAt, receivedAt: Date.now() };
  const payload = JSON.stringify(stored);

  await Promise.all([
    kv.put(latestKey(source), payload),
    kv.put(reportKey(source, generatedAt), payload, { expirationTtl: REPORT_TTL }),
  ]);

  return json({ ok: true, id: `${source}:${generatedAt}` }, 201);
}

// ── GET /qa/reports/latest ───────────────────────────────────────────────────

async function getLatest(url, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const requested = (url.searchParams.get("source") || "").trim();
  if (requested && !SOURCES.includes(requested)) {
    return errJson(400, `source must be one of ${SOURCES.join(", ")}`, {
      code: "bad_report", requestId,
    });
  }

  const wanted = requested ? [requested] : SOURCES;
  const raws = await Promise.all(wanted.map((s) => kv.get(latestKey(s))));

  let best = null;
  let bestAt = -Infinity;
  for (const raw of raws) {
    if (!raw) continue;
    let parsed;
    try { parsed = JSON.parse(raw); } catch { continue; }
    // Order by receivedAt when present (server clock, trustworthy), else by the
    // client's generatedAt.
    const at = Number.isFinite(parsed.receivedAt)
      ? parsed.receivedAt
      : Date.parse(parsed.generatedAt || "") || 0;
    if (at >= bestAt) { bestAt = at; best = parsed; }
  }

  if (!best) {
    // EXACT code `no_reports`, per spec: the companion app uses it to tell
    // "bridge live but empty" apart from the router's generic 404, which is how
    // it decides whether the routes are deployed at all. Do not change this
    // string without changing the app.
    return errJson(404, "No QA reports stored yet", { code: "no_reports", requestId });
  }
  return json(best, 200);
}

// ── GET /qa/reports?source=&limit= ───────────────────────────────────────────

async function listReports(url, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const requested = (url.searchParams.get("source") || "").trim();
  if (requested && !SOURCES.includes(requested)) {
    return errJson(400, `source must be one of ${SOURCES.join(", ")}`, {
      code: "bad_report", requestId,
    });
  }

  const raw = parseInt(url.searchParams.get("limit") || "", 10);
  const limit = Number.isFinite(raw) && raw > 0 ? Math.min(raw, LIST_MAX) : LIST_DEFAULT;

  const prefixes = requested ? [`qa:report:${requested}:`] : SOURCES.map((s) => `qa:report:${s}:`);
  const listings = await Promise.all(prefixes.map((p) => kv.list({ prefix: p, limit: LIST_MAX })));

  const reports = [];
  for (const listing of listings) {
    for (const k of listing.keys || []) {
      // key shape: qa:report:<source>:<ISO>  — the ISO itself contains colons,
      // so split off the fixed first three segments and rejoin the rest.
      const parts = k.name.split(":");
      if (parts.length < 4) continue;
      const source = parts[2];
      const generatedAt = parts.slice(3).join(":");
      reports.push({ id: `${source}:${generatedAt}`, source, generatedAt });
    }
  }

  // Newest first. ISO-8601 sorts lexically, but parse anyway so a malformed
  // stamp sinks instead of landing at the top.
  reports.sort((a, b) => (Date.parse(b.generatedAt) || 0) - (Date.parse(a.generatedAt) || 0));

  return json({ ok: true, reports: reports.slice(0, limit) }, 200);
}

// ── Router ──────────────────────────────────────────────────────────────────

/**
 * Handle a /qa/* route. Returns a Response, or null when the path is not ours
 * so index.js can keep matching.
 */
export async function handleQARoute(url, request, env, requestId) {
  const p = url.pathname;
  const m = request.method;

  if (p === "/qa/reports/latest") {
    if (m !== "GET") return errJson(405, "Method not allowed", { code: "method_not_allowed", requestId });
    return getLatest(url, env, requestId);
  }

  if (p === "/qa/reports") {
    if (m === "POST") return postReport(request, env, requestId);
    if (m === "GET") return listReports(url, env, requestId);
    return errJson(405, "Method not allowed", { code: "method_not_allowed", requestId });
  }

  return null;
}
