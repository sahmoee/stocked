// routes.js — prompt construction for every AI route.
//
// TWO calling conventions, both preserved/added here:
//   • LEGACY (unchanged): the app POSTs a payload to "/" and buildLegacyPrompt()
//     sniffs its shape. The 7 existing routes and their schema versions are kept
//     BYTE-FOR-BYTE so the shipped app keeps parsing content[0].text as before.
//   • NEW: pathname endpoints (POST /recipes/enrich, …) handled by buildRoutePrompt().
//
// ROUTE_SCHEMA stays in this module AND is asserted by tests/contracts.test.mjs.

export const ROUTE_SCHEMA = Object.freeze({
  // ── existing (do not change versions) ──
  receiptText: 2,
  receiptImage: 2,
  barcode: 1,
  recipeImport: 2,
  recipeGeneration: 2,
  inventoryIntent: 2,
  inventoryScan: 2,
  // ── new endpoints ──
  recipeEnrich: 1,
  recipeFix: 1,
  recipeSubstitutions: 1,
  recipeBuildAround: 1,
  receiptReview: 1,
  inventoryNormalize: 1,
  groceryReconcile: 1,
  mealPlanOptimize: 1,
});

const RECEIPT_SYSTEM =
  "You extract grocery line items from a receipt into a JSON array. Each element: " +
  '{"name": string, "quantity": number, "unit": string|null, "price": number|null, "category": string|null}. ' +
  "Resolve abbreviations to real product names, separate brand from the product, and preserve uncertainty by using the safest shelf-stable zone rather than guessing refrigeration. " +
  "Ignore subtotals, tax, totals, loyalty lines, and non-product rows. Output ONLY the JSON array.";

function routePrompt(route, system, user, maxTokens, options = {}) {
  return {
    route, schemaVersion: ROUTE_SCHEMA[route], system, user, maxTokens,
    cacheKey: options.cacheKey || null, cacheTTL: options.cacheTTL || 0,
    validated: options.validated || false,     // true → run through output validation+repair
    passthrough: options.passthrough || false, // true → return raw Anthropic envelope unchanged
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// LEGACY payload-sniffing (verbatim behavior). Returns null if unrecognized.
// ─────────────────────────────────────────────────────────────────────────────
export function buildLegacyPrompt(p) {
  if (typeof p.imageBase64 === "string" && p.imageBase64) {
    const store = p.storeName ? `\nStore: ${p.storeName}` : "";
    const corrections = p.corrections ? `\nKnown corrections (raw → resolved): ${JSON.stringify(p.corrections)}` : "";
    return routePrompt("receiptImage", RECEIPT_SYSTEM, [
      { type: "image", source: { type: "base64", media_type: p.imageMediaType || "image/jpeg", data: p.imageBase64 } },
      { type: "text", text: `Parse this receipt into the JSON array described.${store}${corrections}` },
    ], 3000, { passthrough: true });
  }

  if (typeof p.receipt === "string" && p.receipt.trim()) {
    const store = p.storeName ? `\nStore: ${p.storeName}` : "";
    const corrections = p.corrections ? `\nKnown corrections (raw → resolved): ${JSON.stringify(p.corrections)}` : "";
    return routePrompt("receiptText", RECEIPT_SYSTEM,
      `Receipt OCR text:${store}${corrections}\n\n${p.receipt}`, 3000, { passthrough: true });
  }

  if (typeof p.barcode === "string" && p.barcode.trim()) {
    return routePrompt("barcode",
      "You identify a grocery product from its barcode (UPC/EAN). Respond with ONLY the product name in plain text (brand + product, under 60 characters). If you cannot identify it confidently, respond with exactly \"unknown\".",
      `Barcode: ${p.barcode}`, 120,
      { passthrough: true, cacheKey: `barcode:v${ROUTE_SCHEMA.barcode}:${p.barcode.trim()}`, cacheTTL: 2592000 });
  }

  if (typeof p.recipeText === "string" && p.recipeText.trim()) {
    return routePrompt("recipeImport",
      "Convert pasted recipe text into one JSON object. Output JSON only. Schema: " +
      '{"schemaVersion":2,"title":string,"description":string,"cookTime":string,"prepTime":string,' +
      '"servings":number,"difficulty":"Easy"|"Medium"|"Hard","cuisine":string,"tags":string[],' +
      '"ingredients":[{"name":string,"amount":string}],"instructions":string[]}. ' +
      "Do not invent missing facts. When a step is genuinely implied but absent, prefix that instruction with [Inferred]. " +
      "Keep ingredient names separate from amounts and preparation notes. Ignore navigation, ads, author biography, and comments. " +
      "Example input: Ingredients: 2 eggs. Mix and bake 20 min. Example output has one egg ingredient and two concise instructions, not one giant blob.",
      p.recipeText, 3500, { passthrough: true });
  }

  if (typeof p.intent === "string" && p.intent.trim()) {
    const inv = p.inventory ? JSON.stringify(p.inventory) : "[]";
    const corrections = p.corrections ? `\nKnown corrections: ${JSON.stringify(p.corrections)}` : "";
    return routePrompt("inventoryIntent",
      "Translate a natural-language kitchen update into changes. Output JSON only. Exact schema: " +
      '{"schemaVersion":2,"changes":[{"id":string|null,"name":string,"action":"add"|"remove"|"setLevel"|"adjustQuantity"|"clearAll",' +
      '"level":number|null,"quantity":number|null,"delta":number|null,"containerType":string|null,"sizeAmount":number|null,"sizeUnit":string|null}]}. ' +
      "Use stable ids for existing items. 'used two cans of beans' means adjustQuantity delta -2, not remove, unless quantity reaches zero. " +
      "'finished the milk' means remove. 'bought 3 14 oz cans of tomatoes' means add quantity 3, containerType can, sizeAmount 14, sizeUnit oz. " +
      "If uncertain, omit the change rather than targeting the wrong item. Never match by substring alone: ham must not target graham crackers. " +
      "Example: 'put milk at half' -> setLevel 0.5 for the stable milk id. Example: 'I used cayenne pepper' must target the spice, not a fresh pepper item.",
      `Current inventory: ${inv}${corrections}\n\nUser request: ${p.intent}`, 2200, { validated: true });
  }

  if (typeof p.recipeIdea === "string" && p.recipeIdea.trim()) {
    const have = Array.isArray(p.haveItems) && p.haveItems.length
      ? `\nIngredients the user already has (prefer these, but add common staples as needed): ${p.haveItems.join(", ")}.` : "";
    const diet = typeof p.dietary === "string" && p.dietary.trim() ? `\nDietary requirement: ${p.dietary}. The recipe MUST comply.` : "";
    const time = typeof p.maxTime === "string" && p.maxTime.trim() ? `\nThe recipe should fit roughly within ${p.maxTime} of total time.` : "";
    return routePrompt("recipeGeneration",
      "You are a recipe developer. Create ONE complete, realistic, cookable recipe from the " +
      "user's description. Invent a sensible recipe with real quantities and clear steps; do " +
      "not refuse and do not ask questions. Respond with ONLY a single JSON object, no prose, " +
      "no markdown fences: " +
      '{"schemaVersion": 2, "title": string, "description": string, "cookTime": string, "prepTime": string, ' +
      '"servings": number, "difficulty": "Easy"|"Medium"|"Hard", "cuisine": string, ' +
      '"tags": string[], "ingredients": [{"name": string, "amount": string}], ' +
      '"steps": string[]}. Each step is one clear instruction. Include any cooking or ' +
      "resting time inside the relevant step text (e.g. \"Bake for 12 minutes\") so timers can " +
      "be derived. Include schemaVersion: 2. Keep cookTime and prepTime as short human strings like \"20 minutes\".",
      `Recipe request: ${p.recipeIdea}${have}${diet}${time}`, 4500, { validated: true });
  }

  if (p.inventoryScan === true && Array.isArray(p.inventory)) {
    const rows = p.inventory.slice(0, 120).map((it) => {
      const flags = [];
      if (it && it.hasNutrition) flags.push("hasNutrition");
      if (it && it.hasExpiry) flags.push("hasExpiry");
      const brand = it && it.brand ? ` brand=${it.brand}` : "";
      return `- id=${it && it.id} name=${it && it.name} zone=${it && it.zone}${brand}${flags.length ? " (" + flags.join(",") + ")" : ""}`;
    }).join("\n");
    return routePrompt("inventoryScan",
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
      'ONLY a JSON object, no prose and no markdown fences: {"schemaVersion": 2, "updates": [{"id": string, ' +
      '"newName"?: string, "newZone"?: string, "calories"?: number, "protein"?: number, ' +
      '"servingSize"?: string, "expiryDays"?: number, "reason": string}]}. If nothing needs ' +
      'changing, return {"schemaVersion":2,"updates": []}. Include schemaVersion: 2 in every response.',
      `Inventory to review:\n${rows}`, 4200, { validated: true });
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// NEW pathname endpoints. Each returns a routePrompt or null (bad input).
// All are `validated: true` so output flows through validation + one repair.
// ─────────────────────────────────────────────────────────────────────────────
export function buildRoutePrompt(routeName, p) {
  switch (routeName) {
    case "recipeEnrich":
      if (!p || typeof p.recipe !== "object") return null;
      return routePrompt("recipeEnrich",
        "You complete a partial recipe into Stocked's full schema. Output ONLY JSON: " +
        '{"schemaVersion":1,"title":string,"description":string,"cuisine":string,"difficulty":"Easy"|"Medium"|"Hard",' +
        '"prepTime":string,"cookTime":string,"servings":number,"equipment":string[],' +
        '"ingredients":[{"name":string,"amount":string}],"steps":[{"text":string,"timerMinutes":number|null}],' +
        '"storage":string,"leftovers":string,"confidence":number}. ' +
        "Preserve every fact already present; only fill genuine gaps. Prefix any inferred step with [Inferred]. " +
        "confidence is 0–1 for how much had to be inferred.",
        `Partial recipe:\n${JSON.stringify(p.recipe).slice(0, 12000)}`, 3500, { validated: true });

    case "recipeFix":
      if (!p || typeof p.recipe !== "object") return null;
      return routePrompt("recipeFix",
        "You audit a recipe for defects and return a REVIEWABLE patch (never a full rewrite). Output ONLY JSON: " +
        '{"schemaVersion":1,"issues":[{"kind":"brokenName"|"mergedInstruction"|"missingAmount"|"badUnit"|"duplicateLine"|"servingsMismatch",' +
        '"path":string,"before":string,"after":string,"note":string}],"fixedIngredients":[{"name":string,"amount":string}]}. ' +
        "Detect ingredient names merged with instructions, missing amounts, incompatible units, duplicate lines, and inconsistent servings. " +
        "Only include issues you are confident about. Leave the recipe unchanged where it is already correct.",
        `Recipe to audit:\n${JSON.stringify(p.recipe).slice(0, 12000)}`, 3000, { validated: true });

    case "recipeSubstitutions":
      if (!p || typeof p.ingredient !== "string") return null;
      return routePrompt("recipeSubstitutions",
        "You suggest ranked ingredient substitutions. Output ONLY JSON: " +
        '{"schemaVersion":1,"substitutions":[{"name":string,"tier":"exact"|"acceptable"|"avoid","ratio":string,' +
        '"flavorImpact":string,"changesCookTime":boolean,"note":string}]}. ' +
        "Rank by suitability given the inventory, dietary restrictions, and the ingredient's role. " +
        "Clearly separate exact substitutes, acceptable compromises, and substitutions that should NOT be used (tier \"avoid\").",
        `Ingredient: ${p.ingredient}\nRole: ${p.role || "unspecified"}\nInventory: ${JSON.stringify(p.inventory || []).slice(0, 4000)}\nDiet: ${JSON.stringify(p.dietary || [])}`,
        1800, { validated: true });

    case "recipeBuildAround":
      if (!p || (!Array.isArray(p.items) && typeof p.anchor !== "string")) return null;
      return routePrompt("recipeBuildAround",
        "You are given inventory items the user wants to cook with plus their equipment and preferences. " +
        "You do NOT invent recipes here — you EXPLAIN how to build around what they have. Output ONLY JSON: " +
        '{"schemaVersion":1,"anchor":string,"coverageNotes":string,"missingStaples":[string],' +
        '"substitutionTips":[{"for":string,"use":string,"note":string}],"servingsAdvice":string}. ' +
        "Keep it grounded in the provided items; suggest common staples only when essential.",
        `Anchor: ${p.anchor || ""}\nItems: ${JSON.stringify(p.items || []).slice(0, 4000)}\nEquipment: ${JSON.stringify(p.equipment || [])}\nServings: ${p.servings || ""}\nPrefs: ${JSON.stringify(p.preferences || {})}`,
        1800, { validated: true });

    case "receiptReview":
      if (!p || !Array.isArray(p.items)) return null;
      return routePrompt("receiptReview",
        "You are a second-stage receipt auditor. Given already-parsed line items, flag problems and score confidence. " +
        "Output ONLY JSON: " +
        '{"schemaVersion":1,"items":[{"index":number,"confidence":number,"flags":[string],"suggestedName":string|null,"needsReview":boolean}]}. ' +
        "flags may include: duplicate, weighted, quantityMultiplier, discountNotProduct, subtotalLine, implausiblePrice, uncertainAbbrev, lowConfidenceMatch. " +
        "Set needsReview true only for genuinely uncertain lines.",
        `Parsed items:\n${JSON.stringify(p.items).slice(0, 12000)}`, 2500, { validated: true });

    case "inventoryNormalize":
      if (!p || !Array.isArray(p.items)) return null;
      return routePrompt("inventoryNormalize",
        "You normalize freshly-entered food items before insertion. Output ONLY JSON: " +
        '{"schemaVersion":1,"items":[{"input":string,"canonicalName":string,"brand":string|null,"zone":"Fridge"|"Freezer"|"Pantry"|"Staples",' +
        '"container":string|null,"unit":string|null,"shelfLifeDays":number|null,"category":string,"iconKey":string,"duplicateOf":string|null}]}. ' +
        "canonicalName collapses variants (e.g. 'chicken breasts'/'boneless breast' → 'chicken breast'). " +
        "duplicateOf names an existing item this likely duplicates, else null. Never move a shelf-stable item to Fridge.",
        `Items to normalize: ${JSON.stringify(p.items).slice(0, 8000)}\nExisting names: ${JSON.stringify(p.existing || []).slice(0, 4000)}`,
        2500, { validated: true });

    case "groceryReconcile":
      if (!p || !Array.isArray(p.plannedMeals)) return null;
      return routePrompt("groceryReconcile",
        "You reconcile planned meals against inventory into ONE deduplicated grocery list. Output ONLY JSON: " +
        '{"schemaVersion":1,"list":[{"name":string,"quantity":number,"unit":string|null,"aisle":string,"optional":boolean,"haveEnough":boolean,"note":string}]}. ' +
        "Combine quantities, convert compatible units, drop items already sufficiently in stock (respect safety-stock), assign a store aisle, and mark optional ingredients.",
        `Planned meals: ${JSON.stringify(p.plannedMeals).slice(0, 8000)}\nInventory: ${JSON.stringify(p.inventory || []).slice(0, 8000)}\nSafetyStock: ${JSON.stringify(p.safetyStock || {})}`,
        3000, { validated: true });

    case "mealPlanOptimize":
      if (!p || !Array.isArray(p.days)) return null;
      return routePrompt("mealPlanOptimize",
        "You build a multi-day meal plan. Output ONLY JSON: " +
        '{"schemaVersion":1,"plan":[{"day":string,"meal":string,"recipeRef":string|null,"reason":string}]}. ' +
        "Prioritize using soon-to-expire items first, honor the household schedule, reuse leftovers, respect cooking-time and budget limits, hit serving needs, prefer saved recipes, and keep variety. " +
        "reason explains WHY each meal is on that day (e.g. 'uses spinach expiring Tue').",
        `Days: ${JSON.stringify(p.days)}\nExpiring: ${JSON.stringify(p.expiring || []).slice(0, 4000)}\nInventory: ${JSON.stringify(p.inventory || []).slice(0, 6000)}\nSaved: ${JSON.stringify(p.savedRecipes || []).slice(0, 4000)}\nConstraints: ${JSON.stringify(p.constraints || {})}`,
        4000, { validated: true });

    default:
      return null;
  }
}

// Map POST pathname → new route name.
export const PATH_ROUTES = Object.freeze({
  "/recipes/enrich": "recipeEnrich",
  "/recipes/fix": "recipeFix",
  "/recipes/substitutions": "recipeSubstitutions",
  "/recipes/build-around": "recipeBuildAround",
  "/receipts/review": "receiptReview",
  "/inventory/normalize": "inventoryNormalize",
  "/grocery/reconcile": "groceryReconcile",
  "/meal-plan/optimize": "mealPlanOptimize",
});
