import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const routes = await readFile(new URL('../src/routes.js', import.meta.url), 'utf8');
const index = await readFile(new URL('../index.js', import.meta.url), 'utf8');
const util = await readFile(new URL('../src/util.js', import.meta.url), 'utf8');
const client = await readFile(new URL('../../Stocked/StockedWorkerClient.swift', import.meta.url), 'utf8').catch(() => '');

const expected = {
  receiptText: 2, receiptImage: 2, barcode: 1, recipeImport: 2,
  recipeGeneration: 2, inventoryIntent: 2, inventoryScan: 2,
};

test('ROUTE_SCHEMA keeps the shipped app-facing versions', () => {
  for (const [route, version] of Object.entries(expected)) {
    assert.match(routes, new RegExp(`\\b${route}\\s*:\\s*${version}\\b`), `routes.js ${route}`);
  }
});

test('Swift client route versions still match (if client present)', () => {
  if (!client) return; // client not in this checkout
  assert.match(client, /case \.receiptText, \.receiptImage: return 2/);
  assert.match(client, /case \.barcode: return 1/);
  assert.match(client, /case \.recipeImport, \.recipeGeneration: return 2/);
  assert.match(client, /case \.inventoryIntent: return 2/);
  assert.match(client, /case \.inventoryScan: return 2/);
});

test('Structured routes still echo schemaVersion', () => {
  for (const route of ['recipeImport', 'recipeGeneration', 'inventoryIntent', 'inventoryScan']) {
    const start = routes.indexOf(`routePrompt("${route}"`);
    assert.notEqual(start, -1, `${route} prompt exists`);
    assert.match(routes.slice(start, start + 6000), /schemaVersion/, `${route} includes schemaVersion`);
  }
});

test('Household is served by the Durable Object (improvement #1)', () => {
  assert.match(index, /HOUSEHOLD_DO/);
  assert.match(index, /export \{ HouseholdDO \}/);
});

test('Household codes use Web Crypto, never Math.random (improvement #4)', () => {
  assert.match(util, /crypto\.getRandomValues/);
  assert.doesNotMatch(util, /Math\.random/);
});

test('fetch receives ctx for waitUntil (improvement #6)', () => {
  assert.match(index, /async fetch\(request, env, ctx\)/);
  assert.match(util, /ctx\.waitUntil/);
});
