package com.sowens.stocked.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val LocalStockedDark = staticCompositionLocalOf { false }
val LocalSetStockedDark = staticCompositionLocalOf<(Boolean) -> Unit> { {} }

object StockedPalette {
    val cream=Color(0xFFFDF7EF); val charcoal=Color(0xFF43392F); val ink=Color(0xFF3D3228)
    val honey=Color(0xFFD2AF6A); val sage=Color(0xFF90A280)
    @Composable fun oat()=if(LocalStockedDark.current) Color(0xFF3D362B) else Color(0xFFF1E4CF)
    @Composable fun garden()=if(LocalStockedDark.current) Color(0xFF2E3829) else Color(0xFFE9ECDC)
    @Composable fun peach()=if(LocalStockedDark.current) Color(0xFF423329) else Color(0xFFFAEAD6)
    @Composable fun accent()=if(LocalStockedDark.current) Color(0xFFD5B36B) else Color(0xFF806231)
}

@Composable
fun StockedTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("stocked-appearance", Context.MODE_PRIVATE) }
    var dark by remember { mutableStateOf(prefs.getBoolean("dark", false)) }
    CompositionLocalProvider(LocalStockedDark provides dark, LocalSetStockedDark provides { value -> dark=value; prefs.edit().putBoolean("dark",value).apply() }) {
    val colors = if (dark) darkColorScheme(
        primary=Color(0xFFD5B36B), onPrimary=Color(0xFF211E1A), primaryContainer=Color(0xFF3D362B),
        background=Color(0xFF161410), surface=Color(0xFF211E1A), surfaceContainer=Color(0xFF211E1A), surfaceContainerLow=Color(0xFF211E1A), surfaceContainerHigh=Color(0xFF29251F),
        onBackground=Color(0xFFFFFAF3), onSurface=Color(0xFFFFFAF3), onSurfaceVariant=Color(0xFFBDB4A7), outlineVariant=Color(0xFF595245),
        secondary=Color(0xFFB1C8A0), surfaceTint=Color.Transparent
    ) else lightColorScheme(
        primary=StockedPalette.charcoal, onPrimary=Color(0xFFFFFAF3), primaryContainer=StockedPalette.oat(), onPrimaryContainer=StockedPalette.ink,
        background=StockedPalette.cream, surface=Color(0xFFFFFAF3), surfaceContainer=Color(0xFFFFFAF3), surfaceContainerLow=Color(0xFFFFFAF3), surfaceContainerHigh=StockedPalette.oat(),
        onBackground=StockedPalette.ink, onSurface=StockedPalette.ink, onSurfaceVariant=Color(0xFF635C54), outlineVariant=Color(0xFFDDD3C3),
        secondary=Color(0xFF566B4A), surfaceTint=Color.Transparent
    )
    val serif=FontFamily.Serif; val sans=FontFamily.SansSerif
    val type=Typography(
        headlineLarge=TextStyle(fontFamily=serif,fontWeight=FontWeight.Bold,fontSize=34.sp,lineHeight=39.sp,letterSpacing=(-0.6).sp),
        headlineMedium=TextStyle(fontFamily=serif,fontWeight=FontWeight.Bold,fontSize=30.sp,lineHeight=35.sp,letterSpacing=(-0.6).sp),
        headlineSmall=TextStyle(fontFamily=serif,fontWeight=FontWeight.SemiBold,fontSize=26.sp,lineHeight=31.sp),
        titleLarge=TextStyle(fontFamily=serif,fontWeight=FontWeight.SemiBold,fontSize=22.sp,lineHeight=27.sp),
        titleMedium=TextStyle(fontFamily=serif,fontWeight=FontWeight.SemiBold,fontSize=18.sp,lineHeight=23.sp),
        titleSmall=TextStyle(fontFamily=sans,fontWeight=FontWeight.SemiBold,fontSize=14.sp,lineHeight=19.sp),
        bodyLarge=TextStyle(fontFamily=sans,fontSize=16.sp,lineHeight=23.sp),
        bodyMedium=TextStyle(fontFamily=sans,fontSize=14.sp,lineHeight=21.sp),
        bodySmall=TextStyle(fontFamily=sans,fontSize=12.sp,lineHeight=17.sp),
        labelLarge=TextStyle(fontFamily=sans,fontWeight=FontWeight.SemiBold,fontSize=14.sp,lineHeight=18.sp),
        labelMedium=TextStyle(fontFamily=sans,fontWeight=FontWeight.Medium,fontSize=12.sp,lineHeight=16.sp),
        labelSmall=TextStyle(fontFamily=sans,fontWeight=FontWeight.Medium,fontSize=11.sp,lineHeight=14.sp)
    )
    MaterialTheme(colorScheme=colors, typography=type, shapes=Shapes(small=RoundedCornerShape(12.dp),medium=RoundedCornerShape(18.dp),large=RoundedCornerShape(22.dp)), content=content)
    }
}
