// smart.js — "fully worked" Worker intelligence. Self-contained, deterministic, edge-cached.
// Pure functions are exported so tests can pin their behavior (see tests/smart.test.mjs).
//
// Endpoints (all key-gated like the rest, all fully functional — no external services):
//   GET  /units/convert?value=&from=&to=&ingredient=     unit conversion (vol↔mass via density)
//   GET  /units/parse?q=                                  parse "1 1/2 cups flour"
//   POST /recipe/scale        {ingredients[], factor|from|to}   scale ingredient lines
//   POST /recipe/pantry-match {pantry[], ingredients[]}         makeability + missing
//   POST /ingredients/normalize {names[]}                       canonical names
//   GET  /ingredients/substitute?name=&diet=                    substitutions w/ ratios + diet filter
//   POST /grocery/optimize    {items[]}                         dedupe/merge/aisle-sort
//   POST /grocery/from-recipes {recipes:[{ingredients[]}]}      combined shopping list
//   POST /nutrition/estimate  {ingredients[]}                   kcal/macros estimate
//   GET  /expiry/estimate?name=&storage=                        shelf-life days (crowd-aware)
//   GET  /season/produce?month=&region=                        in-season produce
//   POST /meal-plan/suggest   {pantry[], days}                  meals you can mostly make
//   POST /barcodes/batch      {codes[]}                         resolve many barcodes at once

import { json, errJson, withCors, background } from "./util.js";
import { handleBarcodeResolve } from "./barcodes.js";

// ── Unit tables ───────────────────────────────────────────────────────────────
const VOL_ML = {
  tsp: 4.92892, teaspoon: 4.92892, teaspoons: 4.92892,
  tbsp: 14.7868, tablespoon: 14.7868, tablespoons: 14.7868,
  cup: 236.588, cups: 236.588, ml: 1, milliliter: 1, milliliters: 1,
  l: 1000, liter: 1000, litre: 1000, liters: 1000,
  floz: 29.5735, "fl oz": 29.5735, pint: 473.176, pt: 473.176,
  quart: 946.353, qt: 946.353, gallon: 3785.41, gal: 3785.41,
  dash: 0.616, pinch: 0.308,
};
const MASS_G = {
  g: 1, gram: 1, grams: 1, kg: 1000, kilogram: 1000, kilograms: 1000, mg: 0.001,
  oz: 28.3495, ounce: 28.3495, ounces: 28.3495, lb: 453.592, lbs: 453.592, pound: 453.592, pounds: 453.592,
};
const DENSITY = { // g per ml
  water: 1.0, milk: 1.03, flour: 0.53, "all-purpose flour": 0.53, "bread flour": 0.53,
  sugar: 0.845, "granulated sugar": 0.845, "brown sugar": 0.9, "powdered sugar": 0.56,
  butter: 0.911, honey: 1.42, oil: 0.918, "olive oil": 0.918, "vegetable oil": 0.918,
  rice: 0.85, salt: 1.217, "cocoa powder": 0.52, "rolled oats": 0.41, oats: 0.41,
  cornstarch: 0.54, "maple syrup": 1.37, cream: 1.01, yogurt: 1.03,
};
const UNI_FRAC = { "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875 };

export function density(ingredient) {
  const n = normalizeIngredient(ingredient || "");
  if (DENSITY[n] != null) return DENSITY[n];
  for (const k of Object.keys(DENSITY)) if (n.includes(k)) return DENSITY[k];
  return 1.0;
}

export function convertUnits(value, from, to, ingredient) {
  const f = String(from || "").toLowerCase().trim(), t = String(to || "").toLowerCase().trim();
  const v = Number(value);
  if (!isFinite(v)) throw new Error("value must be a number");
  const fVol = VOL_ML[f], tVol = VOL_ML[t], fMass = MASS_G[f], tMass = MASS_G[t];
  let out;
  if (fVol != null && tVol != null) out = v * fVol / tVol;
  else if (fMass != null && tMass != null) out = v * fMass / tMass;
  else if (fVol != null && tMass != null) out = (v * fVol * density(ingredient)) / tMass;   // vol→mass
  else if (fMass != null && tVol != null) out = (v * fMass / density(ingredient)) / tVol;   // mass→vol
  else throw new Error(`cannot convert ${from} → ${to}`);
  return Math.round(out * 1000) / 1000;
}

// ── Quantity parsing / formatting ─────────────────────────────────────────────
export function parseQuantity(str) {
  let s = String(str || "").trim();
  for (const [g, val] of Object.entries(UNI_FRAC)) s = s.replace(g, ` ${val} `);
  s = s.replace(/\s+/g, " ").trim();
  // leading number: mixed "1 1/2", fraction "1/2", decimal "1.5", integer "2"
  const m = s.match(/^(\d+\s+\d+\/\d+|\d+\/\d+|\d*\.\d+|\d+)/);
  let value = null, rest = s;
  if (m) {
    const tok = m[1];
    if (/^\d+\s+\d+\/\d+$/.test(tok)) { const [w, fr] = tok.split(/\s+/); const [a, b] = fr.split("/"); value = Number(w) + Number(a) / Number(b); }
    else if (/^\d+\/\d+$/.test(tok)) { const [a, b] = tok.split("/"); value = Number(a) / Number(b); }
    else value = Number(tok);
    rest = s.slice(m[1].length).trim();
  }
  // unit token
  let unit = "", ingredient = rest;
  const words = rest.split(" ");
  if (words.length) {
    const cand = words[0].toLowerCase().replace(/\.$/, "");
    if (VOL_ML[cand] != null || MASS_G[cand] != null || ["clove", "cloves", "can", "cans", "slice", "slices", "piece", "pieces", "stick", "sticks", "package", "pkg"].includes(cand)) {
      unit = cand; ingredient = words.slice(1).join(" ").trim();
    }
  }
  return { value: value == null ? null : Math.round(value * 1000) / 1000, unit, ingredient };
}

export function formatQuantity(v) {
  if (v == null || !isFinite(v)) return "";
  const whole = Math.floor(v), frac = v - whole;
  const table = [[0.125, "1/8"], [0.25, "1/4"], [1 / 3, "1/3"], [0.375, "3/8"], [0.5, "1/2"], [0.625, "5/8"], [2 / 3, "2/3"], [0.75, "3/4"], [0.875, "7/8"]];
  let best = null, bestErr = 0.04;
  for (const [f, label] of table) if (Math.abs(frac - f) < bestErr) { best = label; bestErr = Math.abs(frac - f); }
  if (frac < 0.02) return String(whole);
  if (best) return whole > 0 ? `${whole} ${best}` : best;
  return String(Math.round(v * 100) / 100);
}

export function scaleRecipe(ingredients, factor) {
  const fac = Number(factor);
  return (ingredients || []).map((line) => {
    const p = parseQuantity(line);
    if (p.value == null) return line;
    const scaled = formatQuantity(p.value * fac);
    return [scaled, p.unit, p.ingredient].filter(Boolean).join(" ");
  });
}

// ── Ingredient normalization ──────────────────────────────────────────────────
const QUALIFIERS = ["fresh", "dried", "chopped", "diced", "minced", "sliced", "grated", "shredded",
  "large", "small", "medium", "ripe", "boneless", "skinless", "ground", "whole", "raw", "cooked",
  "to taste", "optional", "finely", "roughly", "peeled", "seeded", "packed", "softened", "melted",
  "room temperature", "cold", "warm", "organic", "low-fat", "reduced-fat", "unsalted", "salted"];
export function normalizeIngredient(name) {
  let n = String(name || "").toLowerCase();
  n = n.replace(/\([^)]*\)/g, " ");                 // drop parentheticals
  n = n.replace(/[^a-z\s-]/g, " ");                 // drop numbers/punct
  for (const q of QUALIFIERS) n = n.replace(new RegExp(`\\b${q}\\b`, "g"), " ");
  n = n.replace(/\s+/g, " ").trim();
  // naive singularize
  n = n.split(" ").map((w) => {
    if (w.endsWith("ies") && w.length > 3) return w.slice(0, -3) + "y";
    if (w.endsWith("oes") && w.length > 3) return w.slice(0, -2);
    if (w.endsWith("s") && !w.endsWith("ss") && w.length > 3) return w.slice(0, -1);
    return w;
  }).join(" ");
  return n.trim();
}

// ── Grocery optimization (aisle categorization) ───────────────────────────────
const AISLES = {
  produce: ["apple", "banana", "lettuce", "tomato", "onion", "garlic", "pepper", "carrot", "potato", "spinach", "broccoli", "lemon", "lime", "herb", "basil", "cilantro", "avocado", "cucumber", "celery", "mushroom"],
  dairy: ["milk", "cheese", "butter", "yogurt", "cream", "egg"],
  meat: ["chicken", "beef", "pork", "turkey", "bacon", "sausage", "steak", "ground"],
  seafood: ["fish", "salmon", "shrimp", "tuna", "cod"],
  bakery: ["bread", "bun", "bagel", "tortilla", "roll", "muffin"],
  pantry: ["flour", "sugar", "rice", "pasta", "bean", "oil", "vinegar", "sauce", "stock", "broth", "spice", "salt", "pepper", "can", "cereal", "oat"],
  frozen: ["frozen", "ice cream"],
  beverages: ["water", "juice", "soda", "coffee", "tea", "wine", "beer"],
};
export function aisleFor(name) {
  const n = normalizeIngredient(name);
  for (const [aisle, kws] of Object.entries(AISLES)) if (kws.some((k) => n.includes(k))) return aisle;
  return "other";
}
export function optimizeGrocery(items) {
  const uNorm = (u) => (u || "").replace(/s$/, "");   // "cups" ≡ "cup"
  const merged = new Map();
  for (const raw of items || []) {
    const text = typeof raw === "string" ? raw : (raw && raw.name) || "";
    const p = parseQuantity(text);
    const nkey = normalizeIngredient(p.ingredient || text);
    if (!nkey) continue;
    const key = nkey + "|" + uNorm(p.unit);           // same ingredient + unit merges; different units stay separate
    const ex = merged.get(key);
    if (ex && ex.value != null && p.value != null) ex.value += p.value;
    else if (!ex) merged.set(key, { name: nkey, value: p.value, unit: p.unit, aisle: aisleFor(nkey) });
  }
  const list = [...merged.values()].map((x) => ({
    name: x.name, aisle: x.aisle,
    quantity: x.value != null ? [formatQuantity(x.value), x.unit].filter(Boolean).join(" ") : "",
  }));
  const order = ["produce", "meat", "seafood", "dairy", "bakery", "frozen", "pantry", "beverages", "other"];
  list.sort((a, b) => order.indexOf(a.aisle) - order.indexOf(b.aisle) || a.name.localeCompare(b.name));
  return list;
}

// ── Pantry match / makeability ────────────────────────────────────────────────
export function pantryMatch(pantry, ingredients) {
  const have = new Set((pantry || []).map(normalizeIngredient).filter(Boolean));
  const need = (ingredients || []).map((x) => normalizeIngredient(typeof x === "string" ? x : (x && x.ingredient) || "")).filter(Boolean);
  const present = [], missing = [];
  for (const n of need) {
    const ok = have.has(n) || [...have].some((h) => n.includes(h) || h.includes(n));
    (ok ? present : missing).push(n);
  }
  const total = need.length || 1;
  return { makeable: missing.length === 0, score: Math.round((present.length / total) * 100) / 100, have: present, missing };
}

// ── Nutrition estimate (per-100g table, heuristic) ────────────────────────────
const KCAL_100G = { // {kcal, p, c, f} per 100 g
  chicken: { kcal: 165, p: 31, c: 0, f: 3.6 }, beef: { kcal: 250, p: 26, c: 0, f: 15 }, egg: { kcal: 143, p: 13, c: 1, f: 10 },
  rice: { kcal: 130, p: 2.7, c: 28, f: 0.3 }, pasta: { kcal: 131, p: 5, c: 25, f: 1.1 }, bread: { kcal: 265, p: 9, c: 49, f: 3.2 },
  flour: { kcal: 364, p: 10, c: 76, f: 1 }, sugar: { kcal: 387, p: 0, c: 100, f: 0 }, butter: { kcal: 717, p: 0.9, c: 0.1, f: 81 },
  oil: { kcal: 884, p: 0, c: 0, f: 100 }, milk: { kcal: 42, p: 3.4, c: 5, f: 1 }, cheese: { kcal: 402, p: 25, c: 1.3, f: 33 },
  potato: { kcal: 77, p: 2, c: 17, f: 0.1 }, tomato: { kcal: 18, p: 0.9, c: 3.9, f: 0.2 }, onion: { kcal: 40, p: 1.1, c: 9, f: 0.1 },
  bean: { kcal: 127, p: 9, c: 22, f: 0.5 }, salmon: { kcal: 208, p: 20, c: 0, f: 13 }, banana: { kcal: 89, p: 1.1, c: 23, f: 0.3 },
};
function gramsFor(p) {
  if (p.value == null) return 100;
  if (MASS_G[p.unit] != null) return p.value * MASS_G[p.unit];
  if (VOL_ML[p.unit] != null) return p.value * VOL_ML[p.unit] * density(p.ingredient);
  return p.value * 100; // count units → assume ~100 g each
}
export function estimateNutrition(ingredients) {
  let kcal = 0, protein = 0, carbs = 0, fat = 0; const items = [];
  for (const line of ingredients || []) {
    const p = parseQuantity(typeof line === "string" ? line : (line && line.text) || "");
    const n = normalizeIngredient(p.ingredient || String(line));
    let ref = KCAL_100G[n];
    if (!ref) { const k = Object.keys(KCAL_100G).find((x) => n.includes(x)); ref = k ? KCAL_100G[k] : null; }
    if (!ref) { items.push({ name: n, kcal: null, note: "unknown" }); continue; }
    const g = gramsFor(p), scale = g / 100;
    const kc = Math.round(ref.kcal * scale);
    kcal += kc; protein += ref.p * scale; carbs += ref.c * scale; fat += ref.f * scale;
    items.push({ name: n, grams: Math.round(g), kcal: kc });
  }
  return { items, total: { kcal: Math.round(kcal), protein: Math.round(protein), carbs: Math.round(carbs), fat: Math.round(fat) } };
}

// ── Expiry estimate ───────────────────────────────────────────────────────────
const SHELF = { // days by category and storage
  dairy: { fridge: 7, freezer: 90, pantry: 0 }, meat: { fridge: 3, freezer: 180, pantry: 0 },
  seafood: { fridge: 2, freezer: 120, pantry: 0 }, produce: { fridge: 7, freezer: 240, pantry: 4 },
  bakery: { fridge: 7, freezer: 90, pantry: 4 }, pantry: { fridge: 365, freezer: 365, pantry: 365 },
  eggs: { fridge: 28, freezer: 0, pantry: 0 }, leftovers: { fridge: 4, freezer: 60, pantry: 0 },
};
function categoryOf(name) {
  const n = normalizeIngredient(name);
  if (/(egg)/.test(n)) return "eggs";
  for (const [aisle, kws] of Object.entries(AISLES)) if (kws.some((k) => n.includes(k))) {
    if (aisle === "dairy") return "dairy"; if (aisle === "meat") return "meat"; if (aisle === "seafood") return "seafood";
    if (aisle === "produce") return "produce"; if (aisle === "bakery") return "bakery"; if (aisle === "pantry") return "pantry";
  }
  return "pantry";
}
export function expiryDays(name, storage) {
  const cat = categoryOf(name); const st = ["fridge", "freezer", "pantry"].includes(storage) ? storage : "fridge";
  const days = (SHELF[cat] || SHELF.pantry)[st];
  return { category: cat, storage: st, days };
}

// ── Seasonal produce (US default) ─────────────────────────────────────────────
const SEASON_US = {
  1: ["kale", "citrus", "leek", "cabbage"], 2: ["citrus", "broccoli", "brussels sprouts"], 3: ["asparagus", "peas", "spinach"],
  4: ["asparagus", "strawberry", "artichoke"], 5: ["strawberry", "rhubarb", "spinach"], 6: ["berries", "zucchini", "corn", "tomato"],
  7: ["tomato", "corn", "peach", "watermelon", "berries"], 8: ["tomato", "pepper", "eggplant", "peach"], 9: ["apple", "squash", "grape"],
  10: ["pumpkin", "apple", "squash", "sweet potato"], 11: ["squash", "cranberry", "brussels sprouts"], 12: ["citrus", "pomegranate", "kale"],
};
export function seasonProduce(month) {
  const m = Math.min(12, Math.max(1, Number(month) || (new Date().getUTCMonth() + 1)));
  return { month: m, produce: SEASON_US[m] || [] };
}

// ── Substitutions with ratios + dietary filter ────────────────────────────────
const SUBS = {
  butter: [{ sub: "olive oil", ratio: "3/4 amount", vegan: true }, { sub: "coconut oil", ratio: "1:1", vegan: true }, { sub: "applesauce", ratio: "1:1", vegan: true }],
  egg: [{ sub: "flax egg (1 tbsp flax + 3 tbsp water)", ratio: "per egg", vegan: true }, { sub: "applesauce (1/4 cup)", ratio: "per egg", vegan: true }, { sub: "mashed banana (1/4 cup)", ratio: "per egg", vegan: true }],
  milk: [{ sub: "almond milk", ratio: "1:1", vegan: true }, { sub: "oat milk", ratio: "1:1", vegan: true }, { sub: "soy milk", ratio: "1:1", vegan: true }],
  sugar: [{ sub: "honey", ratio: "3/4 amount", vegan: false }, { sub: "maple syrup", ratio: "3/4 amount", vegan: true }, { sub: "stevia", ratio: "to taste", vegan: true }],
  flour: [{ sub: "almond flour", ratio: "1:1", vegan: true, glutenFree: true }, { sub: "oat flour", ratio: "1:1", vegan: true, glutenFree: true }],
  "sour cream": [{ sub: "greek yogurt", ratio: "1:1", vegan: false }, { sub: "coconut cream", ratio: "1:1", vegan: true }],
  buttermilk: [{ sub: "milk + 1 tbsp lemon juice", ratio: "per cup", vegan: false }],
  "heavy cream": [{ sub: "milk + butter", ratio: "3/4 cup milk + 1/4 cup butter per cup", vegan: false }, { sub: "coconut cream", ratio: "1:1", vegan: true }],
};
export function substitutionsFor(name, diet) {
  const n = String(name || "").toLowerCase().trim();
  let list = SUBS[n] || Object.entries(SUBS).find(([k]) => n.includes(k) || k.includes(n))?.[1] || [];
  if (diet === "vegan") list = list.filter((s) => s.vegan);
  if (diet === "gluten-free" || diet === "glutenfree") list = list.filter((s) => s.glutenFree || n !== "flour");
  return list;
}

// ── Oven temperature convert (F ↔ C ↔ gas mark) ──────────────────────────────
const GAS = { 275: 1, 300: 2, 325: 3, 350: 4, 375: 5, 400: 6, 425: 7, 450: 8, 475: 9 };
export function convertTemperature(value, from, to) {
  const v = Number(value); const f = String(from || "").toUpperCase()[0], t = String(to || "").toUpperCase()[0];
  if (!isFinite(v)) throw new Error("value must be a number");
  let c = f === "C" ? v : f === "G" ? null : (v - 32) * 5 / 9;               // to Celsius
  if (f === "G") { const fEntry = Object.entries(GAS).find(([, g]) => g === v); c = fEntry ? (Number(fEntry[0]) - 32) * 5 / 9 : null; }
  if (c == null) throw new Error("cannot convert from " + from);
  if (t === "C") return Math.round(c);
  if (t === "F") return Math.round(c * 9 / 5 + 32);
  if (t === "G") { const fdeg = c * 9 / 5 + 32; let best = null, err = 999; for (const [d, g] of Object.entries(GAS)) if (Math.abs(fdeg - Number(d)) < err) { err = Math.abs(fdeg - Number(d)); best = g; } return best; }
  throw new Error("cannot convert to " + to);
}

// ── Deterministic A/B bucketing (stable per subject) ──────────────────────────
export function abVariant(subject, buckets = ["a", "b"], salt = "") {
  const s = String(salt) + "|" + String(subject || "");
  let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  const idx = (h >>> 0) % buckets.length;
  return buckets[idx];
}

// ── HTTP handlers ─────────────────────────────────────────────────────────────
const ok = (obj) => withCors(json({ ok: true, ...obj }));
const bad = (msg, requestId) => errJson(400, msg, { code: "badInput", requestId });
async function body(request) { try { return await request.json(); } catch { return {}; } }

export async function handleSmartRoute(url, request, env, ctx, requestId) {
  const p = url.pathname, m = request.method, q = url.searchParams;

  if (m === "GET" && p === "/units/convert") {
    try { return ok({ value: convertUnits(q.get("value"), q.get("from"), q.get("to"), q.get("ingredient")), to: q.get("to") }); }
    catch (e) { return bad(String(e.message || e), requestId); }
  }
  if (m === "GET" && p === "/units/parse") return ok({ parsed: parseQuantity(q.get("q") || "") });
  if (m === "POST" && p === "/recipe/scale") {
    const b = await body(request);
    let factor = Number(b.factor);
    if (!isFinite(factor) && b.from && b.to) factor = Number(b.to) / Number(b.from);
    if (!isFinite(factor) || factor <= 0) return bad("factor (or from+to servings) required", requestId);
    return ok({ ingredients: scaleRecipe(b.ingredients || [], factor), factor: Math.round(factor * 1000) / 1000 });
  }
  if (m === "POST" && p === "/recipe/pantry-match") {
    const b = await body(request); return ok(pantryMatch(b.pantry || [], b.ingredients || []));
  }
  if (m === "POST" && p === "/ingredients/normalize") {
    const b = await body(request); return ok({ names: (b.names || []).map(normalizeIngredient) });
  }
  if (m === "GET" && p === "/ingredients/substitute") return ok({ name: q.get("name"), substitutions: substitutionsFor(q.get("name"), q.get("diet")) });
  if (m === "POST" && p === "/grocery/optimize") { const b = await body(request); return ok({ list: optimizeGrocery(b.items || []) }); }
  if (m === "POST" && p === "/grocery/from-recipes") {
    const b = await body(request);
    const all = []; for (const r of b.recipes || []) for (const i of (r.ingredients || [])) all.push(i);
    return ok({ list: optimizeGrocery(all) });
  }
  if (m === "POST" && p === "/nutrition/estimate") { const b = await body(request); return ok(estimateNutrition(b.ingredients || [])); }
  if (m === "GET" && p === "/expiry/estimate") {
    if (!q.get("name")) return bad("name required", requestId);
    const base = expiryDays(q.get("name"), q.get("storage"));
    // Crowd override: if the shared crowd KV has learned a shelf life, prefer it.
    try {
      if (env && env.CROWD) {
        const raw = await env.CROWD.get("shelf:" + normalizeIngredient(q.get("name")));
        if (raw) { const d = Number(JSON.parse(raw).days); if (isFinite(d) && d > 0) return ok({ ...base, days: Math.round(d), source: "crowd" }); }
      }
    } catch {}
    return ok({ ...base, source: "table" });
  }
  if (m === "GET" && p === "/units/temperature") {
    try { return ok({ value: convertTemperature(q.get("value"), q.get("from"), q.get("to")), to: q.get("to") }); }
    catch (e) { return bad(String(e.message || e), requestId); }
  }
  if (m === "GET" && p === "/experiment") {
    const subj = request.headers.get("X-Stocked-Session") || q.get("subject") || "anon";
    const name = q.get("name") || "default";
    const buckets = (q.get("buckets") || "a,b").split(",").map((x) => x.trim()).filter(Boolean);
    return ok({ name, variant: abVariant(subj, buckets, name), buckets });
  }
  if (m === "GET" && p === "/season/produce") return ok(seasonProduce(q.get("month")));
  if (m === "POST" && p === "/meal-plan/suggest") {
    const b = await body(request);
    const seeds = b.recipes || DEFAULT_SEEDS;
    const ranked = seeds.map((r) => ({ title: r.title, ...pantryMatch(b.pantry || [], r.ingredients || []) }))
      .sort((a, z) => z.score - a.score).slice(0, Number(b.days) || 5);
    return ok({ suggestions: ranked });
  }
  if (m === "POST" && p === "/barcodes/batch") {
    const b = await body(request);
    const codes = (b.codes || []).slice(0, 25);
    const results = await Promise.all(codes.map(async (code) => {
      try {
        const req = new Request(url.origin + "/barcodes/resolve", { method: "POST", headers: request.headers, body: JSON.stringify({ barcode: String(code) }) });
        const res = await handleBarcodeResolve(req, env, ctx, requestId);
        const jsonBody = await res.clone().json().catch(() => null);
        return { code, ok: res.ok, product: jsonBody };
      } catch (e) { return { code, ok: false, error: String(e.message || e) }; }
    }));
    return ok({ results });
  }
  return null;
}

const DEFAULT_SEEDS = [
  { title: "Garlic Butter Chicken & Rice", ingredients: ["chicken", "rice", "butter", "garlic", "onion"] },
  { title: "Tomato Basil Pasta", ingredients: ["pasta", "tomato", "garlic", "olive oil", "basil"] },
  { title: "Veggie Fried Rice", ingredients: ["rice", "egg", "carrot", "onion", "soy sauce"] },
  { title: "Black Bean Quesadilla", ingredients: ["tortilla", "bean", "cheese", "pepper"] },
  { title: "Simple Omelette", ingredients: ["egg", "cheese", "milk", "butter"] },
];
