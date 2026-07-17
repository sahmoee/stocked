// retailerapi.js — client for retailerapi.com (real cross-retailer product +
// price data by UPC/EAN). Contract mirrored from the official MCP server source:
//   GET https://api.retailerapi.com/v1/products/<identifier>
//   Authorization: Bearer <RETAILERAPI_KEY>;  Accept: application/json
//   ?include_cross_retailer=true  → cross_retailer{ slug: {price,url,in_stock,status} }
//
// Free tier is 1,000 lookups/month, so callers MUST cache (both endpoints do).
// Everything is key-gated: with no RETAILERAPI_KEY, hasRetailerApi() is false and
// callers skip it entirely (barcode resolve still returns OpenFoodFacts data).

const BASE = "https://api.retailerapi.com/v1";
const TIMEOUT_MS = 6000;

export function hasRetailerApi(env) { return !!(env && env.RETAILERAPI_KEY); }

async function apiGet(env, path, query = {}) {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) if (v != null && v !== "") params.set(k, String(v));
  const url = `${BASE}${path}${params.toString() ? "?" + params.toString() : ""}`;
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(url, {
      signal: c.signal,
      headers: {
        Authorization: `Bearer ${env.RETAILERAPI_KEY}`,
        Accept: "application/json",
        "User-Agent": "Stocked-Worker/1.0",
      },
    });
    if (r.status === 429) return { ok: false, status: 429, retryAfter: Number(r.headers.get("retry-after")) || 60 };
    if (!r.ok) return { ok: false, status: r.status };
    const text = await r.text();
    try { return { ok: true, data: JSON.parse(text) }; }
    catch { return { ok: false, status: 502 }; }
  } catch (e) {
    return { ok: false, status: (e && e.name === "AbortError") ? 504 : 502 };
  } finally { clearTimeout(t); }
}

/** Base product lookup (1 token). crossRetailer=true adds the price map (+2 tokens). */
export async function lookupProduct(env, identifier, { crossRetailer = false } = {}) {
  return apiGet(env, `/products/${encodeURIComponent(identifier)}`, {
    include_cross_retailer: crossRetailer ? "true" : undefined,
  });
}

function num(v) { if (v == null || v === "") return null; const n = typeof v === "number" ? v : Number(v); return Number.isFinite(n) ? n : null; }
function firstImage(d) { return d.image || d.image_url || d.primary_image || null; }

/** Compact fields to fold into a /barcodes/resolve response (price + where to buy). */
export function normalizeForBarcode(d) {
  if (!d || typeof d !== "object") return null;
  const price = num(d.current_price) ?? num(d.buybox_price);
  const retailers = Array.isArray(d.retailer_links)
    ? d.retailer_links.slice(0, 8).map((r) => ({ retailer: r.retailer, url: r.url })).filter((r) => r.retailer && r.url)
    : [];
  return {
    title: typeof d.title === "string" ? d.title : null,
    brand: typeof d.brand === "string" ? d.brand : null,
    image: firstImage(d),
    price: price != null ? { current: price, currency: "USD" } : null,
    retailers,
  };
}

/**
 * Ranked per-retailer prices from a cross_retailer lookup. Includes the anchor
 * product's own current_price as one entry. Optional unit pricing when the caller
 * knows the package size. Returns { product, prices[], cheapest }.
 */
export function normalizeForCompare(d, { sizeValue, sizeUnit } = {}) {
  if (!d || typeof d !== "object") return null;
  const out = [];
  const seen = new Set();
  const add = (retailer, price, url, inStock) => {
    const p = num(price);
    if (!retailer || p == null || p <= 0) return;
    const key = retailer.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ retailer: key, price: p, url: url || null, inStock: inStock ?? null, unitPrice: unitPriceFor(p, sizeValue, sizeUnit) });
  };

  // Anchor retailer (base call).
  const anchor = String(d.retailer || d.source_retailer || "primary");
  add(anchor, d.current_price ?? d.buybox_price, d.walmart_url || d.url, null);

  // Cross-retailer cells.
  const cr = d.cross_retailer;
  if (cr && typeof cr === "object" && !Array.isArray(cr)) {
    for (const [slug, cell] of Object.entries(cr)) {
      if (!cell || (cell.status && cell.status !== "ok" && cell.status !== "stale")) continue;
      add(cell.retailer || slug, cell.price, cell.url, cell.in_stock);
    }
  }

  out.sort((a, b) => a.price - b.price);
  return {
    product: { title: typeof d.title === "string" ? d.title : null, brand: typeof d.brand === "string" ? d.brand : null, image: firstImage(d) },
    prices: out,
    cheapest: out[0] || null,
  };
}

// Simple unit-price normalization. Weight units also get per-oz / per-lb.
function unitPriceFor(price, sizeValue, sizeUnit) {
  const size = Number(sizeValue);
  if (!Number.isFinite(size) || size <= 0 || !sizeUnit) return null;
  const unit = String(sizeUnit).toLowerCase();
  const per = { unit: `per ${unit}`, value: round(price / size) };
  const toOz = { oz: 1, lb: 16, g: 0.035274, kg: 35.274, ml: null, l: null };
  if (toOz[unit]) {
    const oz = size * toOz[unit];
    per.perOz = round(price / oz);
    per.perLb = round(price / (oz / 16));
  }
  return per;
}
function round(n) { return Math.round(n * 1000) / 1000; }
