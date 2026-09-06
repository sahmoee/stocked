// Runs the exact production scripts in a bounded fake DOM, not an iOS simulator.
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../Stocked/RecipePageMarkup.swift', import.meta.url), 'utf8');
const script = name => {
  const match = source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`));
  assert.ok(match, `production ${name} exists`);
  return match[1];
};
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const url = 'https://example.com/recipe#instructions';
function snapshot(values) {
  return runInNewContext(script('snapshotScript'), {
    document: { querySelectorAll: selector => {
      check(selector === 'script[type="application/ld+json"]', 'reads only structured page data');
      return values.map(textContent => ({ textContent }));
    } }, location: { href: url },
  }, { timeout: 1000 });
}
const actual = snapshot(['{"@type":"Recipe","name":"Rice"}']);
check(actual.url === url, 'uses current document URL and anchor');
check(actual.html.includes('"name":"Rice"'), 'recipe metadata preserved');
check(snapshot([]).html === '', 'absent metadata is empty, not invented');
check(snapshot(['x'.repeat(262145)]).html === '', 'oversized single block excluded');
const many = snapshot(Array.from({ length: 40 }, () => '{}'));
check((many.html.match(/<script/g) || []).length === 16, 'at most 16 blocks cross IPC');
check(snapshot(['a'.repeat(262144), 'b'.repeat(262144), 'c']).html.length < 525000, 'total snapshot bounded');
let inspected = 0;
runInNewContext(script('snapshotScript'), {
  document: { querySelectorAll: () => Array.from({ length: 100 }, () => ({ get textContent() { inspected++; return 'x'.repeat(262145); } })) },
  location: { href: url },
}, { timeout: 1000 });
check(inspected === 32, 'even oversized pages inspect at most 32 script nodes');
let scrollOptions;
const found = runInNewContext(script('jumpScript'), {
  document: { querySelector: () => ({ scrollIntoView: options => { scrollOptions = options; } }) },
}, { timeout: 1000 });
check(found === true, 'recipe target reports success');
check(scrollOptions.behavior === 'instant' && scrollOptions.block === 'start', 'jump respects reduced motion');
const missing = runInNewContext(script('jumpScript'), { document: { querySelector: () => null } }, { timeout: 1000 });
check(missing === false, 'missing target reports fallback');
console.log(`PASS: ${checks} browser script checks`);
