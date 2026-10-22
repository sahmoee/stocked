package com.sowens.stocked.imports

import com.sowens.stocked.data.*
import org.json.JSONArray
import org.json.JSONObject

object RecipeImporter {
    const val MAX_BYTES = 2 * 1024 * 1024
    fun parse(text: String, source: String? = null): List<Recipe> {
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "Import exceeds 2 MB." }
        val input = text.trim().removePrefix("\uFEFF")
        require(input.isNotBlank()) { "Paste a recipe or select a file." }
        val recipes = when {
            input.startsWith("{") || input.startsWith("[") -> json(input, source)
            input.lineSequence().first().lowercase().contains("title,") || input.lineSequence().first().lowercase().startsWith("title,") -> csv(input)
            else -> listOf(plain(input, source))
        }
        require(recipes.isNotEmpty()) { "No recipes were found." }; require(recipes.size <= 250) { "Import at most 250 recipes at a time." }
        recipes.forEach { KitchenRules.validate(it); require(it.ingredients.all { ingredient -> ingredient.name.length <= 500 && ingredient.amount.length <= 500 }) { "Ingredient is too long." } }
        return recipes
    }
    fun json(text: String, source: String? = null): List<Recipe> {
        val root: Any = if (text.trim().startsWith("[")) JSONArray(text) else JSONObject(text)
        val result = mutableListOf<Recipe>()
        fun visit(node: Any?) {
            when (node) {
                is JSONArray -> for (index in 0 until node.length()) visit(node.opt(index))
                is JSONObject -> {
                    val type = node.opt("@type")
                    val isRecipe = type == "Recipe" || type is JSONArray && (0 until type.length()).any { type.optString(it) == "Recipe" }
                    val title = node.optString("title").ifBlank { node.optString("name") }
                    if (isRecipe || title.isNotBlank() && (node.has("ingredients") || node.has("recipeIngredient") || node.has("instructions"))) {
                        val ingredients = node.optJSONArray("ingredients") ?: node.optJSONArray("recipeIngredient") ?: JSONArray()
                        val steps = mutableListOf<String>()
                        fun step(value: Any?) { when (value) { is String -> if (value.isNotBlank()) steps.add(clean(value)); is JSONArray -> for (i in 0 until value.length()) step(value.opt(i)); is JSONObject -> { if (value.has("text")) step(value.opt("text")); else step(value.opt("itemListElement")) } } }
                        step(node.opt("instructions") ?: node.opt("recipeInstructions"))
                        val tagsValue = node.opt("tags") ?: node.opt("keywords")
                        val tags = when(tagsValue) { is JSONArray -> (0 until tagsValue.length()).map { tagsValue.optString(it) }; is String -> tagsValue.split(',').map { it.trim() }; else -> emptyList() }
                        result += Recipe(title = clean(title), description = clean(node.optString("description")),
                            servings = node.optInt("servings", 0).takeIf { it > 0 } ?: Regex("\\d+").find(node.optString("recipeYield"))?.value?.toIntOrNull()?.coerceIn(1,1000) ?: 4,
                            ingredients = (0 until ingredients.length()).mapNotNull { i -> val value = ingredients.opt(i); when (value) { is JSONObject -> Ingredient(name = value.optString("name"), amount = value.optString("amount")); is String -> Ingredient(name = clean(value)); else -> null } },
                            instructions = steps, prepTime = node.optString("prepTime"), cookTime = node.optString("cookTime"), tags = tags,
                            cuisine = node.optString("cuisine").ifBlank { node.optString("recipeCuisine") }, notes = node.optString("notes"),
                            sourceURL = node.optString("sourceURL").ifBlank { source.orEmpty() }.ifBlank { null },
                            sourceName = node.optString("sourceName").ifBlank { null }, license = node.optString("license").ifBlank { null })
                    } else {
                        listOf("@graph", "userRecipes", "recipes", "data").forEach { if (node.has(it)) visit(node.opt(it)) }
                    }
                }
            }
        }
        visit(root); return result
    }
    private fun clean(value: String): String {
        val tags = value.replace(Regex("<[^>]+>"), " ")
        return Regex("&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);").replace(tags) { match ->
            val entity = match.groupValues[1]
            when(entity) { "amp" -> "&"; "lt" -> "<"; "gt" -> ">"; "quot" -> "\""; "apos" -> "'"; "nbsp" -> " "; else -> {
                val code = if(entity.startsWith("#x")) entity.drop(2).toIntOrNull(16) else entity.drop(1).toIntOrNull()
                if(code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else match.value
            } }
        }.trim()
    }
    private fun plain(input: String, source: String?): Recipe {
        val lines = input.lines().map { it.trim() }.filter { it.isNotBlank() }
        val metadata = lines.filter { it.startsWith(">>") }.mapNotNull { val parts = it.removePrefix(">>").split(':', limit=2); if(parts.size==2) parts[0].trim().lowercase() to parts[1].trim() else null }.toMap()
        val cooklang = lines.any { it.contains('@') }
        val title = metadata["title"] ?: metadata["name"] ?: if (cooklang) "Imported Cooklang recipe" else lines.first().removePrefix("#").trim()
        val ingredients = mutableListOf<Ingredient>(); val steps = mutableListOf<String>(); var section = ""
        lines.drop(if(metadata.isEmpty() && !cooklang) 1 else 0).forEach { line ->
            when {
                line.startsWith(">>") || line.startsWith("--") -> Unit
                line.trimEnd(':').equals("ingredients", true) -> section = "ingredients"
                line.trimEnd(':').lowercase() in listOf("instructions", "directions", "steps") -> section = "steps"
                line.contains('@') -> {
                    val ingredientPattern = Regex("@([^@{}]+)\\{([^}]*)}|@([\\p{L}\\p{N}_-]+)")
                    ingredientPattern.findAll(line).forEach { match -> ingredients += Ingredient(name = match.groupValues[1].ifBlank { match.groupValues[3] }.trim(), amount = match.groupValues[2].replace('%',' ')) }
                    val instruction = line.replace(ingredientPattern) { it.groupValues[1].ifBlank { it.groupValues[3] }.trim() }.replace(Regex("~([^{}]*)\\{([^}]*)}")) { "${it.groupValues[1]} ${it.groupValues[2].replace('%',' ')}" }
                    steps += instruction
                }
                section == "ingredients" -> ingredients += Ingredient(name = line.removePrefix("-").trim())
                else -> steps += line.removePrefix("-").trim()
            }
        }
        require(ingredients.isNotEmpty() || steps.isNotEmpty()) { "Include ingredients or cooking steps." }
        return Recipe(title = title, ingredients = ingredients.distinctBy { KitchenRules.key(it.name) }, instructions = steps, sourceURL = source, sourceName = metadata["source"], license = metadata["license"], servings = metadata["servings"]?.toIntOrNull()?.coerceIn(1,1000) ?: 4)
    }
    private fun csv(input: String): List<Recipe> {
        val rows = mutableListOf<List<String>>(); val row = mutableListOf<String>(); val field = StringBuilder(); var quoted = false; var index = 0
        while(index < input.length) { val char = input[index]; when { char == '"' -> if(quoted && index+1<input.length && input[index+1]=='"') { field.append('"'); index++ } else quoted = !quoted; char == ',' && !quoted -> { row += field.toString(); field.setLength(0) }; char == '\n' && !quoted -> { row += field.toString().trimEnd('\r'); field.setLength(0); rows += row.toList(); row.clear() }; else -> field.append(char) }; index++ }
        require(!quoted) { "CSV contains an unfinished quoted field." }; if(field.isNotEmpty() || row.isNotEmpty()) { row += field.toString(); rows += row.toList() }
        require(rows.isNotEmpty()); val header = rows.first().map { it.trim().lowercase() }; require("title" in header) { "CSV needs a title column." }
        return rows.drop(1).filter { it.any { field -> field.isNotBlank() } }.map { values -> fun get(key:String):String = header.indexOf(key).takeIf { it>=0 }?.let { values.getOrNull(it) }.orEmpty()
            Recipe(title = get("title"), description = get("description"), servings = get("servings").toIntOrNull()?.coerceIn(1,1000) ?: 4, ingredients = get("ingredients").split('\n',';').filter { it.isNotBlank() }.map { Ingredient(name=it.trim()) }, instructions = get("instructions").split('\n',';').filter { it.isNotBlank() }, sourceURL=get("sourceurl").ifBlank { null }, license=get("license").ifBlank { null }) }
    }
}
