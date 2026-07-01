/**
 * Stocked. — Anthropic API proxy Worker (hardened).
 * ────────────────────────────────────────────────────────────────────────────
 * Why this exists: it keeps the Anthropic API key OFF the device. The app POSTs
 * a small JSON payload (receipt text, a barcode, recipe text, or an inventory
 * intent); this Worker holds the `sk-ant-…` key as a server-side secret, calls
 * Anthropic, and returns Anthropic's response envelope unchanged so the app can
 * read `content[0].text`.
 *
 * HARDENING added here (was a bare proxy before):
 *   1. Shared-secret header check  — rejects callers that don't present X-Stocked-Key.
 *   2. Per-IP rate limiting (KV)    — caps requests/min and requests/day per IP so a
 *                                     leaked URL can't burn the Anthropic budget.
 *   3. Method/size guards           — only POST, capped body size, JSON only.
 *   4. CORS preflight handling      — so the app (and future web) can call it.
 *
 * COMPATIBILITY: the four existing payload shapes are preserved exactly —
 *   { receipt, storeName?, corrections? }   (receipt OCR parse)
 *   { barcode }                              (barcode → product name)
 *   { recipeText }                           (recipe import)
 *   { recipeIdea, haveItems?, dietary?, maxTime? }  (recipe generation)
 *   { intent, inventory }                    (inventory change proposal)
 * …and the response is Anthropic's JSON passthrough ({ content: [{ text }], … }).
 *
 * REQUIRED Worker config (see README.md):
 *   Secret  : ANTHROPIC_API_KEY   (wrangler secret put ANTHROPIC_API_KEY)
 *   Secret  : STOCKED_SHARED_KEY  (wrangler secret put STOCKED_SHARED_KEY) — must match the app
 *   KV bind : RATE_KV             (a KV namespace for the rate-limit counters)
 *   Var     : ANTHROPIC_MODEL     (optional; defaults below)
 */

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const DEFAULT_MODEL = "claude-sonnet-4-6";
const MAX_TOKENS = 1500;

// Rate limits per IP.
const PER_MINUTE_LIMIT = 12;     // burst protection
const PER_DAY_LIMIT = 200;       // daily abuse cap (keeps Anthropic spend bounded)

const MAX_BODY_BYTES = 2 * 1024 * 1024; // 2 MB — text is tiny; a base64 receipt photo needs room

// Shared receipt-parsing instruction (used by both the OCR-text and image/vision paths).
const RECEIPT_SYSTEM =
  "You parse grocery receipts into structured items. Respond ONLY with a JSON array, no " +
  "prose, no markdown fences. Each element: " +
  '{"raw": string, "resolved": string, "quantity": number, "zone": "Fridge"|"Freezer"|"Pantry"|"Other", ' +
  '"brand": string|null, "unitPrice": number|null, "totalPrice": number|null}. ' +
  "Resolve abbreviations to real product names. Skip totals, tax, and non-items.";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Stocked-Key",
  "Access-Control-Max-Age": "86400",
};

export default {
  async fetch(request, env) {
    // ── CORS preflight ──
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    // ── 1. Shared-secret check ──
    // The app sends X-Stocked-Key; reject anything that doesn't match. This isn't
    // bulletproof (the secret ships in the app), but combined with rate limiting it
    // stops casual/automated abuse of the endpoint.
    const provided = request.headers.get("X-Stocked-Key") || "";
    if (!env.STOCKED_SHARED_KEY || !timingSafeEqual(provided, env.STOCKED_SHARED_KEY)) {
      return json({ error: "Unauthorized" }, 401);
    }

    // ── Household sync routing (KV-backed; replaces the old CloudKit CKShare flow) ──
    // Any path under /household is handled here and never reaches the Anthropic proxy.
    // Storage reuses the RATE_KV namespace with an "hh:" prefix, so no new Cloudflare
    // config is required. A household is one JSON snapshot keyed by its short code.
    const url = new URL(request.url);
    if (url.pathname.startsWith("/household")) {
      if (!env.RATE_KV) return json({ error: "Server misconfigured (no KV)" }, 500);
      return handleHousehold(url.pathname, request, env);
    }

    // ── 2. Per-IP rate limiting ──
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    if (env.RATE_KV) {
      const limited = await isRateLimited(env.RATE_KV, ip);
      if (limited) {
        return json({ error: "Rate limit exceeded. Try again later." }, 429);
      }
    }

    // ── 3. Body guards ──
    const lenHeader = parseInt(request.headers.get("Content-Length") || "0", 10);
    if (lenHeader && lenHeader > MAX_BODY_BYTES) {
      return json({ error: "Payload too large" }, 413);
    }

    let payload;
    try {
      const raw = await request.text();
      if (raw.length > MAX_BODY_BYTES) return json({ error: "Payload too large" }, 413);
      payload = JSON.parse(raw);
    } catch {
      return json({ error: "Invalid JSON" }, 400);
    }

    // ── Build the Anthropic prompt from whichever payload shape arrived ──
    const prompt = buildPrompt(payload);
    if (!prompt) {
      return json({ error: "Unrecognized request" }, 422);
    }

    if (!env.ANTHROPIC_API_KEY) {
      return json({ error: "Server misconfigured" }, 500);
    }

    // ── Call Anthropic ──
    const model = env.ANTHROPIC_MODEL || DEFAULT_MODEL;
    let upstream;
    try {
      upstream = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": ANTHROPIC_VERSION,
        },
        body: JSON.stringify({
          model,
          max_tokens: MAX_TOKENS,
          system: prompt.system,
          messages: [{ role: "user", content: prompt.user }],
        }),
      });
    } catch (e) {
      return json({ error: "Upstream request failed" }, 502);
    }

    // Pass Anthropic's response through unchanged (status + body) so the app keeps
    // reading content[0].text exactly as before.
    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: { "Content-Type": "application/json", ...CORS_HEADERS },
    });
  },
};

/**
 * Turns each known payload shape into a request for Anthropic. Most return a
 * (system, user-text) prompt; the image-receipt shape returns vision content blocks.
 * Returns null for anything unrecognized. Keep these in sync with what each app caller
 * expects to parse back out of content[0].text.
 */
function buildPrompt(p) {
  // Image-based receipt (vision) → JSON array of items. The app sends a downscaled JPEG.
  if (typeof p.imageBase64 === "string" && p.imageBase64) {
    const store = p.storeName ? `\nStore: ${p.storeName}` : "";
    const corrections = p.corrections
      ? `\nKnown corrections (raw → resolved): ${JSON.stringify(p.corrections)}`
      : "";
    return {
      system: RECEIPT_SYSTEM,
      // Vision: an image block + a text instruction block.
      user: [
        {
          type: "image",
          source: {
            type: "base64",
            media_type: p.imageMediaType || "image/jpeg",
            data: p.imageBase64,
          },
        },
        { type: "text", text: `Parse this receipt into the JSON array described.${store}${corrections}` },
      ],
    };
  }

  // Receipt OCR parse → JSON array of items.
  if (typeof p.receipt === "string" && p.receipt.trim()) {
    const store = p.storeName ? `\nStore: ${p.storeName}` : "";
    const corrections = p.corrections
      ? `\nKnown corrections (raw → resolved): ${JSON.stringify(p.corrections)}`
      : "";
    return {
      system: RECEIPT_SYSTEM,
      user: `Receipt OCR text:${store}${corrections}\n\n${p.receipt}`,
    };
  }

  // Barcode → product name (plain text, short).
  if (typeof p.barcode === "string" && p.barcode.trim()) {
    return {
      system:
        "You identify a grocery product from its barcode (UPC/EAN). Respond with ONLY the " +
        "product name in plain text (brand + product, under 60 characters). If you cannot " +
        'identify it confidently, respond with exactly "unknown".',
      user: `Barcode: ${p.barcode}`,
    };
  }

  // Recipe import → structured recipe JSON.
  if (typeof p.recipeText === "string" && p.recipeText.trim()) {
    return {
      system:
        "You convert pasted recipe text into a single JSON object, no prose, no markdown fences: " +
        '{"title": string, "description": string, "cookTime": string, "prepTime": string, ' +
        '"servings": number, "difficulty": "Easy"|"Medium"|"Hard", "cuisine": string, ' +
        '"tags": string[], "ingredients": [{"name": string, "amount": string}], ' +
        '"instructions": string[]}.',
      user: p.recipeText,
    };
  }

  // Inventory change proposal → structured changes JSON.
  if (typeof p.intent === "string" && p.intent.trim()) {
    const inv = p.inventory ? JSON.stringify(p.inventory) : "[]";
    return {
      system:
        "You translate a natural-language kitchen update into inventory changes. Respond ONLY " +
        "with a JSON object, no prose, no markdown fences: " +
        '{"changes": [{"name": string, "action": "add"|"remove"|"setLevel", "level": number|null, ' +
        '"quantity": number|null}]}. Match against the provided current inventory where possible.',
      user: `Current inventory: ${inv}\n\nUser request: ${p.intent}`,
    };
  }

  // Recipe generation from a description → structured recipe JSON (SAME shape as recipeText,
  // so the app parses it with the existing recipe parser). The user describes what they want and
  // may list ingredients they have and dietary/time constraints. Generate a complete, realistic
  // recipe — do not just echo the request.
  if (typeof p.recipeIdea === "string" && p.recipeIdea.trim()) {
    const have = Array.isArray(p.haveItems) && p.haveItems.length
      ? `\nIngredients the user already has (prefer these, but add common staples as needed): ${p.haveItems.join(", ")}.`
      : "";
    const diet = typeof p.dietary === "string" && p.dietary.trim()
      ? `\nDietary requirement: ${p.dietary}. The recipe MUST comply.`
      : "";
    const time = typeof p.maxTime === "string" && p.maxTime.trim()
      ? `\nThe recipe should fit roughly within ${p.maxTime} of total time.`
      : "";
    return {
      system:
        "You are a recipe developer. Create ONE complete, realistic, cookable recipe from the " +
        "user's description. Invent a sensible recipe with real quantities and clear steps; do " +
        "not refuse and do not ask questions. Respond with ONLY a single JSON object, no prose, " +
        "no markdown fences: " +
        '{"title": string, "description": string, "cookTime": string, "prepTime": string, ' +
        '"servings": number, "difficulty": "Easy"|"Medium"|"Hard", "cuisine": string, ' +
        '"tags": string[], "ingredients": [{"name": string, "amount": string}], ' +
        '"steps": string[]}. Each step is one clear instruction. Include any cooking or ' +
        "resting time inside the relevant step text (e.g. \"Bake for 12 minutes\") so timers can " +
        "be derived. Keep cookTime and prepTime as short human strings like \"20 minutes\".",
      user: `Recipe request: ${p.recipeIdea}${have}${diet}${time}`,
    };
  }

  return null;
}

/**
 * Per-IP rate limiting using a KV namespace. Two windows: a per-minute burst cap
 * and a per-day cap. Counters auto-expire via KV TTL so there's no cleanup.
 */
async function isRateLimited(kv, ip) {
  const now = Date.now();
  const minuteKey = `m:${ip}:${Math.floor(now / 60000)}`;
  const dayKey = `d:${ip}:${Math.floor(now / 86400000)}`;

  const [minRaw, dayRaw] = await Promise.all([kv.get(minuteKey), kv.get(dayKey)]);
  const minCount = parseInt(minRaw || "0", 10);
  const dayCount = parseInt(dayRaw || "0", 10);

  if (minCount >= PER_MINUTE_LIMIT || dayCount >= PER_DAY_LIMIT) return true;

  // Increment both (fire-and-forget TTLs: 120s for minute bucket, ~25h for day).
  await Promise.all([
    kv.put(minuteKey, String(minCount + 1), { expirationTtl: 120 }),
    kv.put(dayKey, String(dayCount + 1), { expirationTtl: 90000 }),
  ]);
  return false;
}

/** Constant-time string comparison to avoid leaking the secret via timing. */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// HOUSEHOLD SYNC (KV-backed). Replaces CloudKit CKShare, which produced
// unreliable "share not found" errors. A household is a single JSON document
// stored under key hh:<CODE>. Members push and pull the whole document; the app
// merges locally. No per-device share URLs to rot.
//
// Endpoints (all POST, all require X-Stocked-Key, JSON body):
//   POST /household/create  { ownerName }            -> { code, household }
//   POST /household/join    { code, memberName }     -> { ok, household } | 404
//   POST /household/pull    { code }                 -> { household } | 404
//   POST /household/push    { code, inventory, grocery, activity } -> { ok, household }
//   POST /household/leave   { code, memberName }     -> { ok }
//
// The "household" document shape:
//   { code, ownerName, members:[{name, joinedAt}], inventory:[...],
//     grocery:[...], activity:[...], updatedAt }
// ─────────────────────────────────────────────────────────────────────────────

const HH_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous chars
const HH_MAX_ITEMS = 2000;     // sane caps so a household doc can't grow unbounded
const HH_MAX_ACTIVITY = 200;
const HH_TTL_SECONDS = 60 * 60 * 24 * 365; // refreshed on every write; ~1 year idle expiry

async function handleHousehold(pathname, request, env) {
  const kv = env.RATE_KV;
  let body;
  try {
    body = JSON.parse(await request.text());
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const action = pathname.replace(/^\/household\/?/, "");

  if (action === "create") {
    const ownerName = sanitizeName(body.ownerName);
    const ownerId = sanitizeId(body.memberId);
    // Generate a code that isn't already taken (a few tries is plenty at this scale).
    let code = "";
    for (let attempt = 0; attempt < 6; attempt++) {
      const candidate = makeHouseholdCode();
      const existing = await kv.get(hhKey(candidate));
      if (!existing) { code = candidate; break; }
    }
    if (!code) return json({ error: "Could not allocate a code, try again" }, 503);
    const household = {
      code,
      ownerName,
      ownerId,
      members: [{ name: ownerName, memberId: ownerId, joinedAt: Date.now() }],
      inventory: [],
      grocery: [],
      activity: [{ kind: "householdCreated", itemName: "", actorName: ownerName, date: Date.now() }],
      updatedAt: Date.now(),
    };
    await kv.put(hhKey(code), JSON.stringify(household), { expirationTtl: HH_TTL_SECONDS });
    return json({ code, household });
  }

  // Regenerate the invite code for an EXISTING household: mint a fresh code, move the document
  // to the new key, and delete the old key so the previous code stops working. Members stay in
  // the household (it's the same document) — only the code they'd share with new people changes.
  if (action === "regenerate") {
    const oldCode = normalizeCode(body.code);
    const household = await readHousehold(kv, oldCode);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    let newCode = "";
    for (let attempt = 0; attempt < 6; attempt++) {
      const candidate = makeHouseholdCode();
      if (candidate === oldCode) continue;
      const existing = await kv.get(hhKey(candidate));
      if (!existing) { newCode = candidate; break; }
    }
    if (!newCode) return json({ error: "Could not allocate a new code, try again" }, 503);
    household.code = newCode;
    household.updatedAt = Date.now();
    await kv.put(hhKey(newCode), JSON.stringify(household), { expirationTtl: HH_TTL_SECONDS });
    await kv.delete(hhKey(oldCode));
    return json({ code: newCode, household });
  }

  if (action === "join") {
    const code = normalizeCode(body.code);
    const memberName = sanitizeName(body.memberName);
    const memberId = sanitizeId(body.memberId);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);

    // Identify an existing member by stable memberId when we have one; fall back to name only
    // for legacy clients that predate memberId. This is the core fix: two devices that are both
    // called "You" (or two real people both named Jess) are now distinct members, and the join
    // is no longer silently deduped away.
    const idx = household.members.findIndex((m) =>
      memberId ? m.memberId === memberId : (m.name === memberName && !m.memberId)
    );

    if (idx === -1) {
      household.members.push({ name: memberName, memberId, joinedAt: Date.now() });
      household.activity = appendActivity(household.activity, {
        kind: "memberJoined", itemName: "", actorName: memberName, date: Date.now(),
      });
      household.updatedAt = Date.now();
      await writeHousehold(kv, code, household);
    } else if (household.members[idx].name !== memberName || !household.members[idx].memberId) {
      // Same device re-joining: refresh its stored name and backfill its id, no duplicate row.
      household.members[idx].name = memberName;
      household.members[idx].memberId = memberId || household.members[idx].memberId;
      household.updatedAt = Date.now();
      await writeHousehold(kv, code, household);
    }
    return json({ ok: true, household });
  }

  if (action === "pull") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    return json({ household });
  }

  if (action === "push") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    // Merge the collaborative parts by id rather than replacing. The previous code did a full
    // replace: household.inventory = body.inventory. With two devices, whoever pushed last wiped
    // the other's items, so an item added on one device vanished when the other synced — the
    // "only one inventory increases" bug. Merging by id lets each device contribute and keeps
    // everyone's items. A device that legitimately removed an item is handled by it simply not
    // being present on that device's next full push once both sides have converged; to keep this
    // simple and non-destructive we bias toward keeping items (adds win), which is the safe
    // default for a shared pantry.
    if (Array.isArray(body.inventory)) {
      household.inventory = mergeById(household.inventory, body.inventory).slice(0, HH_MAX_ITEMS);
    }
    if (Array.isArray(body.grocery)) {
      household.grocery = mergeById(household.grocery, body.grocery).slice(0, HH_MAX_ITEMS);
    }
    if (Array.isArray(body.activity)) {
      // Merge incoming activity, keep newest, cap.
      const merged = household.activity.concat(body.activity);
      household.activity = appendActivity(merged, null);
    }
    household.updatedAt = Date.now();
    await writeHousehold(kv, code, household);
    return json({ ok: true, household });
  }

  if (action === "leave") {
    const code = normalizeCode(body.code);
    const memberName = sanitizeName(body.memberName);
    const memberId = sanitizeId(body.memberId);
    const household = await readHousehold(kv, code);
    if (!household) return json({ ok: true });   // already gone
    household.members = household.members.filter((m) =>
      memberId ? m.memberId !== memberId : m.name !== memberName
    );
    household.activity = appendActivity(household.activity, {
      kind: "memberLeft", itemName: "", actorName: memberName, date: Date.now(),
    });
    household.updatedAt = Date.now();
    // If nobody is left, delete the household entirely.
    if (household.members.length === 0) {
      await kv.delete(hhKey(code));
    } else {
      await writeHousehold(kv, code, household);
    }
    return json({ ok: true });
  }

  return json({ error: "Unknown household action" }, 404);
}

function hhKey(code) { return "hh:" + code; }

// Merge two arrays of {id, ...} records by id: start from existing, overlay incoming so an
// updated item (same id) wins, and keep items only one side has. Records without a usable id
// fall back to appending, so nothing is silently dropped. This is what makes /household/push
// non-destructive across multiple devices instead of last-write-wins replacing the whole list.
function mergeById(existing, incoming) {
  const byId = new Map();
  let anon = 0;
  for (const item of Array.isArray(existing) ? existing : []) {
    const key = item && item.id != null ? String(item.id) : "anon_" + anon++;
    byId.set(key, item);
  }
  for (const item of Array.isArray(incoming) ? incoming : []) {
    const key = item && item.id != null ? String(item.id) : "anon_" + anon++;
    byId.set(key, item);
  }
  return Array.from(byId.values());
}

async function readHousehold(kv, code) {
  if (!code) return null;
  const raw = await kv.get(hhKey(code));
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

async function writeHousehold(kv, code, household) {
  await kv.put(hhKey(code), JSON.stringify(household), { expirationTtl: HH_TTL_SECONDS });
}

function makeHouseholdCode() {
  let out = "";
  for (let i = 0; i < 8; i++) {
    out += HH_CODE_ALPHABET[Math.floor(Math.random() * HH_CODE_ALPHABET.length)];
  }
  return out;
}

// Keep only code characters, uppercase, so quotes/spaces/dashes never break a lookup.
function normalizeCode(raw) {
  if (typeof raw !== "string") return "";
  return raw.toUpperCase().split("").filter((c) => HH_CODE_ALPHABET.includes(c)).join("");
}

function sanitizeName(raw) {
  if (typeof raw !== "string" || !raw.trim()) return "Member";
  return raw.trim().slice(0, 40);
}

// A member id is an opaque client-generated string (a UUID). Keep it bounded and stringy; empty
// when absent so legacy callers (no memberId) fall back to name-based matching.
function sanitizeId(raw) {
  if (typeof raw !== "string") return "";
  return raw.trim().slice(0, 64);
}

// Sort activity newest-first and cap. Pass a new event to prepend, or null to just normalize.
function appendActivity(list, newEvent) {
  let arr = Array.isArray(list) ? list.slice() : [];
  if (newEvent) arr.push(newEvent);
  arr.sort((a, b) => (b.date || 0) - (a.date || 0));
  return arr.slice(0, HH_MAX_ACTIVITY);
}
