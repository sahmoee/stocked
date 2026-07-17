// prices.js — POST /prices/compare (new function).
//
// Compares prices for a packaged/UPC item across major US retailers via
// retailerapi.com (Walmart, Amazon, Target, Best Buy, etc.). Returns a ranked
// per-retailer price list with optional unit pricing. Honest limits: packaged
// goods only (needs a barcode — no fresh produce), and major retailers rather
// than local grocery chains. Key-gated + cached 12h (prices change; conserves the
// free-tier 1,000 lookups/month).

import { json, errJson, readBoundedJSON, logEvent } from "./util.js";
import { validatePricesCompare } from "./validation.js";
import { hasRetailerApi, lookupProduct, normalizeForCompare } from "./retailerapi.js";

const CACHE_TTL_S = 12 * 3600;
const MAX_BODY = 16 * 1024;
const cacheURL = (code) => `https://price-compare.internal/${code}`;

export async function handlePricesCompare(request, env, _ctx, requestId) {
  const read = await readBoundedJSON(request, MAX_BODY);
  if (!read.ok) return errJson(read.status, read.message || "Bad request", { code: read.code, requestId });
  const body = read.value || {};
  const v = validatePricesCompare(body);
  if (!v.ok) return errJson(422, "Validation failed", { code: "invalidInput", requestId, extra: { errors: v.errors } });
  const code = v.code;

  if (!hasRetailerApi(env)) {
    return json({ schemaVersion: 1, barcode: code, found: false, reason: "notConfigured" }, 200);
  }

  const sizeValue = body.sizeValue;
  const sizeUnit = body.sizeUnit;
  // Unit pricing depends on size, so cache is keyed on barcode+size.
  const ck = cacheURL(`${code}:${sizeValue ?? ""}:${sizeUnit ?? ""}`);
  try { const hit = await caches.default.match(ck); if (hit) return json({ ...(await hit.json()), cached: true }); } catch {}

  const ra = await lookupProduct(env, code, { crossRetailer: true });
  if (!ra.ok) {
    if (ra.status === 404) return json({ schemaVersion: 1, barcode: code, found: false }, 200);
    if (ra.status === 429) return errJson(429, "Price service rate limited", { code: "rateLimited", requestId, retryAfter: ra.retryAfter || 60, extra: { retryAfter: ra.retryAfter } });
    return errJson(502, "Price lookup failed", { code: "upstreamError", requestId, extra: { upstreamStatus: ra.status } });
  }

  const norm = normalizeForCompare(ra.data, { sizeValue, sizeUnit });
  if (!norm || norm.prices.length === 0) {
    return json({ schemaVersion: 1, barcode: code, found: false }, 200);
  }

  const payload = {
    schemaVersion: 1, barcode: code, found: true,
    product: norm.product, prices: norm.prices, cheapest: norm.cheapest, source: "retailerapi",
  };
  try {
    await caches.default.put(ck, new Response(JSON.stringify(payload), {
      headers: { "Cache-Control": "max-age=" + CACHE_TTL_S, "Content-Type": "application/json" },
    }));
  } catch {}
  logEvent({ event: "priceCompare", retailers: norm.prices.length });
  return json(payload);
}
