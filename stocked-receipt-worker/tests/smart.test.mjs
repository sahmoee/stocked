import { test } from "node:test";
import assert from "node:assert/strict";
import {
  convertUnits, parseQuantity, formatQuantity, scaleRecipe, normalizeIngredient,
  optimizeGrocery, aisleFor, pantryMatch, estimateNutrition, expiryDays,
  seasonProduce, substitutionsFor, density, convertTemperature, abVariant,
} from "../src/smart.js";

const near = (a, b, eps = 0.02) => assert.ok(Math.abs(a - b) <= eps, `${a} ≈ ${b}`);

test("convertUnits: volume↔volume", () => {
  near(convertUnits(1, "cup", "ml"), 236.588);
  near(convertUnits(16, "tbsp", "cup"), 1);
  near(convertUnits(3, "tsp", "tbsp"), 1);
});

test("convertUnits: mass↔mass", () => {
  assert.equal(convertUnits(1, "kg", "g"), 1000);
  near(convertUnits(1, "lb", "oz"), 16);
});

test("convertUnits: volume↔mass via density", () => {
  near(convertUnits(1, "cup", "g", "flour"), 236.588 * 0.53, 0.5);
  near(density("all-purpose flour"), 0.53);
  near(convertUnits(1, "cup", "g", "water"), 236.588, 0.5);
});

test("convertUnits: rejects incompatible", () => {
  assert.throws(() => convertUnits(1, "clove", "ml"));
});

test("parseQuantity: mixed, fraction, decimal, plain", () => {
  assert.deepEqual(parseQuantity("1 1/2 cups flour"), { value: 1.5, unit: "cups", ingredient: "flour" });
  assert.deepEqual(parseQuantity("1/2 tsp salt"), { value: 0.5, unit: "tsp", ingredient: "salt" });
  assert.deepEqual(parseQuantity("2 cups sugar"), { value: 2, unit: "cups", ingredient: "sugar" });
  assert.deepEqual(parseQuantity("3 eggs"), { value: 3, unit: "", ingredient: "eggs" });
  assert.equal(parseQuantity("a pinch of nutmeg").value, null);
});

test("formatQuantity: decimals → friendly fractions", () => {
  assert.equal(formatQuantity(0.5), "1/2");
  assert.equal(formatQuantity(1.5), "1 1/2");
  assert.equal(formatQuantity(0.75), "3/4");
  assert.equal(formatQuantity(3), "3");
});

test("scaleRecipe: scales quantities, keeps text", () => {
  assert.deepEqual(scaleRecipe(["2 cups flour", "1 tsp salt"], 1.5), ["3 cups flour", "1 1/2 tsp salt"]);
  assert.deepEqual(scaleRecipe(["a pinch of salt"], 2), ["a pinch of salt"]);
});

test("normalizeIngredient: strips qualifiers, singularizes", () => {
  assert.equal(normalizeIngredient("Fresh Tomatoes"), "tomato");
  assert.equal(normalizeIngredient("Chicken Breasts (boneless)"), "chicken breast");
  assert.equal(normalizeIngredient("Basil"), "basil");
});

test("aisleFor + optimizeGrocery: merge + categorize", () => {
  assert.equal(aisleFor("milk"), "dairy");
  assert.equal(aisleFor("tomato"), "produce");
  const list = optimizeGrocery(["2 cups flour", "1 cup flour", "milk", "2 tomatoes"]);
  const flour = list.find((x) => x.name.includes("flour"));
  assert.equal(flour.aisle, "pantry");
  assert.equal(flour.quantity, "3 cups");
  assert.ok(list.some((x) => x.aisle === "dairy"));
  assert.ok(list.some((x) => x.aisle === "produce"));
});

test("pantryMatch: makeability + missing", () => {
  const r = pantryMatch(["chicken", "rice", "garlic"], ["chicken", "rice", "butter", "garlic", "onion"]);
  assert.equal(r.makeable, false);
  assert.equal(r.score, 0.6);
  assert.deepEqual(r.missing.sort(), ["butter", "onion"]);
});

test("estimateNutrition: sums from table", () => {
  const n = estimateNutrition(["100 g chicken", "50 g rice"]);
  assert.equal(n.total.kcal, 165 + Math.round(130 * 0.5));
  assert.ok(n.items.length === 2);
});

test("expiryDays: category + storage", () => {
  assert.deepEqual(expiryDays("milk", "fridge"), { category: "dairy", storage: "fridge", days: 7 });
  assert.equal(expiryDays("chicken breast", "fridge").days, 3);
  assert.equal(expiryDays("apple", "pantry").category, "produce");
});

test("seasonProduce: month lookup", () => {
  const s = seasonProduce(7);
  assert.equal(s.month, 7);
  assert.ok(s.produce.includes("tomato"));
});

test("substitutionsFor: dietary filter", () => {
  const vegan = substitutionsFor("butter", "vegan");
  assert.ok(vegan.length >= 1 && vegan.every((x) => x.vegan));
  assert.ok(substitutionsFor("egg").length >= 1);
});

test("convertTemperature: F/C/gas", () => {
  assert.equal(convertTemperature(350, "F", "C"), 177);
  assert.equal(convertTemperature(180, "C", "F"), 356);
  assert.equal(convertTemperature(350, "F", "G"), 4);
});

test("abVariant: deterministic + within buckets", () => {
  const v1 = abVariant("user-123", ["a", "b"], "exp1");
  assert.equal(v1, abVariant("user-123", ["a", "b"], "exp1"));  // stable
  assert.ok(["a", "b"].includes(v1));
});
