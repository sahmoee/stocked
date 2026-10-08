package com.sowens.stocked.imports

import org.junit.Assert.*
import org.junit.Test

class RecipeImporterTest {
    @Test fun cooklangPreservesSourceAndQuantities() {
        val recipe=RecipeImporter.parse(">> title: Pasta\n>> source: Family\n>> license: CC0\nBoil @pasta{200%g}. Add @salt{1%tsp}.").single()
        assertEquals("Pasta",recipe.title); assertEquals("Family",recipe.sourceName); assertEquals("CC0",recipe.license)
        assertEquals(listOf("pasta","salt"),recipe.ingredients.map { it.name }); assertEquals("200 g",recipe.ingredients.first().amount)
        assertTrue(recipe.instructions.single().contains("Boil pasta"))
    }
    @Test fun plainSectionsAreSeparated() {
        val recipe=RecipeImporter.parse("Soup\nIngredients:\nCarrots\nStock\nInstructions:\nSimmer for 20 minutes").single()
        assertEquals(2,recipe.ingredients.size); assertEquals(listOf("Simmer for 20 minutes"),recipe.instructions)
    }
    @Test fun csvHandlesQuotedCommaAndMultiline() {
        val recipe=RecipeImporter.parse("title,ingredients,instructions,servings\n\"Soup, warm\",\"carrots;stock\",\"Simmer\nServe\",2").single()
        assertEquals("Soup, warm",recipe.title); assertEquals(2,recipe.ingredients.size); assertEquals(2,recipe.instructions.size); assertEquals(2,recipe.servings)
    }
    @Test(expected=IllegalArgumentException::class) fun unfinishedCsvRefused() { RecipeImporter.parse("title,ingredients\n\"Soup,carrots") }
    @Test(expected=IllegalArgumentException::class) fun importLimitEnforced() { RecipeImporter.parse("x".repeat(RecipeImporter.MAX_BYTES+1)) }
    @Test fun structuredRecipeSectionsAndAttribution() {
        val recipe=RecipeImporter.parse("""{"@graph":[{"@type":["Thing","Recipe"],"name":"Soup &amp; bread","recipeYield":"2 servings","recipeIngredient":["2 carrots"],"recipeInstructions":[{"@type":"HowToSection","itemListElement":[{"text":"<p>Simmer</p>"}]}],"license":"CC0"}]}""", "https://example.com/soup").single()
        assertEquals("Soup & bread",recipe.title); assertEquals(2,recipe.servings); assertEquals(listOf("Simmer"),recipe.instructions); assertEquals("https://example.com/soup",recipe.sourceURL); assertEquals("CC0",recipe.license)
    }
    @Test fun htmlJsonLdScriptIsLocated() {
        val recipes=RecipeWebFetcher.extractRecipes("""<html><script type="application/ld+json">{"@type":"Recipe","name":"Soup","recipeIngredient":["Carrot"],"recipeInstructions":["Cook"]}</script></html>""", "https://example.com/soup")
        assertEquals("Soup",recipes.single().title)
    }
    @Test fun privateNetworkAddressRangesRefused() {
        listOf("127.0.0.1","10.2.3.4","172.16.1.1","192.168.1.1","169.254.169.254","100.64.0.1","::1","fd00::1").forEach { assertTrue(it,RecipeWebFetcher.privateAddress(java.net.InetAddress.getByName(it))) }
        assertFalse(RecipeWebFetcher.privateAddress(java.net.InetAddress.getByName("8.8.8.8")))
    }
}
