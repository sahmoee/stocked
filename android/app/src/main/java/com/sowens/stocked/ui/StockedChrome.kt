package com.sowens.stocked.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.sowens.stocked.R

@Composable
fun StockedCard(modifier: Modifier=Modifier, fill: Color=MaterialTheme.colorScheme.surface, content: @Composable ColumnScope.()->Unit) {
    Card(modifier=modifier,shape=RoundedCornerShape(18.dp),colors=CardDefaults.cardColors(containerColor=fill),border=BorderStroke(0.65.dp,MaterialTheme.colorScheme.outlineVariant),elevation=CardDefaults.cardElevation(defaultElevation=0.dp),content=content)
}
@Composable
fun StockedCard(onClick: ()->Unit, modifier: Modifier=Modifier, fill: Color=MaterialTheme.colorScheme.surface, content: @Composable ColumnScope.()->Unit) {
    Card(onClick=onClick,modifier=modifier,shape=RoundedCornerShape(18.dp),colors=CardDefaults.cardColors(containerColor=fill),border=BorderStroke(0.65.dp,MaterialTheme.colorScheme.outlineVariant),elevation=CardDefaults.cardElevation(defaultElevation=0.dp),content=content)
}
@Composable
fun EditorialHero(eyebrow: String, title: String, subtitle: String, artwork: Int=0) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(vertical=12.dp)) {
        val stacked=maxWidth<350.dp || LocalDensity.current.fontScale>=1.3f
        val textBlock: @Composable ()->Unit = {
            Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(eyebrow,style=MaterialTheme.typography.labelMedium,color=StockedPalette.accent())
                Text(title,style=MaterialTheme.typography.headlineMedium)
                Text(subtitle,style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if(stacked) Column(verticalArrangement=Arrangement.spacedBy(10.dp)) { textBlock(); if(artwork!=0) Image(painterResource(artwork),null,Modifier.size(100.dp).align(Alignment.End)) }
        else Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) { Box(Modifier.weight(1f)) { textBlock() }; if(artwork!=0) Image(painterResource(artwork),null,Modifier.size(124.dp)) }
    }
}
@Composable fun kitchenArtwork() = if(LocalStockedDark.current) R.drawable.pastel_kitchen_hero_dark else R.drawable.pastel_kitchen_hero
@Composable fun mealArtwork() = if(LocalStockedDark.current) R.drawable.pastel_ready_meal_dark else R.drawable.pastel_ready_meal
@Composable fun produceArtwork() = if(LocalStockedDark.current) R.drawable.pastel_fresh_produce_dark else R.drawable.pastel_fresh_produce
