// household-shared.js — pure helpers shared by the Durable Object. These are
// lifted verbatim (behavior-preserving) from the original index.js so the merge,
// tombstone, revision, and sanitize semantics are byte-for-byte identical.

export const HH_MAX_ITEMS = 2000;
export const HH_MAX_ACTIVITY = 200;
export const HH_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export const ROLE_DEFAULTS = {
  owner:   { add: true,  edit: true,  remove: true },
  manager: { add: true,  edit: true,  remove: true },
  adult:   { add: true,  edit: true,  remove: true },
  teen:    { add: true,  edit: true,  remove: false },
  kid:     { add: false, edit: false, remove: false },
  member:  { add: true,  edit: true,  remove: true },
};

export function normalizeCode(raw) {
  if (typeof raw !== "string") return "";
  return raw.toUpperCase().split("").filter((c) => HH_CODE_ALPHABET.includes(c)).join("");
}

export function sanitizeName(raw) {
  if (typeof raw !== "string" || !raw.trim()) return "Member";
  return raw.trim().slice(0, 40);
}

export function sanitizeId(raw) {
  if (typeof raw !== "string") return "";
  return raw.trim().slice(0, 64);
}

export function appendActivity(list, newEvent) {
  let arr = Array.isArray(list) ? list.slice() : [];
  if (newEvent) arr.push(newEvent);
  const seen = new Set();
  arr = arr.filter((event) => {
    const key = [event.kind, event.itemName, event.oldName, event.actorName, event.date].join("|");
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });
  arr.sort((a, b) => (b.date || 0) - (a.date || 0));
  return arr.slice(0, HH_MAX_ACTIVITY);
}

export function mergeLWW(existing, incoming, deleted) {
  const byId = new Map();
  let anon = 0;
  const put = (item) => {
    if (!item) return;
    const key = item.id != null ? String(item.id) : "anon_" + anon++;
    if (deleted && deleted.has(key)) return;
    const prev = byId.get(key);
    if (!prev) { byId.set(key, item); return; }
    const a = Number(item.updatedAt || 0), b = Number(prev.updatedAt || 0);
    const aw = String(item.lastWriterID || ""), bw = String(prev.lastWriterID || "");
    if (a > b || (a === b && aw > bw)) byId.set(key, item);
  };
  for (const it of Array.isArray(existing) ? existing : []) put(it);
  for (const it of Array.isArray(incoming) ? incoming : []) put(it);
  return Array.from(byId.values()).sort((a, b) => String(a.id || "").localeCompare(String(b.id || "")));
}

export function dedupeCap(arr, cap) {
  const seen = new Set();
  const out = [];
  for (const v of Array.isArray(arr) ? arr : []) {
    const s = String(v);
    if (!seen.has(s)) { seen.add(s); out.push(s); }
  }
  return out.slice(-cap);
}

// ── Push idempotency (safe retries) ──────────────────────────────────────────
// The shipped push payload carries NO operation/batch id (inspected: it's the
// content arrays + actorId), so retries are deduped on a hash of the batch
// content + sender. A retry resends byte-identical content, so an identical
// hash within the dedupe window means "already applied".

export const PUSH_DEDUPE_WINDOW_MS = 10 * 60 * 1000; // 10 minutes
export const PUSH_DEDUPE_MAX = 500;                  // rolling set size

// Launch readiness 1.4 — the client's synced feature collections. One list, shared by the
// DO's push merge, the hash fields, and semanticHousehold, so a new collection is one entry here.
export const FEATURE_COLLECTIONS = Object.freeze([
  "leftovers", "familyProfiles", "events", "sharedExpenses",
  "storeLayouts", "gardenHarvests", "containerLabels", "takeoutLog",
]);
const FEATURE_DELETED = FEATURE_COLLECTIONS.map((k) => k + "Deleted");

const PUSH_HASH_FIELDS = Object.freeze([
  "actorId", "inventory", "grocery", "userRecipes", "genRecipes", "plannedMeals",
  "invDeleted", "groDeleted", "userRecipeDeleted", "genRecipeDeleted", "mealDeleted",
  "activity", "householdName", "qa",
  // 1.4 — without these, two pushes differing only in feature data would be wrongly
  // deduped as identical within the 10-minute window.
  ...FEATURE_COLLECTIONS, ...FEATURE_DELETED,
]);

/** Deterministic JSON: object keys sorted recursively so hashing is stable. */
export function stableStringify(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(stableStringify).join(",") + "]";
  const keys = Object.keys(v).sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + stableStringify(v[k])).join(",") + "}";
}

/** FNV-1a 32-bit — cheap, synchronous, good enough for retry dedupe. */
export function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/**
 * Hash of a push batch (content + sender). Returns null when the body carries
 * no content fields at all (nothing worth deduping).
 */
export function pushBatchHash(body) {
  if (!body || typeof body !== "object") return null;
  const relevant = {};
  let hasContent = false;
  for (const f of PUSH_HASH_FIELDS) {
    if (body[f] !== undefined) { relevant[f] = body[f]; if (f !== "actorId") hasContent = true; }
  }
  if (!hasContent) return null;
  return fnv1a(stableStringify(relevant));
}

export function semanticHousehold(household) {
  const copy = JSON.parse(JSON.stringify(household || {}));
  delete copy.updatedAt;
  delete copy.revision;
  // 1.4 — feature collections are sort-normalized too, so a reordering-only push doesn't
  // bump the revision. storeLayouts sorts by store name (its identity).
  for (const key of ["inventory", "grocery", "userRecipes", "genRecipes", "plannedMeals", "members", ...FEATURE_COLLECTIONS]) {
    if (Array.isArray(copy[key])) copy[key].sort((a, b) => String((a && (a.id || a.memberId || a.store)) || "").localeCompare(String((b && (b.id || b.memberId || b.store)) || "")));
  }
  for (const key of ["invDeleted", "groDeleted", "userRecipeDeleted", "genRecipeDeleted", "mealDeleted", ...FEATURE_DELETED]) {
    if (Array.isArray(copy[key])) copy[key] = Array.from(new Set(copy[key].map(String))).sort();
  }
  if (Array.isArray(copy.activity)) copy.activity = appendActivity(copy.activity, null);
  return copy;
}
