import test from 'node:test';
import assert from 'node:assert/strict';

import { validateInput, validateAIOutput, barcodeChecksumValid, LIMITS } from '../src/validation.js';
import { mergeLWW, dedupeCap, normalizeCode, sanitizeName } from '../src/household-shared.js';
import { buildBrief } from '../src/dailybrief.js';
import { buildLegacyPrompt, buildRoutePrompt, ROUTE_SCHEMA } from '../src/routes.js';
import { HouseholdDO } from '../src/household-do.js';
import { scrub } from '../src/diagnostics.js';
import { suggestZone, normalize } from '../src/barcodes.js';
import { normalizeForBarcode, normalizeForCompare, hasRetailerApi } from '../src/retailerapi.js';

// Minimal mocks so the Durable Object can be exercised in plain node.
function mockStorage() {
  const m = new Map();
  return {
    get: async (k) => m.get(k),
    put: async (k, v) => { m.set(k, v); },
    delete: async (k) => { m.delete(k); },
    deleteAll: async () => { m.clear(); },
  };
}
function mockKV(seed = {}) {
  const m = new Map(Object.entries(seed));
  return { get: async (k) => (m.has(k) ? m.get(k) : null), put: async (k, v) => { m.set(k, v); }, delete: async (k) => { m.delete(k); } };
}
function doRequest(action, code, body) {
  return new Request('https://do.internal/', { method: 'POST', body: JSON.stringify({ action, code, body: body || { code } }) });
}

test('DO seeds from the legacy KV snapshot instead of 404 (the household 404 fix)', async () => {
  const legacy = { code: 'ABCD2345', ownerName: 'Key', ownerId: 'm1',
    members: [{ name: 'Key', memberId: 'm1' }], inventory: [{ id: 'i1', updatedAt: 1 }],
    grocery: [], activity: [], updatedAt: 100, revision: 5 };
  const kv = mockKV({ 'hh:ABCD2345': JSON.stringify(legacy) });
  const dobj = new HouseholdDO({ storage: mockStorage() }, { RATE_KV: kv });

  const res = await dobj.fetch(doRequest('pull', 'ABCD2345'));
  assert.equal(res.status, 200, 'pull must not 404 when a KV snapshot exists');
  const body = await res.json();
  assert.ok(body.household, 'household recovered from KV');
  assert.equal(body.household.code, 'ABCD2345');
  assert.equal(body.household.inventory.length, 1);
});

test('DO returns 404 only when neither DO storage nor KV has the household', async () => {
  const dobj = new HouseholdDO({ storage: mockStorage() }, { RATE_KV: mockKV() });
  const res = await dobj.fetch(doRequest('pull', 'ZZZZ9999'));
  assert.equal(res.status, 404);
});

test('DO push succeeds after KV seed and merges inventory', async () => {
  const legacy = { code: 'ABCD2345', ownerName: 'Key', ownerId: 'm1',
    members: [{ name: 'Key', memberId: 'm1' }], inventory: [{ id: 'i1', updatedAt: 1 }],
    grocery: [], activity: [], updatedAt: 100, revision: 5 };
  const kv = mockKV({ 'hh:ABCD2345': JSON.stringify(legacy) });
  const dobj = new HouseholdDO({ storage: mockStorage() }, { RATE_KV: kv });

  const res = await dobj.fetch(doRequest('push', 'ABCD2345', {
    code: 'ABCD2345', actorId: 'm1', inventory: [{ id: 'i2', updatedAt: 2 }],
  }));
  assert.equal(res.status, 200, 'push must succeed after seeding');
  const body = await res.json();
  assert.equal(body.ok, true);
  const ids = body.household.inventory.map((x) => x.id).sort();
  assert.deepEqual(ids, ['i1', 'i2'], 'existing + pushed item both present');
});

test('barcode checksum: valid UPC-A passes, tampered fails', () => {
  assert.equal(barcodeChecksumValid('036000291452'), true);   // classic valid UPC-A
  assert.equal(barcodeChecksumValid('036000291453'), false);
});

test('real app payloads (with clientVersion/cacheRevision metadata) pass validation', () => {
  // This is the exact shape StockedWorkerClient sends — the regression that 422'd every AI route.
  const intent = validateInput('inventoryIntent', { intent: 'used milk', route: 'inventoryIntent', schemaVersion: 2, clientVersion: '4.13', cacheRevision: 3 });
  assert.equal(intent.ok, true, 'inventoryIntent with metadata must pass');
  const gen = validateInput('recipeGeneration', { recipeIdea: 'chocolate cake', route: 'recipeGeneration', schemaVersion: 2, clientVersion: '4.13', cacheRevision: 3 });
  assert.equal(gen.ok, true, 'recipeGeneration with metadata must pass');
  const barcode = validateInput('barcode', { barcode: '036000291452', route: 'barcode', schemaVersion: 1, clientVersion: '4.13', cacheRevision: 2 });
  assert.equal(barcode.ok, true, 'barcode with metadata must pass');
});

test('unknown fields are non-fatal warnings, never a rejection', () => {
  const r = validateInput('barcode', { barcode: '036000291452', bogus: 1 });
  assert.equal(r.ok, true);
  assert.ok(r.warnings.some(w => w.code === 'unknownField' && w.field === 'bogus'));
});

test('input validation flags oversized receipt text', () => {
  const r = validateInput('receiptText', { receipt: 'x'.repeat(LIMITS.receiptTextChars + 1) });
  assert.equal(r.ok, false);
  assert.ok(r.errors.some(e => e.code === 'fieldTooLong'));
});

test('AI output validation catches unknown inventory action + bad zone', () => {
  const bad = validateAIOutput('inventoryIntent', { schemaVersion: 2, changes: [{ action: 'teleport', name: 'x' }] }, 2);
  assert.equal(bad.ok, false);
  assert.ok(bad.errors.some(e => e.code === 'invalidEnum'));

  const badZone = validateAIOutput('inventoryScan', { schemaVersion: 2, updates: [{ id: 'a', newZone: 'Basement' }] }, 2);
  assert.equal(badZone.ok, false);
  assert.ok(badZone.errors.some(e => e.code === 'invalidEnum'));
});

test('AI output validation flags duplicate item ids', () => {
  const dup = validateAIOutput('inventoryScan', { schemaVersion: 2, updates: [{ id: 'a', reason: 'x' }, { id: 'a', reason: 'y' }] }, 2);
  assert.equal(dup.ok, false);
  assert.ok(dup.errors.some(e => e.code === 'duplicateId'));
});

test('mergeLWW keeps newest by updatedAt and drops tombstoned ids', () => {
  const existing = [{ id: '1', updatedAt: 10, v: 'old' }, { id: '2', updatedAt: 5, v: 'keep' }];
  const incoming = [{ id: '1', updatedAt: 20, v: 'new' }, { id: '3', updatedAt: 1, v: 'gone' }];
  const out = mergeLWW(existing, incoming, new Set(['3']));
  const byId = Object.fromEntries(out.map(x => [x.id, x.v]));
  assert.equal(byId['1'], 'new');   // newer wins
  assert.equal(byId['2'], 'keep');  // one-sided kept
  assert.equal(byId['3'], undefined); // tombstoned dropped
});

test('dedupeCap dedupes and keeps most recent within cap', () => {
  assert.deepEqual(dedupeCap(['a', 'a', 'b', 'c'], 2), ['b', 'c']);
});

test('normalizeCode strips junk + uppercases; sanitizeName bounds length', () => {
  assert.equal(normalizeCode('ab-cd 23!'), 'ABCD23');
  assert.equal(sanitizeName('  '.padEnd(60, 'x')).length <= 40, true);
});

test('buildBrief surfaces the most urgent expiring item as the action', () => {
  const brief = buildBrief({
    inventory: [{ name: 'Spinach', daysUntilExpiry: 1 }, { name: 'Rice', daysUntilExpiry: 200 }],
    plannedMeals: [], grocery: [{ isChecked: false }], planHorizonDays: 7,
  });
  assert.equal(brief.expiring[0].name, 'Spinach');
  assert.match(brief.recommendedAction, /Spinach/);
});

test('legacy prompt sniffing still resolves the 7 shipped routes', () => {
  assert.equal(buildLegacyPrompt({ receipt: 'MILK 2.99' }).route, 'receiptText');
  assert.equal(buildLegacyPrompt({ barcode: '036000291452' }).route, 'barcode');
  assert.equal(buildLegacyPrompt({ recipeText: 'mix eggs' }).route, 'recipeImport');
  assert.equal(buildLegacyPrompt({ intent: 'used milk' }).route, 'inventoryIntent');
  assert.equal(buildLegacyPrompt({ recipeIdea: 'quick pasta' }).route, 'recipeGeneration');
  assert.equal(buildLegacyPrompt({ inventoryScan: true, inventory: [] }).route, 'inventoryScan');
  assert.equal(buildLegacyPrompt({ imageBase64: 'AAAA' }).route, 'receiptImage');
  assert.equal(buildLegacyPrompt({ nonsense: 1 }), null);
});

test('diagnostics scrub drops sensitive fields, keeps whitelisted ones', () => {
  const out = scrub({
    appVersion: '4.13', workerVersion: '2026-07-15.1', syncRevision: 12,
    inventoryNames: ['milk', 'eggs'],        // must be dropped
    accountToken: 'secret',                  // must be dropped
    email: 'a@b.com',                        // must be dropped
    recentFailures: [{ route: 'inventoryIntent', status: 422, code: 'x', ts: 1, extra: 'nope' }],
  });
  assert.equal(out.appVersion, '4.13');
  assert.equal(out.syncRevision, 12);
  assert.equal(out.inventoryNames, undefined);
  assert.equal(out.accountToken, undefined);
  assert.equal(out.email, undefined);
  assert.equal(out.recentFailures[0].route, 'inventoryIntent');
  assert.equal(out.recentFailures[0].extra, undefined); // nested unknowns stripped too
});

test('barcode zone heuristic is conservative', () => {
  assert.equal(suggestZone(['en:frozen-pizzas']), 'Freezer');
  assert.equal(suggestZone(['en:cheeses', 'en:dairies']), 'Fridge');
  assert.equal(suggestZone(['en:spices']), 'Staples');
  assert.equal(suggestZone(['en:unknown-thing']), 'Pantry'); // default never Fridge
  assert.equal(suggestZone([]), 'Pantry');
});

test('barcode normalize extracts name/brand/allergens/zone', () => {
  const p = normalize({
    product_name: 'Whole Milk', brands: 'BrandCo, Other', quantity: '1 L',
    allergens_tags: ['en:milk'], categories_tags: ['en:dairies'], categories: 'Dairy, Milk',
    image_url: 'http://x/img.jpg', nutriments: { 'proteins_100g': 3.4, 'energy-kcal_100g': 60 },
  });
  assert.equal(p.name, 'Whole Milk');
  assert.equal(p.brand, 'BrandCo');
  assert.equal(p.packageQuantity, '1 L');
  assert.deepEqual(p.allergens, ['milk']);
  assert.equal(p.suggestedZone, 'Fridge');
  assert.equal(p.nutrition.proteinPer100g, 3.4);
});

test('retailerapi is key-gated (off without RETAILERAPI_KEY)', () => {
  assert.equal(hasRetailerApi({}), false);
  assert.equal(hasRetailerApi({ RETAILERAPI_KEY: 'rk_live_x' }), true);
});

test('normalizeForBarcode extracts price + retailer links', () => {
  const c = normalizeForBarcode({
    title: 'Cereal', brand: 'BrandCo', image_url: 'http://x/i.jpg', current_price: 3.98,
    retailer_links: [{ retailer: 'walmart', url: 'http://w/1' }, { retailer: 'target', url: 'http://t/1' }],
  });
  assert.equal(c.price.current, 3.98);
  assert.equal(c.price.currency, 'USD');
  assert.equal(c.retailers.length, 2);
  assert.equal(c.image, 'http://x/i.jpg');
});

test('normalizeForCompare ranks retailers cheapest-first and de-dupes', () => {
  const n = normalizeForCompare({
    retailer: 'walmart', current_price: 4.98, title: 'Olive Oil',
    cross_retailer: {
      target: { retailer: 'target', status: 'ok', price: 4.49, url: 'http://t', in_stock: true },
      amazon: { retailer: 'amazon', status: 'ok', price: 5.99, url: 'http://a' },
      bestbuy: { retailer: 'bestbuy', status: 'not_found' },        // skipped
      walmart: { retailer: 'walmart', status: 'ok', price: 4.98 },  // dup of anchor → ignored
    },
  });
  assert.equal(n.prices[0].retailer, 'target');   // cheapest first
  assert.equal(n.cheapest.price, 4.49);
  const slugs = n.prices.map(p => p.retailer).sort();
  assert.deepEqual(slugs, ['amazon', 'target', 'walmart']); // no dup walmart, no not_found bestbuy
});

test('normalizeForCompare computes unit pricing (per-oz / per-lb) when size known', () => {
  const n = normalizeForCompare(
    { retailer: 'walmart', current_price: 8.00, cross_retailer: {} },
    { sizeValue: 16, sizeUnit: 'oz' }
  );
  const w = n.prices[0];
  assert.equal(w.unitPrice.perOz, 0.5);   // $8 / 16oz
  assert.equal(w.unitPrice.perLb, 8);     // $8 / 1lb
});

test('new endpoints build prompts and are marked validated', () => {
  const enrich = buildRoutePrompt('recipeEnrich', { recipe: { title: 'x' } });
  assert.equal(enrich.route, 'recipeEnrich');
  assert.equal(enrich.validated, true);
  assert.equal(ROUTE_SCHEMA.recipeEnrich, 1);
  assert.equal(buildRoutePrompt('recipeFix', {}), null); // missing recipe → null
});
