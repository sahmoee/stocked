@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.sowens.stocked.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.sowens.stocked.data.*
import java.time.LocalDate
import java.time.LocalTime

@Composable
fun HomeScreen(state: KitchenState, navigate: (Int)->Unit, scan: ()->Unit) {
    val today=LocalDate.now()
    val expiring=state.inventory.filter { it.quantity>0 && it.expirationDate?.let { date -> runCatching { LocalDate.parse(date)<=today.plusDays(7) }.getOrDefault(false) }==true }.sortedBy { it.expirationDate }
    val ready=state.userRecipes.count { recipe -> recipe.ingredients.isNotEmpty() && recipe.ingredients.all { ingredient -> state.inventory.any { it.quantity>0 && KitchenRules.key(it.name)==KitchenRules.key(ingredient.name) } } }
    val greeting=when(LocalTime.now().hour) { in 0..11 -> "Good morning"; in 12..16 -> "Good afternoon"; else -> "Good evening" }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal=20.dp),verticalArrangement=Arrangement.spacedBy(12.dp),contentPadding=PaddingValues(bottom=24.dp)) {
        item { EditorialHero(greeting,"Good food starts here.","A little planning. A well-stocked kitchen. Something delicious.",kitchenArtwork()) }
        item { StockedCard(fill=StockedPalette.oat(),onClick={ navigate(2) }) { Column(Modifier.padding(18.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment=Alignment.CenterVertically) { Text("Your kitchen",style=MaterialTheme.typography.titleLarge,modifier=Modifier.weight(1f)); Icon(Icons.Outlined.ChevronRight,null) }
            Text("${state.inventory.sumOf { it.quantity }} items in reach",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(12.dp)) { listOf("Fridge","Freezer","Pantry","Staples").forEach { zone -> Text("$zone  ${state.inventory.filter { it.storageCategory==zone }.sumOf { it.quantity }}",style=MaterialTheme.typography.labelMedium) } }
        } } }
        item { if(LocalDensity.current.fontScale>=1.3f) Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
            HomeFeature("Ready to cook","$ready saved recipes match your pantry",mealArtwork(),StockedPalette.garden(),Modifier.fillMaxWidth()) { navigate(3) }
            HomeFeature("Expiring soon","${expiring.size} items to use first",produceArtwork(),StockedPalette.peach(),Modifier.fillMaxWidth()) { navigate(2) }
        } else Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            HomeFeature("Ready to cook","$ready saved recipes match your pantry",mealArtwork(),StockedPalette.garden(),Modifier.weight(1f)) { navigate(3) }
            HomeFeature("Expiring soon","${expiring.size} items to use first",produceArtwork(),StockedPalette.peach(),Modifier.weight(1f)) { navigate(2) }
        } }
        item { StockedCard(onClick={ navigate(3) }) { Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) { Icon(Icons.Outlined.Lightbulb,null,tint=StockedPalette.accent()); Column(Modifier.weight(1f)) { Text("Try a recipe with what you have",style=MaterialTheme.typography.titleMedium); Text("Turn your ingredients into something great.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }; Icon(Icons.Outlined.ChevronRight,null) } } }
        item { Text("Your shortcuts",style=MaterialTheme.typography.titleLarge) }
        item { Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) { OutlinedButton(onClick=scan,modifier=Modifier.weight(1f)) { Icon(Icons.Outlined.QrCodeScanner,null,Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Scan") }; OutlinedButton(onClick={ navigate(4) },modifier=Modifier.weight(1f)) { Icon(Icons.Outlined.ShoppingCart,null,Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("${state.grocery.count { !it.isChecked }} to buy") } } }
        if(expiring.isNotEmpty()) item { StockedCard(fill=StockedPalette.peach()) { Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) { Text("Use It Soon",style=MaterialTheme.typography.titleLarge); expiring.take(4).forEach { Text("${it.name} · ${it.expirationDate}") }; TextButton(onClick={ navigate(2) }) { Text("View your kitchen") } } } }
        if(state.inventory.isEmpty()) item { StockedCard { Column(Modifier.padding(18.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) { Text("Let's stock your kitchen",style=MaterialTheme.typography.titleLarge); Text("Add a few items to track what you have, what's expiring, and your next grocery trip."); Button(onClick={ navigate(2) }) { Text("Open Kitchen") } } } }
    }
}
@Composable private fun HomeFeature(title:String,detail:String,artwork:Int,fill:androidx.compose.ui.graphics.Color,modifier:Modifier,onClick:()->Unit) {
    StockedCard(onClick=onClick,modifier=modifier,fill=fill) { Column(Modifier.padding(14.dp),verticalArrangement=Arrangement.spacedBy(6.dp)) { Image(painterResource(artwork),null,Modifier.height(90.dp).fillMaxWidth()); Text(title,style=MaterialTheme.typography.titleMedium); Text(detail,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) } }
}
