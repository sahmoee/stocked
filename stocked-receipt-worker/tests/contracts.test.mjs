import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const worker = await readFile(new URL('../index.js', import.meta.url), 'utf8');
const client = await readFile(new URL('../../Stocked/StockedWorkerClient.swift', import.meta.url), 'utf8');

const expected = {
  receiptText: 2,
  receiptImage: 2,
  barcode: 1,
  recipeImport: 2,
  recipeGeneration: 2,
  inventoryIntent: 2,
  inventoryScan: 2,
};

test('Worker and Swift client retain the same route schema versions', () => {
  for (const [route, version] of Object.entries(expected)) {
    assert.match(worker, new RegExp(`\\b${route}\\s*:\\s*${version}\\b`), `Worker ${route}`);
  }
  assert.match(client, /case \.receiptText, \.receiptImage: return 2/);
  assert.match(client, /case \.barcode: return 1/);
  assert.match(client, /case \.recipeImport, \.recipeGeneration: return 2/);
  assert.match(client, /case \.inventoryIntent: return 2/);
  assert.match(client, /case \.inventoryScan: return 2/);
});

test('Every structured AI route requires an echoed schemaVersion', () => {
  for (const route of ['recipeImport', 'recipeGeneration', 'inventoryIntent', 'inventoryScan']) {
    const start = worker.indexOf(`routePrompt("${route}"`);
    assert.notEqual(start, -1, `${route} prompt exists`);
    const block = worker.slice(start, start + 6000);
    assert.match(block, /schemaVersion/, `${route} prompt includes schemaVersion`);
  }
});

test('Household counters remain on Cache API rather than KV', () => {
  assert.match(worker, /caches\.default\.match\(counterURL/);
  assert.match(worker, /caches\.default\.put\(counterURL/);
  assert.doesNotMatch(worker, /RATE_KV\.put\([^\n]*(?:minute|day|counter)/i);
});
