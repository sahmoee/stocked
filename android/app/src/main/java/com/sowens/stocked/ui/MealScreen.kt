@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.sowens.stocked.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sowens.stocked.data.*
import java.time.LocalDate

@Composable
fun MealScreen(state: KitchenState, pending: Recipe?, clearPending: () -> Unit, save: (PlannedMeal) -> Unit, delete: (String) -> Unit, groceries: (String) -> Unit, cooked: (String) -> Unit, browseRecipes: () -> Unit = {}) {
    var editing by remember { mutableStateOf<PlannedMeal?>(null) }
    LaunchedEffect(pending?.id) { pending?.let { editing = PlannedMeal(title = it.title, servings = it.servings, ingredients = it.ingredients.map { ingredient -> "${ingredient.amount} ${ingredient.name}".trim() }, date = LocalDate.now().toString()); clearPending() } }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        EditorialHero("Make something good", "What’s on the menu?", "Good food starts with what you have. Cook something now, or plan the week ahead.", mealArtwork())
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { OutlinedButton(onClick=browseRecipes) { Text("My recipes & timers") }; Button(onClick = { editing = PlannedMeal(title = "", date = LocalDate.now().toString()) }) { Text("Plan meal") } }
        if (state.planned.isEmpty()) EmptyState("Make room for dinner", "Choose a date and meal, or plan a saved recipe from its detail screen.")
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            items(state.planned.sortedBy { it.date ?: "9999" }, key = { it.id }) { meal ->
                StockedCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Column(Modifier.padding(16.dp)) {
                    Text(meal.title, style = MaterialTheme.typography.titleLarge)
                    Text("${meal.date ?: LocalDate.now().plusDays(meal.dayIndex.toLong()).toString()} · ${meal.mealType} · ${meal.servings} servings")
                    if (meal.isCooked) Text("Cooked")
                    FlowRow { TextButton(onClick = { editing = meal }) { Text("Edit") }; TextButton(onClick = { groceries(meal.id) }) { Text("Groceries") }; TextButton(onClick = { cooked(meal.id) }, enabled = !meal.isCooked) { Text("Mark cooked") }; TextButton(onClick = { delete(meal.id) }) { Text("Delete") } }
                } }
            }
        }
    }
    editing?.let { meal ->
        var title by remember(meal.id) { mutableStateOf(meal.title) }; var date by remember { mutableStateOf(meal.date ?: LocalDate.now().plusDays(meal.dayIndex.toLong()).toString()) }; var type by remember { mutableStateOf(meal.mealType) }; var servings by remember { mutableStateOf(meal.servings.toString()) }; var ingredients by remember { mutableStateOf(meal.ingredients.joinToString("\n")) }
        EditorDialog("Plan a meal", title.isNotBlank() && servings.toIntOrNull() in 1..1000 && runCatching { java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), LocalDate.parse(date)) in 0L..365L }.getOrDefault(false), { save(meal.copy(title = title.trim(), date = date, dayIndex = java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), LocalDate.parse(date)).toInt(), mealType = type.trim(), servings = servings.toInt(), ingredients = ingredients.lines().filter { it.isNotBlank() })); editing = null }, { editing = null }) {
            Field("Title", title, { title = it }); Field("Date YYYY-MM-DD", date, { date = it }); Field("Meal type", type, { type = it }); Field("Servings", servings, { servings = it }, true); Field("Ingredients — one per line", ingredients, { ingredients = it }, lines = 3)
            Text("Marking cooked tracks the plan. Use the recipe's ingredient dialog to adjust pantry quantities.", style = MaterialTheme.typography.bodySmall)
        }
    }
}
