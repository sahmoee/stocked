package com.sowens.stocked.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.sowens.stocked.data.*

@Composable
fun GroceryScreen(state: KitchenState, save: (GroceryItem) -> Unit, delete: (String) -> Unit, toggle: (String) -> Unit) {
    var editing by remember { mutableStateOf<GroceryItem?>(null) }
    var query by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Field("Search groceries", query, { query = it })
        Button(onClick = { editing = GroceryItem(name = "") }) { Text("Add grocery") }
        Text("${state.grocery.count { !it.isChecked }} items left to buy")
        if (state.grocery.isEmpty()) EmptyState("Ready for your next shop", "Add groceries here or send recipe ingredients to this list. Matching unchecked entries are combined.")
        if (state.grocery.isNotEmpty() && state.grocery.none { it.name.contains(query, true) }) EmptyState("No matching groceries", "Try a different name or add the item.")
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            items(state.grocery.filter { it.name.contains(query, true) }.sortedBy { it.isChecked }, key = { it.id }) { item ->
                Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Column(Modifier.padding(12.dp)) {
                    Row { Checkbox(checked = item.isChecked, onCheckedChange = { toggle(item.id) }, modifier = Modifier.semantics { contentDescription = "${item.name}: purchased" }); Column(Modifier.weight(1f)) { Text(item.name, style = MaterialTheme.typography.titleMedium); Text("${item.quantity} · ${item.sizeText}"); if (item.recipeSource.isNotBlank()) Text("For ${item.recipeSource}") } }
                    Row { TextButton(onClick = { editing = item }) { Text("Edit") }; TextButton(onClick = { delete(item.id) }) { Text("Delete") } }
                } }
            }
        }
    }
    editing?.let { item ->
        var name by remember(item.id) { mutableStateOf(item.name) }; var quantity by remember { mutableStateOf(item.quantity.toString()) }; var size by remember { mutableStateOf(item.sizeText) }
        EditorDialog("Grocery item", name.isNotBlank() && quantity.toIntOrNull() in 1..100000, { save(item.copy(name = name.trim(), quantity = quantity.toInt(), sizeText = size.trim())); editing = null }, { editing = null }) {
            Field("Name", name, { name = it }); Field("Quantity", quantity, { quantity = it }, true); Field("Package size or amount", size, { size = it })
        }
    }
}
