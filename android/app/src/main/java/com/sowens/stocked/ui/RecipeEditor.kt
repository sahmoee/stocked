package com.sowens.stocked.ui

import androidx.compose.runtime.*
import com.sowens.stocked.data.*

@Composable
fun RecipeEditor(recipe: Recipe, save: (Recipe) -> Unit, dismiss: () -> Unit) {
    var title by remember(recipe.id) { mutableStateOf(recipe.title) }
    var description by remember { mutableStateOf(recipe.description) }
    var servings by remember { mutableStateOf(recipe.servings.toString()) }
    var ingredients by remember { mutableStateOf(recipe.ingredients.joinToString("\n") { "${it.amount} | ${it.name}" }) }
    var steps by remember { mutableStateOf(recipe.instructions.joinToString("\n")) }
    var prep by remember { mutableStateOf(recipe.prepTime) }
    var cook by remember { mutableStateOf(recipe.cookTime) }
    var notes by remember { mutableStateOf(recipe.notes) }
    var cuisine by remember { mutableStateOf(recipe.cuisine) }
    var tags by remember { mutableStateOf(recipe.tags.joinToString(", ")) }
    var source by remember { mutableStateOf(recipe.sourceURL.orEmpty()) }
    EditorDialog("Recipe", title.isNotBlank() && servings.toIntOrNull() in 1..1000, {
        save(recipe.copy(title = title.trim(), description = description, servings = servings.toInt(), prepTime = prep, cookTime = cook,
            ingredients = ingredients.lines().filter { it.isNotBlank() }.map { line -> val split = line.split('|', limit = 2); if (split.size == 2) Ingredient(name = split[1].trim(), amount = split[0].trim()) else Ingredient(name = line.trim()) },
            instructions = steps.lines().map { it.trim() }.filter { it.isNotBlank() }, notes = notes, cuisine = cuisine, tags = tags.split(",").map { it.trim() }.filter { it.isNotBlank() }, sourceURL = source.ifBlank { null }))
    }, dismiss) {
        Field("Title", title, { title = it }); Field("Description", description, { description = it }, lines = 2)
        Field("Servings", servings, { servings = it }, true); Field("Prep time", prep, { prep = it }); Field("Cook time", cook, { cook = it })
        Field("Ingredients — one per line: amount | name", ingredients, { ingredients = it }, lines = 4)
        Field("Instructions — one step per line", steps, { steps = it }, lines = 4); Field("Notes", notes, { notes = it }, lines = 2)
        Field("Cuisine", cuisine, { cuisine = it }); Field("Tags (comma separated)", tags, { tags = it }); Field("Source URL (optional)", source, { source = it })
    }
}
