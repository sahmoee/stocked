@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

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
import java.time.LocalDate

@Composable
fun InventoryScreen(state: KitchenState, save: (InventoryItem) -> Unit, delete: (String) -> Unit, consume: (String, Int) -> Unit, initialQuery: String = "") {
    var zone by remember { mutableStateOf("All") }
    var query by remember(initialQuery) { mutableStateOf(initialQuery) }
    var editing by remember { mutableStateOf<InventoryItem?>(null) }
    var deleting by remember { mutableStateOf<InventoryItem?>(null) }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        EditorialHero("Your kitchen, at a glance", "Good food, all in reach.", "Browse, stay organized, and know what you have.", produceArtwork())
        FlowRow(horizontalArrangement=Arrangement.spacedBy(4.dp)) { listOf("All","Fridge","Freezer","Pantry","Staples").forEach { value -> FilterChip(selected=zone==value,onClick={ zone=value },label={ Text(value) }) } }
        Field("Search inventory", query, { query = it })
        Button(onClick = { editing = InventoryItem(name = "") }) { Text("Add item") }
        val filtered = state.inventory.filter { it.name.contains(query, true) && (zone=="All" || it.storageCategory==zone) }.sortedBy { it.expirationDate ?: "9999" }
        if (filtered.isEmpty()) EmptyState("Your pantry starts here", "Add food, its storage zone and expiry date. Search results appear here too.")
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
            items(filtered, key = { it.id }) { item ->
                StockedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(item.name, style = MaterialTheme.typography.titleMedium)
                    Text("${item.quantity} ${item.containerType} · ${item.storageCategory}")
                    item.expirationDate?.let { Text("Expires $it", color = if (runCatching { LocalDate.parse(it).isBefore(LocalDate.now()) }.getOrDefault(false)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { editing = item }) { Text("Edit") }
                        TextButton(onClick = { consume(item.id, 1) }, enabled = item.quantity > 0) { Text("Use one") }
                        TextButton(onClick = { deleting = item }) { Text("Delete") }
                    }
                } }
            }
        }
    }
    editing?.let { original -> InventoryEditor(original, { save(it); editing = null }, { editing = null }) }
    deleting?.let { item -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete ${item.name}?") }, text = { Text("This removes the inventory entry.") }, confirmButton = { TextButton(onClick = { delete(item.id); deleting = null }) { Text("Delete") } }, dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }) }
}

@Composable
private fun InventoryEditor(item: InventoryItem, save: (InventoryItem) -> Unit, dismiss: () -> Unit) {
    var name by remember(item.id) { mutableStateOf(item.name) }
    var quantity by remember { mutableStateOf(item.quantity.toString()) }
    var container by remember { mutableStateOf(item.containerType) }
    var zone by remember { mutableStateOf(item.storageCategory) }
    var expiry by remember { mutableStateOf(item.expirationDate.orEmpty()) }
    var brand by remember { mutableStateOf(item.brand.orEmpty()) }
    var size by remember { mutableStateOf(item.sizeAmount?.toString().orEmpty()) }
    var unit by remember { mutableStateOf(item.sizeUnit.orEmpty()) }
    var price by remember { mutableStateOf(item.price?.toString().orEmpty()) }
    var barcode by remember { mutableStateOf(item.barcode.orEmpty()) }
    var level by remember { mutableStateOf(item.level.toFloat()) }
    val valid = (price.isBlank() || (price.toDoubleOrNull()?.let { it.isFinite() && it >= 0 } == true)) && name.isNotBlank() && quantity.toIntOrNull() in 0..100000 && (expiry.isBlank() || runCatching { LocalDate.parse(expiry) }.isSuccess) && (size.isBlank() || (size.toDoubleOrNull()?.let { it.isFinite() && it > 0 } == true))
    EditorDialog("Inventory item", valid, { save(item.copy(name = name.trim(), quantity = quantity.toInt(), containerType = container.trim(), storageCategory = zone, expirationDate = expiry.ifBlank { null }, brand = brand.ifBlank { null }, sizeAmount = size.toDoubleOrNull(), sizeUnit = unit.ifBlank { null }, price = price.toDoubleOrNull(), barcode = barcode.ifBlank { null }, level = level.toDouble())) }, dismiss) {
        Field("Name", name, { name = it }); Field("Quantity", quantity, { quantity = it }, true)
        Field("Container (item, can, bottle…)", container, { container = it })
        Text("Storage zone")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) { listOf("Pantry", "Fridge", "Freezer", "Staples").forEach { value -> FilterChip(selected = zone == value, onClick = { zone = value }, label = { Text(value) }) } }
        Field("Expiry YYYY-MM-DD (optional)", expiry, { expiry = it }); Field("Brand (optional)", brand, { brand = it })
        Field("Size (optional)", size, { size = it }, true); Field("Size unit (g, ml…)", unit, { unit = it })
        Field("Price (optional)", price, { price = it }, true); Field("Barcode (optional)", barcode, { barcode = it })
        Text("Fill level: ${(level * 100).toInt()}%")
        Slider(value = level, onValueChange = { level = it }, modifier = Modifier.semantics { contentDescription = "Container fill level" })
        if (!valid) Text("Enter a name, a whole quantity and a valid date/size.", color = MaterialTheme.colorScheme.error)
    }
}
