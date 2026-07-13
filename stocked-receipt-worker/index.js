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
const WORKER_VERSION = "2026-07-12.5"; // bump on every route/prompt change
const DEFAULT_MODEL = "claude-sonnet-5";
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
   try {
    // ── CORS preflight ──
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // ── Health/version probe (auth-free) ──
    // GET /health returns the deployed marker so a stale deploy is provable from the
    // app or a browser. Bump WORKER_VERSION whenever routes/prompts change.
    {
      const u = new URL(request.url);
      if (u.pathname === "/health") {
        return json({
          ok: true,
          version: WORKER_VERSION,
          // Booleans only — never the values. Lets a browser check instantly whether the
          // secrets were actually set on THIS worker (they do not carry over when a
          // worker is created fresh; run: wrangler secret put ANTHROPIC_API_KEY).
          hasAnthropicKey: !!env.ANTHROPIC_API_KEY,
          hasSharedKey: !!env.STOCKED_SHARED_KEY,
        }, 200);
      }
    }

    // ── Shared-secret check (applies to every route) ──
    // The app sends X-Stocked-Key; reject anything that doesn't match. This isn't
    // bulletproof (the secret ships in the app), but combined with rate limiting it
    // stops casual/automated abuse of the endpoint. Checked here, before the POST-only
    // guard, so the crowd GET routes below are authenticated but not rejected as non-POST.
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
      try {
        return await handleHousehold(url.pathname, request, env);
      } catch (e) {
        return json({ error: "household handler threw: " + String((e && e.message) || e), code: "householdCrash" }, 500);
      }
    }

    // ── Crowd item database routing (KV-backed; merged in from the standalone ──
    // stocked-crowd worker so there is a SINGLE worker to deploy and one shared secret.
    // Any path under /crowd is served here and never reaches the Anthropic proxy. It uses
    // its own CROWD KV namespace and the same X-Stocked-Key secret checked above. Crowd
    // read routes are GET, so this must run before the POST-only guard below.
    if (url.pathname.startsWith("/crowd")) {
      if (!env.CROWD) return json({ error: "Server misconfigured (no CROWD KV)" }, 500);
      return handleCrowd(url, request, env);
    }

    // ── The Anthropic proxy routes below are POST-only ──
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
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
      // Explicit so the client can tell the user the real problem.
      return json({ error: "Worker is missing the ANTHROPIC_API_KEY secret. Run: wrangler secret put ANTHROPIC_API_KEY" }, 500);
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

    // Success passes through unchanged so the app keeps reading content[0].text.
    // Upstream FAILURES are wrapped with a distinct status (502) and the upstream
    // status inside the body — otherwise an Anthropic 401 (bad API key) would reach
    // the app as a 401 and masquerade as an X-Stocked-Key mismatch.
    const text = await upstream.text();
    if (upstream.ok) {
      return new Response(text, {
        status: 200,
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }
    let detail = "";
    try { detail = (JSON.parse(text).error || {}).message || ""; } catch {}
    return json({
      error: "Assistant upstream error",
      upstreamStatus: upstream.status,
      detail: detail.slice(0, 200),
    }, 502);
   } catch (e) {
     return json({ error: "Worker threw: " + String((e && e.message) || e), code: "workerCrash" }, 500);
   }
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

  // ── Inventory tidy-up scan (AI Inventory Scan feature) ──────────────────
  // The app sends { inventoryScan: true, inventory: [ {id, name, zone, quantity,
  // brand, hasNutrition, hasExpiry}, … ] } and expects back a JSON object
  // {"updates": [...]} where each update references an item id and proposes only
  // genuinely helpful cleanups. This branch was missing from the consolidated
  // worker, so the scan always failed; it is restored here.
  if (p.inventoryScan === true && Array.isArray(p.inventory)) {
    const rows = p.inventory.slice(0, 120).map((it) => {
      const flags = [];
      if (it && it.hasNutrition) flags.push("hasNutrition");
      if (it && it.hasExpiry) flags.push("hasExpiry");
      const brand = it && it.brand ? ` brand=${it.brand}` : "";
      return `- id=${it && it.id} name=${it && it.name} zone=${it && it.zone}${brand}${flags.length ? " (" + flags.join(",") + ")" : ""}`;
    }).join("\n");
    return {
      system:
        "You tidy up a kitchen inventory. You are given a list of items with an id, name, " +
        "storage zone, and flags. Propose ONLY genuinely helpful cleanups, and return the id " +
        "of each item you change. Rules: correct obvious misspellings or normalize a messy name " +
        "with newName (otherwise omit newName). Fix a clearly wrong storage zone with newZone, " +
        "but be VERY careful about food identity so you never move a shelf-stable item into the fridge. " +
        "Dried seasonings and spices are Staples, NEVER Fridge, even when the name contains a produce word: " +
        "cayenne pepper, lemon pepper, black pepper, chili powder, garlic powder, onion powder, and paprika are " +
        "dried spices, not fresh peppers. Flavored or named snacks stay in Pantry, NEVER dairy or Fridge just " +
        "because of a word in the name: cheddar chips, sour cream and onion chips, cheese crackers, and ranch " +
        "crackers are shelf-stable snacks, not cheese or dairy. Only choose Fridge or Freezer when the item truly " +
        "is fresh, chilled, or frozen. When unsure, leave the zone unchanged and omit newZone. " +
        'which MUST be exactly one of "Fridge", "Freezer", "Pantry", or "Staples" (omit if the ' +
        "current zone is fine). For an item WITHOUT hasNutrition, you may add rough per-serving " +
        "calories (integer) and protein grams (number) with a short servingSize string; NEVER add " +
        "nutrition for an item that already has hasNutrition. For an item WITHOUT hasExpiry you may " +
        "add expiryDays, an integer estimate of typical shelf life from today (1 to 730); NEVER add " +
        "expiry for an item that already has hasExpiry. Give a short reason for each change. Do NOT " +
        "invent items, do NOT propose deletions, and skip items that are already fine. Respond with " +
        'ONLY a JSON object, no prose and no markdown fences: {"updates": [{"id": string, ' +
        '"newName"?: string, "newZone"?: string, "calories"?: number, "protein"?: number, ' +
        '"servingSize"?: string, "expiryDays"?: number, "reason": string}]}. If nothing needs ' +
        'changing, return {"updates": []}.',
      user: `Inventory to review:\n${rows}`,
    };
  }

  return null;
}

/**
 * Per-IP rate limiting using a KV namespace. Two windows: a per-minute burst cap
 * and a per-day cap. Counters auto-expire via KV TTL so there's no cleanup.
 */
async function isRateLimited(kv, ip) {
  // Counters live in the Cache API instead of KV. KV has a hard 1000 writes/day
  // cap on the free plan, and writing a counter on every request burned through
  // it and made every route throw "KV put() limit exceeded". The Cache API has
  // no such write cap and is plenty for coarse per-IP rate limiting.
  const minuteKey = `m:${ip}:${Math.floor(Date.now() / 60000)}`;
  const dayKey = `d:${ip}:${Math.floor(Date.now() / 86400000)}`;
  const minCount = await cacheCounterGet(minuteKey);
  const dayCount = await cacheCounterGet(dayKey);
  if (minCount >= PER_MINUTE_LIMIT || dayCount >= PER_DAY_LIMIT) return true;
  await Promise.all([
    cacheCounterBump(minuteKey, 120),
    cacheCounterBump(dayKey, 90000),
  ]);
  return false;
}

// ── Cache-API counter helpers (no KV writes) ──────────────────────────────
// The Cache API keys on a URL. We use a synthetic https URL under a private host
// so keys never collide with real requests. Values are a small integer body with
// a max-age so the bucket self-expires like the old KV TTL.
function counterURL(key) {
  return "https://rate-limit.internal/" + encodeURIComponent(key);
}
async function cacheCounterGet(key) {
  try {
    const hit = await caches.default.match(counterURL(key));
    if (!hit) return 0;
    const n = parseInt(await hit.text(), 10);
    return Number.isFinite(n) ? n : 0;
  } catch { return 0; }
}
async function cacheCounterBump(key, ttlSeconds) {
  try {
    const current = await cacheCounterGet(key);
    const resp = new Response(String(current + 1), {
      headers: { "Cache-Control": "max-age=" + ttlSeconds, "Content-Type": "text/plain" },
    });
    await caches.default.put(counterURL(key), resp);
  } catch { /* best-effort; never block a request on the limiter */ }
}

/** #20 Per-household push limiter: caps writes per household per minute so one runaway client
 *  can't hammer the KV store, independent of the per-IP limit. Returns true when over the cap. */
async function isHouseholdWriteLimited(kv, code) {
  if (!code) return false;
  // Also moved off KV writes onto the Cache API (see isRateLimited note).
  const key = `hw:${code}:${Math.floor(Date.now() / 60000)}`;
  const count = await cacheCounterGet(key);
  if (count >= HH_WRITE_PER_MINUTE) return true;
  await cacheCounterBump(key, 120);
  return false;
}
const HH_WRITE_PER_MINUTE = 60;   // generous for real use, blocks a stuck client loop

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
      userRecipes: [],
      genRecipes: [],
      plannedMeals: [],
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
    // #11 presence: remember when this member's device last synced (fire-and-forget style;
    // stored under its own key so the household snapshot shape is untouched).
    const mid = sanitizeId(body.memberId);
    if (mid) {
      try {
        const pRaw = await kv.get("hh:presence:" + code);
        const presence = pRaw ? JSON.parse(pRaw) : {};
        presence[mid] = { name: sanitizeName(body.memberName), ts: Date.now() };
        await kv.put("hh:presence:" + code, JSON.stringify(presence), { expirationTtl: 60 * 60 * 24 * 30 });
      } catch (e) { /* presence is best-effort; never block a pull */ }
    }
    // #1 changed-since: if the caller passes the updatedAt it last saw and nothing changed,
    // return a tiny "unchanged" response instead of the full document. Lets the client poll
    // frequently and cheaply for near-instant sync without shipping the whole pantry each time.
    const since = Number(body.since || 0);
    if (since > 0 && Number(household.updatedAt || 0) <= since) {
      return json({ unchanged: true, updatedAt: household.updatedAt || 0 });
    }
    return json({ household });
  }

  // #11 — presence map for the members screen: { memberId: { name, ts } }.
  if (action === "presence") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    const pRaw = await kv.get("hh:presence:" + code);
    return json({ presence: pRaw ? JSON.parse(pRaw) : {} });
  }

  if (action === "push") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    // #20 per-household write cap (separate from per-IP). Protects the KV store from a stuck client.
    if (await isHouseholdWriteLimited(kv, code)) {
      return json({ error: "Too many changes at once; please wait a moment", code: "rateLimited" }, 429);
    }

    // #5 Server-side permission enforcement. Look up the pushing member and their effective
    // permissions (role default, overridden per-member). The owner is always allowed. A member
    // with no add/edit rights (e.g. a kid / view-only) is rejected outright; a member who can
    // add/edit but not remove has their deletion tombstones ignored rather than the push failing.
    const actorId = sanitizeId(body.actorId);
    const isOwner = actorId && actorId === household.ownerId;
    let canWrite = true, canRemove = true;
    if (!isOwner) {
      const me = (household.members || []).find((m) => m.memberId === actorId);
      if (me) {
        const roleDefaults = {
          owner:   { add: true,  edit: true,  remove: true },
          manager: { add: true,  edit: true,  remove: true },
          adult:   { add: true,  edit: true,  remove: true },
          teen:    { add: true,  edit: true,  remove: false },
          kid:     { add: false, edit: false, remove: false },
          member:  { add: true,  edit: true,  remove: true },
        };
        const def = roleDefaults[me.role] || roleDefaults.adult;
        const add    = (typeof me.overrideCanAdd    === "boolean") ? me.overrideCanAdd    : def.add;
        const edit   = (typeof me.overrideCanEdit   === "boolean") ? me.overrideCanEdit   : def.edit;
        canRemove    = (typeof me.overrideCanRemove === "boolean") ? me.overrideCanRemove : def.remove;
        canWrite = add || edit;
      }
    }
    if (!canWrite) {
      return json({ error: "Your access level can't change the household pantry", code: "forbidden" }, 403);
    }
    // If this member can't remove, drop their deletion tombstones before they're accumulated.
    if (!canRemove) {
      body.invDeleted = []; body.groDeleted = []; body.userRecipeDeleted = []; body.genRecipeDeleted = [];
    }

    // Accumulate deletion tombstones so a remove on one device sticks and propagates. Stored on
    // the household doc and echoed back on pull; capped so they can't grow without bound.
    household.invDeleted = dedupeCap((household.invDeleted || []).concat(Array.isArray(body.invDeleted) ? body.invDeleted : []), HH_MAX_ITEMS);
    household.groDeleted = dedupeCap((household.groDeleted || []).concat(Array.isArray(body.groDeleted) ? body.groDeleted : []), HH_MAX_ITEMS);
    household.userRecipeDeleted = dedupeCap((household.userRecipeDeleted || []).concat(Array.isArray(body.userRecipeDeleted) ? body.userRecipeDeleted : []), HH_MAX_ITEMS);
    household.genRecipeDeleted = dedupeCap((household.genRecipeDeleted || []).concat(Array.isArray(body.genRecipeDeleted) ? body.genRecipeDeleted : []), HH_MAX_ITEMS);
    household.mealDeleted = dedupeCap((household.mealDeleted || []).concat(Array.isArray(body.mealDeleted) ? body.mealDeleted : []), HH_MAX_ITEMS);
    const invDel = new Set(household.invDeleted);
    const groDel = new Set(household.groDeleted);
    const userRecipeDel = new Set(household.userRecipeDeleted);
    const genRecipeDel = new Set(household.genRecipeDeleted);

    // Merge inventory/grocery by id with last-write-wins on updatedAt, dropping tombstoned ids.
    // Previously push REPLACED the whole list, so with two devices whoever pushed last wiped the
    // other's items (the "only one inventory increases" bug). LWW merge makes adds, edits
    // (quantity, title, zone), and removals all converge across devices.
    if (Array.isArray(body.inventory)) {
      household.inventory = mergeLWW(household.inventory, body.inventory, invDel).slice(0, HH_MAX_ITEMS);
    }
    if (Array.isArray(body.grocery)) {
      household.grocery = mergeLWW(household.grocery, body.grocery, groDel).slice(0, HH_MAX_ITEMS);
    }
    // Recipes (user-created and AI-generated) merge the same LWW way. Images are not sent, so
    // these payloads stay small.
    if (Array.isArray(body.userRecipes)) {
      household.userRecipes = mergeLWW(household.userRecipes || [], body.userRecipes, userRecipeDel).slice(0, HH_MAX_ITEMS);
    }
    if (Array.isArray(body.genRecipes)) {
      household.genRecipes = mergeLWW(household.genRecipes || [], body.genRecipes, genRecipeDel).slice(0, HH_MAX_ITEMS);
    }
    if (Array.isArray(body.plannedMeals)) {
      const mealDel = new Set(household.mealDeleted);
      household.plannedMeals = mergeLWW(household.plannedMeals || [], body.plannedMeals, mealDel).slice(0, HH_MAX_ITEMS);
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

  // Owner-only: set a member's access level and optional custom label.
  if (action === "setrole") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    const actorId = sanitizeId(body.actorId);
    if (!actorId || actorId !== household.ownerId) {
      return json({ error: "Only the household owner can change member levels", code: "forbidden" }, 403);
    }
    const targetId = sanitizeId(body.memberId);
    const role = typeof body.role === "string" ? body.role.slice(0, 20) : "";
    const label = typeof body.label === "string" ? body.label.slice(0, 40) : undefined;
    const idx = household.members.findIndex((m) => m.memberId === targetId);
    if (idx === -1) return json({ error: "member not found", code: "notFound" }, 404);
    // The owner's own level cannot be changed away from owner.
    if (targetId !== household.ownerId && role) household.members[idx].role = role;
    if (label !== undefined) household.members[idx].label = label;
    // #4 per-permission overrides. Explicit true/false sets an override; null clears it.
    for (const key of ["overrideCanAdd", "overrideCanEdit", "overrideCanRemove"]) {
      if (key in body) {
        if (body[key] === null) delete household.members[idx][key];
        else if (typeof body[key] === "boolean") household.members[idx][key] = body[key];
      }
    }
    household.updatedAt = Date.now();
    await writeHousehold(kv, code, household);
    return json({ ok: true, household });
  }

  if (action === "setname") {
    const code = normalizeCode(body.code);
    const household = await readHousehold(kv, code);
    if (!household) return json({ error: "share not found", code: "notFound" }, 404);
    const actorId = sanitizeId(body.actorId || body.memberId);
    const newName = sanitizeName(body.name);
    if (!actorId || !newName) return json({ error: "Missing member or name", code: "badRequest" }, 400);
    const idx = (household.members || []).findIndex((m) => m.memberId === actorId);
    if (idx === -1) return json({ error: "member not found", code: "notFound" }, 404);
    const oldName = household.members[idx].name || "";
    if (oldName === newName) return json({ ok: true, household });
    household.members[idx].name = newName;
    if (actorId === household.ownerId) household.ownerName = newName;
    const evt = { kind: "memberRenamed", itemName: newName, oldName: oldName, actorName: oldName || newName, date: Date.now() };
    household.activity = appendActivity((household.activity || []).concat([evt]), null);
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

// Last-write-wins merge of two {id, updatedAt, ...} arrays, dropping any id in `deleted`.
// Newer updatedAt wins for a shared id; items only one side has are kept (unless tombstoned).
function mergeLWW(existing, incoming, deleted) {
  const byId = new Map();
  let anon = 0;
  const put = (item) => {
    if (!item) return;
    const key = item.id != null ? String(item.id) : "anon_" + anon++;
    if (deleted && deleted.has(key)) return;   // tombstoned: never keep
    const prev = byId.get(key);
    if (!prev) { byId.set(key, item); return; }
    const a = Number(item.updatedAt || 0), b = Number(prev.updatedAt || 0);
    if (a >= b) byId.set(key, item);            // newer (or equal) wins
  };
  for (const it of Array.isArray(existing) ? existing : []) put(it);
  for (const it of Array.isArray(incoming) ? incoming : []) put(it);
  return Array.from(byId.values());
}

// Dedupe a string array and cap its length, keeping the most recent entries.
function dedupeCap(arr, cap) {
  const seen = new Set();
  const out = [];
  for (const v of Array.isArray(arr) ? arr : []) {
    const s = String(v);
    if (!seen.has(s)) { seen.add(s); out.push(s); }
  }
  return out.slice(-cap);
}

async function readHousehold(kv, code) {
  if (!code) return null;
  const raw = await kv.get(hhKey(code));
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

async function writeHousehold(kv, code, household) {
  // Skip the KV write when the document is byte-identical to what is already
  // stored. Most pushes are no-ops (a member polling with no real change), and
  // every avoided put() is one saved against the daily write quota.
  const next = JSON.stringify(household);
  try {
    const prev = await kv.get(hhKey(code));
    if (prev === next) return;
  } catch { /* fall through and write */ }
  await kv.put(hhKey(code), next, { expirationTtl: HH_TTL_SECONDS });
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

// ─────────────────────────────────────────────────────────────────
// Crowd item database (merged from the former standalone stocked-crowd worker).
// Anonymized + opt-in on the client. Paths are served under /crowd:
//   POST /crowd/report        { items: [{name,category,unit,container,quantity}], basket?: [names] }
//   GET  /crowd/suggest?name=milk
//   GET  /crowd/autocomplete?prefix=ch
//   GET  /crowd/pairings?name=pasta
// Reuses the top-level json() helper and the shared X-Stocked-Key auth already enforced
// in fetch(). Storage is the CROWD KV namespace.
// ─────────────────────────────────────────────────────────────────
const crowdNorm = (s) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

async function crowdGetAgg(env, key) {
  const raw = await env.CROWD.get("item:" + key);
  return raw ? JSON.parse(raw) : { count: 0, units: {}, containers: {}, categories: {}, qtySum: 0, qtyN: 0, shelfSum: 0, shelfN: 0 };
}
function crowdBump(map, k) { if (!k) return; k = String(k).toLowerCase(); map[k] = (map[k] || 0) + 1; }
function crowdTopKey(map) { let best = null, n = -1; for (const k in map) if (map[k] > n) { best = k; n = map[k]; } return best; }
async function crowdUpdatePopular(env, key) {
  const raw = await env.CROWD.get("popular");
  const pop = raw ? JSON.parse(raw) : {};
  pop[key] = (pop[key] || 0) + 1;
  const entries = Object.entries(pop).sort((a, b) => b[1] - a[1]).slice(0, 2000);
  await env.CROWD.put("popular", JSON.stringify(Object.fromEntries(entries)));
}

async function handleCrowd(url, request, env) {
  const path = url.pathname.replace(/^\/crowd/, "") || "/";
  try {
    if (request.method === "POST" && path === "/report") {
      const body = await request.json();
      const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
      for (const it of items) {
        const key = crowdNorm(it.name);
        if (!key || key.length < 2) continue;
        const agg = await crowdGetAgg(env, key);
        agg.count += 1;
        crowdBump(agg.units, it.unit);
        crowdBump(agg.containers, it.container);
        crowdBump(agg.categories, it.category);
        const q = Number(it.quantity);
        if (isFinite(q) && q > 0) { agg.qtySum += q; agg.qtyN += 1; }
        // #B4 shelf-life learning: optional days-until-expiry contributed at add time.
        const sl = Number(it.shelfLifeDays);
        if (isFinite(sl) && sl > 0 && sl < 720) {
          agg.shelfSum = (agg.shelfSum || 0) + sl;
          agg.shelfN = (agg.shelfN || 0) + 1;
        }
        await env.CROWD.put("item:" + key, JSON.stringify(agg));
        await crowdUpdatePopular(env, key);
      }
      const basket = Array.isArray(body.basket)
        ? [...new Set(body.basket.map(crowdNorm).filter(Boolean))].slice(0, 60) : [];
      for (const a of basket) {
        const raw = await env.CROWD.get("pair:" + a);
        const m = raw ? JSON.parse(raw) : {};
        for (const b of basket) if (a !== b) m[b] = (m[b] || 0) + 1;
        const top = Object.entries(m).sort((x, y) => y[1] - x[1]).slice(0, 40);
        await env.CROWD.put("pair:" + a, JSON.stringify(Object.fromEntries(top)));
      }
      return json({ ok: true, received: items.length });
    }

    if (request.method === "GET" && path === "/suggest") {
      const key = crowdNorm(url.searchParams.get("name"));
      if (!key) return json({ error: "name required" }, 400);
      const agg = await crowdGetAgg(env, key);
      return json({
        count: agg.count,
        topUnit: crowdTopKey(agg.units),
        topContainer: crowdTopKey(agg.containers),
        topCategory: crowdTopKey(agg.categories),
        avgQuantity: agg.qtyN ? +(agg.qtySum / agg.qtyN).toFixed(2) : null,
        avgShelfLifeDays: agg.shelfN ? +(agg.shelfSum / agg.shelfN).toFixed(1) : null,
      });
    }

    if (request.method === "GET" && path === "/autocomplete") {
      const prefix = crowdNorm(url.searchParams.get("prefix"));
      const limit = Math.min(20, Number(url.searchParams.get("limit")) || 10);
      const raw = await env.CROWD.get("popular");
      const pop = raw ? JSON.parse(raw) : {};
      const items = Object.entries(pop)
        .filter(([k]) => !prefix || k.startsWith(prefix))
        .sort((a, b) => b[1] - a[1]).slice(0, limit).map(([k]) => k);
      return json({ items });
    }

    if (request.method === "GET" && path === "/pairings") {
      const key = crowdNorm(url.searchParams.get("name"));
      const raw = await env.CROWD.get("pair:" + key);
      const m = raw ? JSON.parse(raw) : {};
      const pairings = Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 20);
      return json({ pairings });
    }

    return json({ error: "not found" }, 404);
  } catch (e) {
    return json({ error: String((e && e.message) || e) }, 500);
  }
}
