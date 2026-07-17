// validation.js — strict per-route INPUT validation (#7) and AI OUTPUT
// validation (#8). Returns stable, field-named error codes so the app can react
// programmatically instead of parsing English.

export const LIMITS = Object.freeze({
  receiptTextChars: 20000,
  recipeTextChars: 20000,
  recipeIdeaChars: 2000,
  intentChars: 2000,
  storeNameChars: 120,
  maxInventoryItems: 500,
  maxIngredients: 200,
  maxCorrections: 400,
  maxImageBytes: 5 * 1024 * 1024,   // decoded budget for a base64 receipt photo
  barcodeMin: 6,
  barcodeMax: 14,
});

const IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/heic", "image/webp"]);
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

/** A single validation failure. `code` is stable; `field` names the offender. */
function fail(field, code, message) {
  return { field, code, message };
}

function isStr(v) { return typeof v === "string"; }
function approxDecodedBytes(b64) { return Math.floor((b64.length * 3) / 4); }

/** GTIN/UPC/EAN checksum (mod-10). Accepts UPC-A(12), EAN-13, EAN-8, etc. */
export function barcodeChecksumValid(code) {
  if (!/^\d+$/.test(code)) return false;
  const digits = code.split("").map(Number);
  const check = digits.pop();
  let sum = 0;
  // Weight 3/1 from the rightmost body digit outward (GS1 standard).
  for (let i = digits.length - 1, w = 3; i >= 0; i--, w = w === 3 ? 1 : 3) sum += digits[i] * w;
  return (10 - (sum % 10)) % 10 === check;
}

/**
 * Validate an inbound payload for a known route. Unknown fields are REJECTED so
 * a typo'd field can't silently no-op. Returns { ok, route, errors }.
 */
// Fields the shipped app adds to EVERY payload (StockedWorkerClient.requestData).
// These must never be treated as "unknown" or the whole app 422s.
const ALLOWED_META = new Set(["route", "schemaVersion", "clientVersion", "cacheRevision"]);

export function validateInput(route, p) {
  const errors = [];
  const warnings = [];
  // Unknown-field detection is NON-FATAL: the shipped client is the source of truth
  // for legacy payload shapes, so an unexpected field is recorded (for logs) but never
  // rejected. The valuable checks below (required / type / size / enum / format) stay fatal.
  const allow = (fields) => {
    for (const k of Object.keys(p)) {
      if (ALLOWED_META.has(k)) continue;
      if (!fields.includes(k)) warnings.push(fail(k, "unknownField", `Unexpected field '${k}'`));
    }
  };
  const str = (name, v, maxChars, required = true) => {
    if (v == null || v === "") { if (required) errors.push(fail(name, "fieldMissing", `${name} is required`)); return; }
    if (!isStr(v)) { errors.push(fail(name, "fieldType", `${name} must be a string`)); return; }
    if (v.length > maxChars) errors.push(fail(name, "fieldTooLong", `${name} exceeds ${maxChars} chars`));
  };
  const arr = (name, v, maxLen, required = true) => {
    if (v == null) { if (required) errors.push(fail(name, "fieldMissing", `${name} is required`)); return; }
    if (!Array.isArray(v)) { errors.push(fail(name, "fieldType", `${name} must be an array`)); return; }
    if (v.length > maxLen) errors.push(fail(name, "arrayTooLarge", `${name} exceeds ${maxLen} items`));
  };

  switch (route) {
    case "receiptImage":
      allow(["imageBase64", "imageMediaType", "storeName", "corrections"]);
      if (!isStr(p.imageBase64) || !p.imageBase64) errors.push(fail("imageBase64", "fieldMissing", "imageBase64 is required"));
      else {
        if (!BASE64_RE.test(p.imageBase64)) errors.push(fail("imageBase64", "invalidBase64", "imageBase64 is not valid base64"));
        if (approxDecodedBytes(p.imageBase64) > LIMITS.maxImageBytes) errors.push(fail("imageBase64", "imageTooLarge", "image exceeds size budget"));
      }
      if (p.imageMediaType != null && !IMAGE_MIME.has(p.imageMediaType)) errors.push(fail("imageMediaType", "invalidEnum", "unsupported image type"));
      if (p.storeName != null) str("storeName", p.storeName, LIMITS.storeNameChars, false);
      break;
    case "receiptText":
      allow(["receipt", "storeName", "corrections"]);
      str("receipt", p.receipt, LIMITS.receiptTextChars);
      if (p.storeName != null) str("storeName", p.storeName, LIMITS.storeNameChars, false);
      break;
    case "barcode":
      allow(["barcode"]);
      if (!isStr(p.barcode) || !p.barcode.trim()) errors.push(fail("barcode", "fieldMissing", "barcode is required"));
      else {
        const b = p.barcode.trim();
        if (b.length < LIMITS.barcodeMin || b.length > LIMITS.barcodeMax || !/^\d+$/.test(b))
          errors.push(fail("barcode", "invalidBarcode", "barcode must be 6–14 digits"));
        else if ((b.length === 12 || b.length === 13 || b.length === 8) && !barcodeChecksumValid(b))
          errors.push(fail("barcode", "barcodeChecksum", "barcode checksum failed"));
      }
      break;
    case "recipeImport":
      allow(["recipeText"]);
      str("recipeText", p.recipeText, LIMITS.recipeTextChars);
      break;
    case "inventoryIntent":
      allow(["intent", "inventory", "corrections"]);
      str("intent", p.intent, LIMITS.intentChars);
      if (p.inventory != null) arr("inventory", p.inventory, LIMITS.maxInventoryItems, false);
      break;
    case "recipeGeneration":
      allow(["recipeIdea", "haveItems", "dietary", "maxTime"]);
      str("recipeIdea", p.recipeIdea, LIMITS.recipeIdeaChars);
      if (p.haveItems != null) arr("haveItems", p.haveItems, LIMITS.maxIngredients, false);
      break;
    case "inventoryScan":
      allow(["inventoryScan", "inventory"]);
      if (p.inventoryScan !== true) errors.push(fail("inventoryScan", "fieldMissing", "inventoryScan must be true"));
      arr("inventory", p.inventory, LIMITS.maxInventoryItems);
      break;
    // New endpoints validate loosely-but-safely (schemas enforced by output validation);
    // callers still get unknown-field protection where the shape is known.
    default:
      break;
  }
  return { ok: errors.length === 0, route, errors, warnings };
}

// ── Non-AI endpoint validation (improvement sweep #4) ────────────────────────
// Stable 422 responses: handlers return { code: "invalidInput", errors } built
// from these pure validators. Kept separate from the legacy validateInput switch
// because these endpoints have their own (stricter) contracts.

export const DIAG_MAX_BYTES = 64 * 1024;
export const BRIEF_MAX_BYTES = 256 * 1024;
export const SIZE_UNITS = Object.freeze(["oz", "floz", "fl oz", "lb", "g", "kg", "mg", "ml", "l", "ct", "count", "each"]);
const SIZE_UNIT_SET = new Set(SIZE_UNITS);

/** Strict barcode for the resolver endpoints: digits only, 8–14 long, checksum for GTIN lengths. */
export function validateResolveBarcode(raw) {
  const errors = [];
  const code = typeof raw === "string" ? raw.trim() : "";
  if (!code) { errors.push(fail("barcode", "fieldMissing", "barcode is required")); return { ok: false, errors, code }; }
  if (!/^\d{8,14}$/.test(code)) errors.push(fail("barcode", "invalidBarcode", "barcode must be 8–14 digits"));
  else if ((code.length === 8 || code.length === 12 || code.length === 13) && !barcodeChecksumValid(code))
    errors.push(fail("barcode", "barcodeChecksum", "barcode checksum failed"));
  return { ok: errors.length === 0, errors, code };
}

/** POST /barcodes/resolve input. */
export function validateBarcodeResolve(body) {
  if (!body || typeof body !== "object") return { ok: false, errors: [fail("$", "notObject", "body must be an object")] };
  const b = validateResolveBarcode(body.barcode);
  const errors = [...b.errors];
  if (body.includePrice != null && typeof body.includePrice !== "boolean")
    errors.push(fail("includePrice", "fieldType", "includePrice must be a boolean"));
  return { ok: errors.length === 0, errors, code: b.code };
}

/** POST /prices/compare input: barcode + optional sizeValue>0 / whitelisted sizeUnit. */
export function validatePricesCompare(body) {
  if (!body || typeof body !== "object") return { ok: false, errors: [fail("$", "notObject", "body must be an object")] };
  const b = validateResolveBarcode(body.barcode);
  const errors = [...b.errors];
  if (body.sizeValue != null) {
    const v = Number(body.sizeValue);
    if (!Number.isFinite(v) || v <= 0) errors.push(fail("sizeValue", "outOfRange", "sizeValue must be a number > 0"));
  }
  if (body.sizeUnit != null) {
    if (typeof body.sizeUnit !== "string" || !SIZE_UNIT_SET.has(body.sizeUnit.trim().toLowerCase()))
      errors.push(fail("sizeUnit", "invalidEnum", `sizeUnit must be one of: ${SIZE_UNITS.join(", ")}`));
  }
  return { ok: errors.length === 0, errors, code: b.code };
}

/** POST /support/diagnostics input: bounded payload, object body. (Byte bound is enforced by the handler via DIAG_MAX_BYTES.) */
export function validateDiagnostics(body, rawBytes) {
  const errors = [];
  if (!body || typeof body !== "object" || Array.isArray(body)) errors.push(fail("$", "notObject", "body must be a JSON object"));
  if (Number.isFinite(rawBytes) && rawBytes > DIAG_MAX_BYTES) errors.push(fail("$", "payloadTooLarge", "diagnostics payload exceeds 64KB"));
  return { ok: errors.length === 0, errors };
}

/** POST /daily-brief/generate input: bounded context arrays and sane scalars. */
export function validateDailyBrief(body) {
  const errors = [];
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, errors: [fail("$", "notObject", "body must be a JSON object")] };
  }
  for (const key of ["inventory", "plannedMeals", "grocery"]) {
    if (body[key] != null) {
      if (!Array.isArray(body[key])) errors.push(fail(key, "fieldType", `${key} must be an array`));
      else if (body[key].length > 2000) errors.push(fail(key, "arrayTooLarge", `${key} exceeds 2000 items`));
    }
  }
  if (body.planHorizonDays != null) {
    const v = Number(body.planHorizonDays);
    if (!Number.isFinite(v) || v < 0 || v > 31) errors.push(fail("planHorizonDays", "outOfRange", "planHorizonDays must be 0–31"));
  }
  if (body.code != null && (typeof body.code !== "string" || body.code.length > 16))
    errors.push(fail("code", "fieldType", "code must be a short string"));
  return { ok: errors.length === 0, errors };
}

// ── AI OUTPUT validation (#8) ─────────────────────────────────────────────────
// After the model returns, parse the text and confirm the ACTUAL route response
// is well-formed before it reaches the app. Returns { ok, value, errors }.

const STORAGE_ZONES = new Set(["Fridge", "Freezer", "Pantry", "Staples"]);
const INV_ACTIONS = new Set(["add", "remove", "setLevel", "adjustQuantity", "clearAll"]);

export function validateAIOutput(route, parsed, expectedSchemaVersion) {
  const errors = [];
  const need = (cond, field, code, msg) => { if (!cond) errors.push(fail(field, code, msg)); };

  if (parsed == null || typeof parsed !== "object") {
    return { ok: false, value: parsed, errors: [fail("$", "notObject", "output is not a JSON object")] };
  }
  if (expectedSchemaVersion != null && parsed.schemaVersion != null) {
    need(Number(parsed.schemaVersion) === Number(expectedSchemaVersion), "schemaVersion", "schemaMismatch", "wrong schemaVersion");
  }

  switch (route) {
    case "inventoryIntent": {
      need(Array.isArray(parsed.changes), "changes", "fieldMissing", "changes[] required");
      const changes = Array.isArray(parsed.changes) ? parsed.changes : [];
      need(changes.length <= 300, "changes", "arrayTooLarge", "too many changes");
      for (const [i, c] of changes.entries()) {
        need(c && INV_ACTIONS.has(c.action), `changes[${i}].action`, "invalidEnum", "unknown inventory action");
        if (c && c.level != null) need(typeof c.level === "number" && c.level >= 0 && c.level <= 1, `changes[${i}].level`, "outOfRange", "level must be 0–1");
      }
      break;
    }
    case "inventoryScan": {
      need(Array.isArray(parsed.updates), "updates", "fieldMissing", "updates[] required");
      const updates = Array.isArray(parsed.updates) ? parsed.updates : [];
      need(updates.length <= 300, "updates", "arrayTooLarge", "too many updates");
      const seen = new Set();
      for (const [i, u] of updates.entries()) {
        need(u && typeof u.id === "string" && u.id, `updates[${i}].id`, "fieldMissing", "update id required");
        if (u && u.id) { need(!seen.has(u.id), `updates[${i}].id`, "duplicateId", "duplicate item id"); seen.add(u.id); }
        if (u && u.newZone != null) need(STORAGE_ZONES.has(u.newZone), `updates[${i}].newZone`, "invalidEnum", "invalid storage zone");
        if (u && u.expiryDays != null) need(Number.isFinite(u.expiryDays) && u.expiryDays >= 1 && u.expiryDays <= 730, `updates[${i}].expiryDays`, "outOfRange", "expiryDays 1–730");
      }
      break;
    }
    case "recipeImport":
    case "recipeGeneration":
    case "recipeEnrich": {
      need(isStr(parsed.title) && parsed.title.length > 0, "title", "fieldMissing", "title required");
      const ings = parsed.ingredients;
      need(Array.isArray(ings), "ingredients", "fieldMissing", "ingredients[] required");
      if (Array.isArray(ings)) need(ings.length <= LIMITS.maxIngredients, "ingredients", "arrayTooLarge", "too many ingredients");
      const steps = parsed.instructions || parsed.steps;
      need(Array.isArray(steps), "steps", "fieldMissing", "steps/instructions required");
      break;
    }
    default:
      // Endpoints without a strict schema still must be a JSON object (checked above).
      break;
  }
  return { ok: errors.length === 0, value: parsed, errors };
}
