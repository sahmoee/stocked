// barcodes.js — POST /barcodes/resolve (new function).
//
// Looks up a UPC/EAN in a real product database (OpenFoodFacts — free, no key)
// and normalizes the result. This REPLACES asking the LLM to guess a product from
// a raw barcode number, which it hallucinates; a real DB is far more accurate.
// Successful lookups are cached (barcodes are stable) so repeat scans are instant
// and never hit the external service.

import { json, errJson, readBoundedJSON, background, logEvent } from "./util.js";
import { validateBarcodeResolve } from "./validation.js";
import { hasRetailerApi, lookupProduct, normalizeForBarcode } from "./retailerapi.js";

const OFF_URL = (code) => `https://world.openfoodfacts.org/api/v2/product/${code}.json`;
const TIMEOUT_MS = 6000;
const CACHE_TTL_S = 30 * 24 * 3600;      // positive results: barcodes are stable
const NEG_CACHE_TTL_S = 24 * 3600;       // negative results: retry the DB daily, not per scan
const MAX_BODY = 16 * 1024;
const cacheURL = (code) => `https://barcode.internal/${code}`;
const negCacheURL = (key) => `https://barcode-neg.internal/${key}`;

async function timedFetch(url) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), TIMEOUT_MS);
  try { return await fetch(url, { signal: c.signal, headers: { "User-Agent": "Stocked/1.0 (+worker)" } }); }
  finally { clearTimeout(t); }
}

// Categories → a conservative storage zone. Defaults to Pantry when unsure so we
// never wrongly send a shelf-stable item to the fridge.
export function suggestZone(tags) {
  const t = (tags || []).join(" ").toLowerCase();
  if (/frozen/.test(t)) return "Freezer";
  // Stem-based so plurals in OpenFoodFacts tags match (en:dairies, en:cheeses, en:yogurts…).
  if (/dair|\bmilk|yogur|cheese|\bbutter|\begg|meat|poultry|seafood|\bfish|charcuterie|deli|\bcream/.test(t)) return "Fridge";
  if (/spice|seasoning|condiment|sauce|oil|vinegar|baking|flour|sugar|canned|pasta|\brice|cereal/.test(t)) return "Staples";
  return "Pantry";
}

export function normalize(product) {
  const n = product.nutriments || {};
  const num = (v) => (Number.isFinite(v) ? v : null);
  const allergens = (product.allergens_tags || []).map((a) => a.replace(/^en:/, "")).filter(Boolean);
  const cats = product.categories_tags || [];
  return {
    name: product.product_name || product.generic_name || "",
    brand: (product.brands || "").split(",")[0].trim() || null,
    packageQuantity: product.quantity || null,
    nutrition: {
      caloriesPer100g: num(n["energy-kcal_100g"]),
      proteinPer100g: num(n["proteins_100g"]),
      fatPer100g: num(n["fat_100g"]),
      carbsPer100g: num(n["carbohydrates_100g"]),
      sugarsPer100g: num(n["sugars_100g"]),
      sodiumPer100g: num(n["sodium_100g"]),
    },
    allergens,
    category: (product.categories || "").split(",").pop()?.trim() || (cats[cats.length - 1] || "").replace(/^en:/, "") || null,
    image: product.image_url || product.image_front_url || null,
    suggestedZone: suggestZone(cats),
  };
}

const PRICE_TTL_S = 12 * 3600;   // prices change → short cache (food data stays 30d)
const priceCacheURL = (code) => `https://barcode-price.internal/${code}`;

/** OpenFoodFacts food data, cached long (barcodes are stable). */
async function foodDataFor(code) {
  try { const hit = await caches.default.match(cacheURL(code)); if (hit) return await hit.json(); } catch {}
  let resolved = null;
  try {
    const res = await timedFetch(OFF_URL(code));
    if (res.ok) { const data = await res.json(); if (data.status === 1 && data.product) resolved = normalize(data.product); }
  } catch (e) { logEvent({ event: "barcodeLookupError", error: String((e && e.message) || e) }); }
  if (resolved && resolved.name) {
    try { await caches.default.put(cacheURL(code), new Response(JSON.stringify(resolved), { headers: { "Cache-Control": "max-age=" + CACHE_TTL_S, "Content-Type": "application/json" } })); } catch {}
  }
  return resolved;
}

/** retailerapi price + where-to-buy, key-gated, cached short (prices change). */
async function commerceFor(env, code) {
  if (!hasRetailerApi(env)) return null;
  try { const hit = await caches.default.match(priceCacheURL(code)); if (hit) return await hit.json(); } catch {}
  const ra = await lookupProduct(env, code, { crossRetailer: false });
  if (!ra.ok) return null;
  const c = normalizeForBarcode(ra.data);
  if (c) { try { await caches.default.put(priceCacheURL(code), new Response(JSON.stringify(c), { headers: { "Cache-Control": "max-age=" + PRICE_TTL_S, "Content-Type": "application/json" } })); } catch {} }
  return c;
}

export async function handleBarcodeResolve(request, env, ctx, requestId) {
  const read = await readBoundedJSON(request, MAX_BODY);
  if (!read.ok) return errJson(read.status, read.message || "Bad request", { code: read.code, requestId });
  const body = read.value || {};
  const v = validateBarcodeResolve(body);
  if (!v.ok) return errJson(422, "Validation failed", { code: "invalidInput", requestId, extra: { errors: v.errors } });
  const code = v.code;

  // Food data (OpenFoodFacts) + optional price (retailerapi) in parallel. The app
  // can pass includePrice:false to skip the retailer call and conserve quota.
  const wantPrice = body.includePrice !== false;

  // Negative-result cache: a miss is remembered for 24h so repeat scans of an
  // unknown code don't re-hit OpenFoodFacts every time. Keyed on code+wantPrice
  // because a price-included lookup can succeed where a food-only one missed.
  const negKey = negCacheURL(`${code}:${wantPrice ? 1 : 0}`);
  try {
    const negHit = await caches.default.match(negKey);
    if (negHit) return json({ schemaVersion: 1, barcode: code, found: false, cached: true }, 200);
  } catch {}

  const [resolved, commerce] = await Promise.all([
    foodDataFor(code),
    wantPrice ? commerceFor(env, code) : Promise.resolve(null),
  ]);

  const haveFood = !!(resolved && resolved.name);
  const haveCommerce = !!(commerce && (commerce.title || commerce.price));
  if (!haveFood && !haveCommerce) {
    background(ctx, (async () => {
      try {
        await caches.default.put(negKey, new Response("0", {
          headers: { "Cache-Control": "max-age=" + NEG_CACHE_TTL_S, "Content-Type": "text/plain" },
        }));
      } catch {}
    })());
    return json({ schemaVersion: 1, barcode: code, found: false }, 200);
  }

  // Base = OpenFoodFacts food attributes; fall back to retailerapi identity if OFF missed.
  const product = resolved || {
    name: commerce.title || "", brand: commerce.brand || null, packageQuantity: null,
    nutrition: {}, allergens: [], category: null, image: commerce.image || null, suggestedZone: "Pantry",
  };
  if (commerce) {
    if (commerce.price) product.price = commerce.price;
    if (commerce.retailers && commerce.retailers.length) product.retailers = commerce.retailers;
    if (!product.image && commerce.image) product.image = commerce.image;
  }
  const source = [haveFood ? "OpenFoodFacts" : null, haveCommerce ? "retailerapi" : null].filter(Boolean).join("+");
  logEvent({ event: "barcodeResolved", found: true, source });
  return json({ schemaVersion: 1, barcode: code, found: true, product, source });
}
