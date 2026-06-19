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
