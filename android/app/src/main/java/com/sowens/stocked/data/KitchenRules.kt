package com.sowens.stocked.data

import java.text.Normalizer
import java.time.LocalDate
import java.util.Locale

object KitchenRules {
 fun key(name: String): String = Normalizer.normalize(name.trim(), Normalizer.Form.NFKC)
  .lowercase(Locale.ROOT).replace(Regex("\\s+"), " ")
 fun validate(item: InventoryItem) {
  require(item.name.trim().isNotEmpty() && item.name.length <= 500) { "Enter an item name (up to 500 characters)." }
  require(item.quantity in 0..100000) { "Quantity must be between 0 and 100,000." }
  require(item.level.isFinite() && item.level in 0.0..1.0) { "Fill level must be between zero and one." }
  require(item.sizeAmount == null || item.sizeAmount.isFinite() && item.sizeAmount > 0) { "Container size must be positive." }
  require(item.price == null || item.price.isFinite() && item.price >= 0) { "Price cannot be negative." }
  require(item.storageCategory in listOf("Pantry", "Fridge", "Freezer", "Staples")) { "Choose a storage zone." }
  item.expirationDate?.let { LocalDate.parse(it) }
 }
 fun validate(item: GroceryItem) { require(item.name.trim().isNotEmpty() && item.name.length <= 500); require(item.quantity in 1..100000) }
 fun validate(recipe: Recipe) { require(recipe.title.trim().isNotEmpty() && recipe.title.length <= 500); require(recipe.servings in 1..1000); require(recipe.ingredients.size <= 1000 && recipe.instructions.size <= 1000) }
 fun validate(meal: PlannedMeal) { require(meal.title.trim().isNotEmpty()); require(meal.dayIndex in 0..365); require(meal.servings in 1..1000); meal.date?.let { LocalDate.parse(it) } }
 fun consume(item: InventoryItem, quantity: Int, now: Double): InventoryItem {
  require(quantity > 0 && quantity <= item.quantity) { "Choose a quantity available in inventory." }
  return item.copy(quantity = item.quantity - quantity, updatedAt = now)
 }
 /** Exact normalized names AND package sizes only; ham never matches graham. Checked rows stay separate. */
 fun addGrocery(items: List<GroceryItem>, incoming: GroceryItem): List<GroceryItem> {
  validate(incoming)
  val match = items.indexOfFirst { !it.isChecked && !incoming.isChecked && key(it.name) == key(incoming.name) && key(it.sizeText) == key(incoming.sizeText) && it.recipeId == incoming.recipeId }
  if (match < 0) return items + incoming
  val existing = items[match]
  val total = Math.addExact(existing.quantity, incoming.quantity)
  require(total <= 100000) { "Combined quantity is too large." }
  return items.toMutableList().also { it[match] = existing.copy(quantity = total, updatedAt = maxOf(existing.updatedAt, incoming.updatedAt)) }
 }
 fun recipeGroceries(recipe: Recipe, now: Double): List<GroceryItem> = recipe.ingredients
  .filter { it.name.trim().isNotEmpty() }.map { GroceryItem(name=it.name.trim(), recipeSource=recipe.title, recipeId=recipe.id, sizeText=it.amount, updatedAt=now) }
}
