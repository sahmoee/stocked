package com.sowens.stocked.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

@Composable
fun StockedTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Color(0xFFD5B36B), onPrimary = Color(0xFF211E1A),
        background = Color(0xFF161410), surface = Color(0xFF211E1A),
        onBackground = Color(0xFFFFFAF3), onSurface = Color(0xFFFFFAF3),
        secondary = Color(0xFFB1C8A0)
    ) else lightColorScheme(
        primary = Color(0xFF806231), onPrimary = Color.White,
        background = Color(0xFFFDF7EF), surface = Color(0xFFFFFAF3),
        onBackground = Color(0xFF3D3228), onSurface = Color(0xFF3D3228),
        secondary = Color(0xFF566B4A)
    )
    MaterialTheme(colorScheme = colors, content = content)
}
