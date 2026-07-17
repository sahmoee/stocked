// improvements.test.mjs — pure-logic tests for the content proxy + the ten
// worker improvements (ETag hashing, error-code mapping, validation additions,
// push dedupe hashing/idempotency, SWR staleness, metrics rollups, prompt
// caching blocks, config-driven AI options, session-aware rate keys).

import test from 'node:test';
import assert from 'node:assert/strict';

import { codeForStatus, errJson, etagMatches, strongETag, readBoundedJSON, corsHeadersFor } from '../src/util.js';
import { contentOriginFor, isRecipesPayload, etagForContent, DEFAULT_CONTENT_ORIGIN } from '../src/content.js';
import {
  validateBarcodeResolve, validatePricesCompare, validateDiagnostics, validateDailyBrief,
  DIAG_MAX_BYTES,
} from '../src/validation.js';
import { stableStringify, fnv1a, pushBatchHash } from '../src/household-shared.js';
import { HouseholdDO } from '../src/household-do.js';
import { metricsKey, bumpRollup, SAMPLE_RATE } from '../src/metrics.js';
import { systemBlocksFor } from '../src/ai.js';
import { resolveMaxTokens, resolveModel } from '../src/config.js';
import { rateSubject } from '../src/ratelimit.js';
import { normalizeDiscoverQuery, isStale } from '../src/discover.js';

// ── error envelope (#3) ──────────────────────────────────────────────────────

test('codeForStatus maps statuses to stable codes', () => {
  assert.equal(codeForStatus(401), 'unauthorized');
  assert.equal(codeForStatus(404), 'notFound');
  assert.equal(codeForStatus(405), 'methodNotAllowed');
  assert.equal(codeForStatus(413), 'payloadTooLarge');
  assert.equal(codeForStatus(422), 'invalidInput');
  assert.equal(codeForStatus(429), 'rateLimited');
  assert.equal(codeForStatus(502), 'upstreamError');
  assert.equal(codeForStatus(599), 'upstreamError'); // unknown 5xx
});

test('errJson: every 429 carries Retry-After; body has error/code/requestId', async () => {
  const r = errJson(429, 'slow down', { requestId: 'abc123' });
  assert.equal(r.status, 429);
  assert.equal(r.headers.get('Retry-After'), '30');
  const body = await r.json();
  assert.equal(body.error, 'slow down');
  assert.equal(body.code, 'rateLimited');
  assert.equal(body.requestId, 'abc123');
});

test('errJson defaults code from status and merges extra fields', async () => {
  const r = errJson(422, 'bad', { requestId: 'x', extra: { errors: [{ field: 'a' }] } });
  const body = await r.json();
  assert.equal(body.code, 'invalidInput');
  assert.equal(body.errors.length, 1);
});

// ── ETag helpers (#1 + Task 1) ───────────────────────────────────────────────

test('strongETag is stable per body and quoted', async () => {
  const a = await strongETag('{"recipes":[]}');
  const b = await strongETag('{"recipes":[]}');
  const c = await strongETag('{"recipes":[1]}');
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.match(a, /^"[0-9a-f]{32}"$/);
});

test('etagMatches handles exact, lists, weak prefixes, and *', () => {
  assert.equal(etagMatches('"abc"', '"abc"'), true);
  assert.equal(etagMatches('"x", "abc"', '"abc"'), true);
  assert.equal(etagMatches('W/"abc"', '"abc"'), true);
  assert.equal(etagMatches('*', '"abc"'), true);
  assert.equal(etagMatches('"nope"', '"abc"'), false);
  assert.equal(etagMatches(null, '"abc"'), false);
  assert.equal(etagMatches('"abc"', ''), false);
});

// ── content proxy (Task 1) ───────────────────────────────────────────────────

test('contentOriginFor defaults and strips trailing slashes', () => {
  assert.equal(contentOriginFor({}), DEFAULT_CONTENT_ORIGIN);
  assert.equal(contentOriginFor({ CONTENT_ORIGIN: 'https://x.example/' }), 'https://x.example');
});

test('isRecipesPayload accepts wrapped and bare-array formats only', () => {
  assert.equal(isRecipesPayload([{ title: 'x' }]), true);
  assert.equal(isRecipesPayload({ version: 3, recipes: [] }), true);
  assert.equal(isRecipesPayload({ version: 3 }), false);
  assert.equal(isRecipesPayload('nope'), false);
  assert.equal(isRecipesPayload(null), false);
});

test('etagForContent prefers a strong origin ETag, hashes otherwise', async () => {
  assert.equal(await etagForContent('"origin-tag"', 'body'), '"origin-tag"');
  const hashed = await etagForContent('W/"weak"', 'body');       // weak origin tag → hash instead
  assert.match(hashed, /^"[0-9a-f]{32}"$/);
  assert.equal(await etagForContent(null, 'body'), hashed);
});

// ── bounded bodies (#10) ─────────────────────────────────────────────────────

test('readBoundedJSON enforces the byte budget and parses JSON', async () => {
  const ok = await readBoundedJSON(new Request('https://x/', { method: 'POST', body: '{"a":1}' }), 100);
  assert.equal(ok.ok, true);
  assert.equal(ok.value.a, 1);

  const big = await readBoundedJSON(new Request('https://x/', { method: 'POST', body: '"' + 'x'.repeat(200) + '"' }), 100);
  assert.equal(big.ok, false);
  assert.equal(big.status, 413);
  assert.equal(big.code, 'payloadTooLarge');

  const bad = await readBoundedJSON(new Request('https://x/', { method: 'POST', body: 'not json' }), 100);
  assert.equal(bad.ok, false);
  assert.equal(bad.status, 400);
});

test('corsHeadersFor: "*" with no allowlist, echo only listed origins otherwise', () => {
  assert.equal(corsHeadersFor('https://evil.example', '')['Access-Control-Allow-Origin'], '*');
  const allowed = corsHeadersFor('https://app.example', 'https://app.example, https://b.example');
  assert.equal(allowed['Access-Control-Allow-Origin'], 'https://app.example');
  const denied = corsHeadersFor('https://evil.example', 'https://app.example');
  assert.equal(denied['Access-Control-Allow-Origin'], undefined);
});

// ── validation additions (#4) ────────────────────────────────────────────────

test('validateBarcodeResolve: digits 8–14, checksum on GTIN lengths, stable errors', () => {
  assert.equal(validateBarcodeResolve({ barcode: '036000291452' }).ok, true);     // valid UPC-A
  assert.equal(validateBarcodeResolve({ barcode: ' 036000291452 ' }).code, '036000291452'); // trimmed
  assert.equal(validateBarcodeResolve({ barcode: '1234567' }).ok, false);         // 7 digits
  assert.equal(validateBarcodeResolve({ barcode: '123456789012345' }).ok, false); // 15 digits
  assert.equal(validateBarcodeResolve({ barcode: '036000291453' }).ok, false);    // checksum
  assert.equal(validateBarcodeResolve({ barcode: 'abcdefgh' }).ok, false);
  assert.equal(validateBarcodeResolve({}).ok, false);
  assert.equal(validateBarcodeResolve({ barcode: '036000291452', includePrice: 'yes' }).ok, false);
  const errs = validateBarcodeResolve({ barcode: '12' }).errors;
  assert.ok(errs.some((e) => e.code === 'invalidBarcode'));
});

test('validatePricesCompare: optional sizeValue>0 and whitelisted sizeUnit', () => {
  const base = { barcode: '036000291452' };
  assert.equal(validatePricesCompare(base).ok, true);
  assert.equal(validatePricesCompare({ ...base, sizeValue: 16, sizeUnit: 'oz' }).ok, true);
  assert.equal(validatePricesCompare({ ...base, sizeUnit: 'OZ' }).ok, true);      // case-insensitive
  assert.equal(validatePricesCompare({ ...base, sizeValue: 0 }).ok, false);
  assert.equal(validatePricesCompare({ ...base, sizeValue: -2 }).ok, false);
  assert.equal(validatePricesCompare({ ...base, sizeValue: 'big' }).ok, false);
  assert.equal(validatePricesCompare({ ...base, sizeUnit: 'furlongs' }).ok, false);
});

test('validateDiagnostics: object required, 64KB bound', () => {
  assert.equal(validateDiagnostics({ appVersion: '1' }, 100).ok, true);
  assert.equal(validateDiagnostics([], 100).ok, false);
  assert.equal(validateDiagnostics({ a: 1 }, DIAG_MAX_BYTES + 1).ok, false);
});

test('validateDailyBrief: bounded context arrays and sane scalars', () => {
  assert.equal(validateDailyBrief({}).ok, true);
  assert.equal(validateDailyBrief({ inventory: [], planHorizonDays: 7 }).ok, true);
  assert.equal(validateDailyBrief({ inventory: 'nope' }).ok, false);
  assert.equal(validateDailyBrief({ inventory: new Array(2001).fill({}) }).ok, false);
  assert.equal(validateDailyBrief({ planHorizonDays: 99 }).ok, false);
  assert.equal(validateDailyBrief({ code: 'X'.repeat(30) }).ok, false);
});

// ── push idempotency (#5) ────────────────────────────────────────────────────

test('stableStringify is key-order independent; fnv1a is stable', () => {
  assert.equal(stableStringify({ b: 1, a: [2, { d: 3, c: 4 }] }), stableStringify({ a: [2, { c: 4, d: 3 }], b: 1 }));
  assert.equal(fnv1a('hello'), fnv1a('hello'));
  assert.notEqual(fnv1a('hello'), fnv1a('hellp'));
});

test('pushBatchHash: same batch+sender → same hash; different content or sender → different; empty → null', () => {
  const batch = { actorId: 'm1', inventory: [{ id: 'i1', updatedAt: 5 }], code: 'ABCD2345' };
  assert.equal(pushBatchHash(batch), pushBatchHash({ ...batch }));
  assert.notEqual(pushBatchHash(batch), pushBatchHash({ ...batch, actorId: 'm2' }));
  assert.notEqual(pushBatchHash(batch), pushBatchHash({ ...batch, inventory: [{ id: 'i2', updatedAt: 5 }] }));
  assert.equal(pushBatchHash({ actorId: 'm1', code: 'ABCD2345' }), null);   // no content fields
  assert.equal(pushBatchHash(null), null);
});

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

test('DO push is idempotent: an identical retry is skipped and answered ok', async () => {
  const legacy = { code: 'ABCD2345', ownerName: 'Key', ownerId: 'm1',
    members: [{ name: 'Key', memberId: 'm1' }], inventory: [],
    grocery: [], activity: [], updatedAt: 100, revision: 5 };
  const kv = mockKV({ 'hh:ABCD2345': JSON.stringify(legacy) });
  const dobj = new HouseholdDO({ storage: mockStorage() }, { RATE_KV: kv });

  const batch = { code: 'ABCD2345', actorId: 'm1', inventory: [{ id: 'i1', updatedAt: 2 }],
    activity: [{ kind: 'itemAdded', itemName: 'Milk', actorName: 'Key', date: 42 }] };

  const first = await (await dobj.fetch(doRequest('push', 'ABCD2345', batch))).json();
  assert.equal(first.ok, true);
  const rev = first.household.revision;

  const retry = await (await dobj.fetch(doRequest('push', 'ABCD2345', batch))).json();
  assert.equal(retry.ok, true, 'retry still succeeds');
  assert.equal(retry.deduped, true, 'retry is recognized as a duplicate');
  assert.equal(retry.household.revision, rev, 'revision not bumped again');
  assert.equal(retry.household.inventory.length, 1, 'item not duplicated');
});

test('DO push with different content is NOT deduped', async () => {
  const legacy = { code: 'ABCD2345', ownerName: 'Key', ownerId: 'm1',
    members: [{ name: 'Key', memberId: 'm1' }], inventory: [], grocery: [], activity: [], updatedAt: 100, revision: 1 };
  const kv = mockKV({ 'hh:ABCD2345': JSON.stringify(legacy) });
  const dobj = new HouseholdDO({ storage: mockStorage() }, { RATE_KV: kv });

  await dobj.fetch(doRequest('push', 'ABCD2345', { code: 'ABCD2345', actorId: 'm1', inventory: [{ id: 'i1', updatedAt: 2 }] }));
  const second = await (await dobj.fetch(doRequest('push', 'ABCD2345', { code: 'ABCD2345', actorId: 'm1', inventory: [{ id: 'i2', updatedAt: 3 }] }))).json();
  assert.equal(second.deduped, undefined);
  assert.equal(second.household.inventory.length, 2);
});

// ── metrics (#8) ─────────────────────────────────────────────────────────────

test('metricsKey is metrics:YYYY-MM-DD', () => {
  assert.equal(metricsKey(new Date('2026-07-17T12:00:00Z')), 'metrics:2026-07-17');
});

test('bumpRollup counts per-route and error buckets with sample weight', () => {
  let r = bumpRollup({}, 'household', 200);
  r = bumpRollup(r, 'household', 200);
  r = bumpRollup(r, 'barcodeResolve', 502);
  assert.equal(r.total, 3 * SAMPLE_RATE);
  assert.equal(r.routes.household, 2 * SAMPLE_RATE);
  assert.equal(r.routes.barcodeResolve, SAMPLE_RATE);
  assert.equal(r.errors.total, SAMPLE_RATE);
  assert.equal(r.errors['5xx'], SAMPLE_RATE);
  assert.equal(r.errors.byRoute.barcodeResolve, SAMPLE_RATE);
  assert.equal(r.errors['4xx'], undefined);
});

// ── AI efficiency (#9) ───────────────────────────────────────────────────────

test('systemBlocksFor wraps the system prompt with cache_control only when enabled', () => {
  const sys = 'You extract grocery line items…';
  assert.equal(systemBlocksFor(sys, false), sys);
  const blocks = systemBlocksFor(sys, true);
  assert.equal(blocks[0].type, 'text');
  assert.equal(blocks[0].text, sys);
  assert.deepEqual(blocks[0].cache_control, { type: 'ephemeral' });
  assert.equal(systemBlocksFor('', true), '');           // empty stays untouched
});

test('resolveMaxTokens honors bounded config overrides; resolveModel prefers config', () => {
  assert.equal(resolveMaxTokens({ aiLimits: { recipeGeneration: 3000 } }, 'recipeGeneration', 4500), 3000);
  assert.equal(resolveMaxTokens({ aiLimits: { recipeGeneration: 5 } }, 'recipeGeneration', 4500), 4500);      // too small → fallback
  assert.equal(resolveMaxTokens({ aiLimits: {} }, 'recipeGeneration', 4500), 4500);
  assert.equal(resolveMaxTokens(null, 'x', 1500), 1500);
  assert.equal(resolveModel({ aiModel: 'claude-x' }, 'claude-env', 'claude-def'), 'claude-x');
  assert.equal(resolveModel({ aiModel: '  ' }, 'claude-env', 'claude-def'), 'claude-env');
  assert.equal(resolveModel({}, null, 'claude-def'), 'claude-def');
});

// ── session-aware rate limiting (#7) ─────────────────────────────────────────

test('rateSubject keys by session subject when valid, IP otherwise (guests stay IP-keyed)', () => {
  assert.equal(rateSubject({ ok: true, sub: 'apple:123', guest: false }, '1.2.3.4'), 's:apple:123');
  assert.equal(rateSubject({ ok: true, sub: 'guest', guest: true }, '1.2.3.4'), 'ip:1.2.3.4');
  assert.equal(rateSubject({ ok: false }, '1.2.3.4'), 'ip:1.2.3.4');
  assert.equal(rateSubject(null, null), 'ip:unknown');
});

// ── discover SWR (#6) ────────────────────────────────────────────────────────

test('normalizeDiscoverQuery lowercases/trims/caps; isStale respects the fresh window', () => {
  assert.equal(normalizeDiscoverQuery('  Pasta Bake  '), 'pasta bake');
  assert.equal(normalizeDiscoverQuery(42), '');
  const now = Date.now();
  assert.equal(isStale(String(now - 60 * 1000), now), false);         // 1 min old → fresh
  assert.equal(isStale(String(now - 16 * 60 * 1000), now), true);     // 16 min old → stale
  assert.equal(isStale(null, now), true);                             // unknown age → treat as stale
});
