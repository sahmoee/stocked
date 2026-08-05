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

// ── Screenshots (Build 73) ───────────────────────────────────────────────────
// Pictures do not travel on the report envelope. MAX_BYTES exists to stop a
// runaway ticket batch from filling KV, and a screenshot is fifteen times the
// size of the text it illustrates — raising the cap enough to carry one would
// remove that protection from the text path too. So shots get their own route,
// their own cap and their own keys, and the envelope carries only a small
// base64 thumbnail so the App Health screen has something to show without a
// second fetch.
//
// 2 MB matches QAShotUploader.maxBytes in the app exactly. If you change one,
// change the other, or the app will spend a phone's battery uploading bytes
// this worker is about to reject.
const MAX_SHOT_BYTES = 2 * 1024 * 1024;
const SHOT_TTL = 60 * 60 * 24 * 30;   // 30 days, same as the report it belongs to
const SHOT_KINDS = Object.freeze(["screenshot", "mockup"]);

/** The KV namespace to use, or null when none is bound. */
function store(env) {
  return env.QA_KV || env.CROWD || null;
}

// SLOTS: the envelope carries an optional `kind`. An absent or unrecognised
// kind is a full App Health report and keeps the original key shapes, so every
// already-deployed client and every already-stored key behaves exactly as
// before. A recognised kind gets its OWN pair of slots.
//
// WHY (the July 2026 field export): the app pushes tickets on the same
// `stocked-qa-report/v1` envelope, because that is the only schema tag this
// worker accepts. Without a slot those slim ticket pushes landed on
// `qa:latest:stocked-app` and clobbered the last full report — the App Health
// screen would show a complete report, a ticket would sync seconds later, and
// the next GET would return an envelope with no suites, no checklists and no
// health block. Separating the slots means both survive.
const KINDS = Object.freeze(["tickets"]);

/** Normalised slot for an envelope: "" for a full report, else the kind. */
function kindOf(body) {
  const raw = typeof body.kind === "string" ? body.kind.trim().toLowerCase() : "";
  return KINDS.includes(raw) ? raw : "";
}

const latestKey = (source, kind = "") =>
  kind ? `qa:latest:${kind}:${source}` : `qa:latest:${source}`;
const reportKey = (source, generatedAt, kind = "") =>
  kind ? `qa:${kind}:${source}:${generatedAt}` : `qa:report:${source}:${generatedAt}`;

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
  const kind = kindOf(body);
  const generatedAt = stampOf(body);
  // Stamp arrival server-side so a client with a wrong clock is still orderable
  // against other reports, without discarding what the client claimed.
  const stored = { ...body, generatedAt, receivedAt: Date.now() };
  const payload = JSON.stringify(stored);

  await Promise.all([
    kv.put(latestKey(source, kind), payload),
    kv.put(reportKey(source, generatedAt, kind), payload, { expirationTtl: REPORT_TTL }),
  ]);

  return json({ ok: true, id: `${source}:${generatedAt}`, kind: kind || "report" }, 201);
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

  // Absent `kind` reads the full-report slot, which is what every existing
  // client asks for and what the spec's `/qa/reports/latest` has always meant.
  const kind = (url.searchParams.get("kind") || "").trim().toLowerCase();
  if (kind && !KINDS.includes(kind)) {
    return errJson(400, `kind must be one of ${KINDS.join(", ")}`, {
      code: "bad_report", requestId,
    });
  }

  const wanted = requested ? [requested] : SOURCES;
  const raws = await Promise.all(wanted.map((s) => kv.get(latestKey(s, kind))));

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

  const kind = (url.searchParams.get("kind") || "").trim().toLowerCase();
  if (kind && !KINDS.includes(kind)) {
    return errJson(400, `kind must be one of ${KINDS.join(", ")}`, {
      code: "bad_report", requestId,
    });
  }

  const raw = parseInt(url.searchParams.get("limit") || "", 10);
  const limit = Number.isFinite(raw) && raw > 0 ? Math.min(raw, LIST_MAX) : LIST_DEFAULT;

  // `reportKey(source, "", kind)` is exactly the prefix of every key in that
  // slot, so the listing and the writer can never disagree about key shape.
  const wantedSources = requested ? [requested] : SOURCES;
  const prefixes = wantedSources.map((s) => reportKey(s, "", kind));
  const listings = await Promise.all(prefixes.map((p) => kv.list({ prefix: p, limit: LIST_MAX })));

  const reports = [];
  for (const listing of listings) {
    for (const k of listing.keys || []) {
      // key shape: qa:<slot>:<source>:<ISO> — `report` for a full report, the
      // kind for anything else. The ISO itself contains colons, so split off
      // the fixed first three segments and rejoin the rest.
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

// ── POST /qa/shots?ticket=&kind=  ·  GET /qa/shots?ticket=&kind= ─────────────
//
// The body is a raw JPEG, not JSON, so readBoundedJSON is no use here and the
// size check has to be done by hand. Two guards, because either can be absent:
// Content-Length when the client sends it (cheap, rejects before transfer), and
// the actual byte count after the read (authoritative, catches a lying or
// chunked sender).

/** Ticket numbers key the shot, so keep them to the shape the app generates. */
function shotTicketOf(url, request) {
  const raw = (url.searchParams.get("ticket") || request.headers.get("X-QA-Ticket") || "").trim();
  // STK-73-0004 and friends. Anything with a colon would break the key shape
  // the listing below splits on, so restrict rather than escape.
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(raw)) return null;
  return raw;
}

function shotKindOf(url, request) {
  const raw = (url.searchParams.get("kind") || request.headers.get("X-QA-Kind") || "")
    .trim().toLowerCase();
  if (!raw) return "screenshot";
  return SHOT_KINDS.includes(raw) ? raw : null;
}

const shotKey = (ticket, kind) => `qa:shot:${ticket}:${kind}`;

async function postShot(url, request, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const ticket = shotTicketOf(url, request);
  if (!ticket) {
    return errJson(400, "ticket must be supplied as ?ticket= or X-QA-Ticket", {
      code: "bad_shot", requestId,
    });
  }

  const kind = shotKindOf(url, request);
  if (!kind) {
    return errJson(400, `kind must be one of ${SHOT_KINDS.join(", ")}`, {
      code: "bad_shot", requestId,
    });
  }

  const declared = parseInt(request.headers.get("Content-Length") || "", 10);
  if (Number.isFinite(declared) && declared > MAX_SHOT_BYTES) {
    return errJson(413, `Screenshot exceeds ${MAX_SHOT_BYTES} bytes`, {
      code: "shot_too_large", requestId,
    });
  }

  let bytes;
  try {
    bytes = await request.arrayBuffer();
  } catch {
    return errJson(400, "Could not read the image body", { code: "bad_shot", requestId });
  }

  if (!bytes || bytes.byteLength === 0) {
    return errJson(400, "Empty image body", { code: "bad_shot", requestId });
  }
  if (bytes.byteLength > MAX_SHOT_BYTES) {
    return errJson(413, `Screenshot exceeds ${MAX_SHOT_BYTES} bytes`, {
      code: "shot_too_large", requestId,
    });
  }

  const receivedAt = Date.now();
  await kv.put(shotKey(ticket, kind), bytes, {
    expirationTtl: SHOT_TTL,
    // Metadata rides along on kv.list, so the index below can report sizes and
    // dates without fetching (and paying for) every picture.
    metadata: { ticket, kind, bytes: bytes.byteLength, receivedAt },
  });

  return json({
    ok: true, ticket, kind, bytes: bytes.byteLength,
    receivedAt: new Date(receivedAt).toISOString(),
  }, 201);
}

async function getShot(url, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const ticket = (url.searchParams.get("ticket") || "").trim();
  if (!ticket) {
    // No ticket means "what have you got" — the index, not an error.
    return listShots(url, env, requestId);
  }
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(ticket)) {
    return errJson(400, "bad ticket", { code: "bad_shot", requestId });
  }

  const kindRaw = (url.searchParams.get("kind") || "screenshot").trim().toLowerCase();
  if (!SHOT_KINDS.includes(kindRaw)) {
    return errJson(400, `kind must be one of ${SHOT_KINDS.join(", ")}`, {
      code: "bad_shot", requestId,
    });
  }

  const { value, metadata } = await kv.getWithMetadata(shotKey(ticket, kindRaw), {
    type: "arrayBuffer",
  });
  if (!value) {
    return errJson(404, "No such screenshot", { code: "no_shot", requestId });
  }

  return new Response(value, {
    status: 200,
    headers: {
      "Content-Type": "image/jpeg",
      "Content-Length": String(value.byteLength),
      // Immutable for a day: a given ticket+kind is overwritten only when the
      // tester edits the report, and a stale picture for a few hours is a far
      // smaller problem than re-downloading every screenshot on every view.
      "Cache-Control": "private, max-age=86400",
      "X-QA-Ticket": ticket,
      "X-QA-Kind": kindRaw,
      "X-QA-Received": metadata && metadata.receivedAt
        ? new Date(metadata.receivedAt).toISOString() : "",
    },
  });
}

async function listShots(url, env, requestId) {
  const kv = store(env);
  if (!kv) {
    return errJson(503, "QA report storage is not configured", {
      code: "qa_storage_unavailable", requestId,
    });
  }

  const raw = parseInt(url.searchParams.get("limit") || "", 10);
  const limit = Number.isFinite(raw) && raw > 0 ? Math.min(raw, LIST_MAX) : LIST_DEFAULT;

  const listing = await kv.list({ prefix: "qa:shot:", limit: LIST_MAX });
  const shots = [];
  for (const k of listing.keys || []) {
    // qa:shot:<ticket>:<kind> — the ticket pattern forbids colons, so a plain
    // split is safe here in a way it is not for the ISO-keyed report listing.
    const parts = k.name.split(":");
    if (parts.length !== 4) continue;
    const meta = k.metadata || {};
    shots.push({
      ticket: parts[2],
      kind: parts[3],
      bytes: Number.isFinite(meta.bytes) ? meta.bytes : null,
      receivedAt: meta.receivedAt ? new Date(meta.receivedAt).toISOString() : null,
      url: `/qa/shots?ticket=${encodeURIComponent(parts[2])}&kind=${encodeURIComponent(parts[3])}`,
    });
  }

  shots.sort((a, b) => (Date.parse(b.receivedAt || "") || 0) - (Date.parse(a.receivedAt || "") || 0));
  return json({ ok: true, shots: shots.slice(0, limit) }, 200);
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

  // Build 73. `/qa/shots/STK-73-0004` is accepted as well as `?ticket=` so a
  // stored picture has a plain URL you can paste into a browser or a report.
  if (p === "/qa/shots" || p.startsWith("/qa/shots/")) {
    if (p.length > "/qa/shots/".length && p.startsWith("/qa/shots/")) {
      const segments = p.slice("/qa/shots/".length).split("/").filter(Boolean);
      if (segments[0] && !url.searchParams.get("ticket")) {
        url.searchParams.set("ticket", decodeURIComponent(segments[0]));
      }
      if (segments[1] && !url.searchParams.get("kind")) {
        url.searchParams.set("kind", decodeURIComponent(segments[1]));
      }
    }
    if (m === "POST" || m === "PUT") return postShot(url, request, env, requestId);
    if (m === "GET") return getShot(url, env, requestId);
    return errJson(405, "Method not allowed", { code: "method_not_allowed", requestId });
  }

  return null;
}
