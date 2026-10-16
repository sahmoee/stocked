package com.sowens.stocked.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import java.util.UUID

@Serializable data class InventoryItem(
 val id: String = UUID.randomUUID().toString(), val name: String,
 val quantity: Int = 1, val containerType: String = "item",
 val sizeAmount: Double? = null, val sizeUnit: String? = null,
 val level: Double = 1.0, val storageCategory: String = "Pantry",
 val expirationDate: String? = null, val brand: String? = null,
 val price: Double? = null, val barcode: String? = null,
 val updatedAt: Double = 0.0, val lastWriterID: String = "",
 val extra: JsonObject = JsonObject(emptyMap())
)
@Serializable data class GroceryItem(
 val id: String = UUID.randomUUID().toString(), val name: String,
 val quantity: Int = 1, val isChecked: Boolean = false,
 val recipeSource: String = "", val recipeId: String = "", val sizeText: String = "",
 val updatedAt: Double = 0.0, val lastWriterID: String = "",
 val extra: JsonObject = JsonObject(emptyMap())
)
@Serializable data class Ingredient(val id: String = UUID.randomUUID().toString(), val name: String, val amount: String = "", val extra: JsonObject = JsonObject(emptyMap()))
@Serializable data class Recipe(
 val id: String = UUID.randomUUID().toString(), val title: String,
 val description: String = "", val servings: Int = 4, val prepTime: String = "", val cookTime: String = "",
 val ingredients: List<Ingredient> = emptyList(), val instructions: List<String> = emptyList(),
 val tags: List<String> = emptyList(), val cuisine: String = "", val notes: String = "",
 val sourceURL: String? = null, val sourceName: String? = null, val license: String? = null,
 val imageURL: String? = null, val isFavorited: Boolean = false, val cookCount: Int = 0,
 val updatedAt: Double = 0.0, val lastWriterID: String = "",
 val extra: JsonObject = JsonObject(emptyMap())
)
@Serializable data class PlannedMeal(
 val id: String = UUID.randomUUID().toString(), val title: String,
 val dayIndex: Int = 0, val date: String? = null, val servings: Int = 4, val mealType: String = "Dinner",
 val ingredients: List<String> = emptyList(), val isCooked: Boolean = false,
 val updatedAt: Double = 0.0, val lastWriterID: String = "",
 val extra: JsonObject = JsonObject(emptyMap())
)
@Serializable data class KitchenState(
 val schemaVersion: Int = 1, val inventory: List<InventoryItem> = emptyList(),
 val grocery: List<GroceryItem> = emptyList(), val userRecipes: List<Recipe> = emptyList(),
 val planned: List<PlannedMeal> = emptyList(), val extra: JsonObject = JsonObject(emptyMap())
)
data class ImportPreview(val incoming: KitchenState, val conflicts: List<String>, val warnings: List<String>)
