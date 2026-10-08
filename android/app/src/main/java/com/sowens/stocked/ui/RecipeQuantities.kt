package com.sowens.stocked.ui

import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale

object RecipeQuantities {
    data class Result(val text: String, val scaled: Boolean)
    private val fractions=mapOf('¼' to 0.25,'½' to 0.5,'¾' to 0.75,'⅓' to 1.0/3,'⅔' to 2.0/3,'⅛' to 0.125,'⅜' to 0.375,'⅝' to 0.625,'⅞' to 0.875,'⅕' to 0.2,'⅖' to 0.4,'⅗' to 0.6,'⅘' to 0.8,'⅙' to 1.0/6,'⅚' to 5.0/6)
    private val units=setOf("g","kg","mg","gram","grams","kilogram","kilograms","ml","l","liter","liters","litre","litres","milliliter","milliliters","tsp","tsps","teaspoon","teaspoons","tbsp","tbsps","tablespoon","tablespoons","cup","cups","oz","ounce","ounces","lb","lbs","pound","pounds","fl","fluid","clove","cloves","can","cans","bottle","bottles","item","items","piece","pieces","slice","slices","pinch","pinches","bunch","bunches","package","packages","packet","packets","stalk","stalks","sprig","sprigs","small","medium","large")
    fun scale(input: String, factor: Double): Result {
        if(!factor.isFinite() || factor<=0 || input.isBlank()) return Result(input,false)
        val text=input.trim()
        var value:Double?=null; var suffix=""
        val fraction=Regex("^(?:(\\d+)\\s+)?(\\d+)\\s*/\\s*(\\d+)(.*)$").matchEntire(text)
        val unicode=Regex("^(\\d+)?\\s*([¼½¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚])(.*)$").matchEntire(text)
        val decimal=Regex("^(\\d+(?:\\.\\d+)?)(.*)$").matchEntire(text)
        when {
            fraction!=null -> { val denominator=fraction.groupValues[3].toDoubleOrNull() ?: return Result(input,false); if(denominator==0.0) return Result(input,false); value=(fraction.groupValues[1].toDoubleOrNull() ?: 0.0)+(fraction.groupValues[2].toDoubleOrNull() ?: return Result(input,false))/denominator; suffix=fraction.groupValues[4] }
            unicode!=null -> { value=(unicode.groupValues[1].toDoubleOrNull() ?: 0.0)+fractions.getValue(unicode.groupValues[2].single()); suffix=unicode.groupValues[3] }
            decimal!=null -> { value=decimal.groupValues[1].toDoubleOrNull(); suffix=decimal.groupValues[2] }
        }
        val unit=suffix.trim().substringBefore(' ').trimEnd('.').lowercase(Locale.ROOT)
        if(value==null || !value.isFinite() || (unit.isNotEmpty() && unit !in units)) return Result(input,false)
        val scaled=value*factor
        if(!scaled.isFinite()) return Result(input,false)
        val number=BigDecimal.valueOf(scaled).setScale(3,RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
        return Result(number + suffix,true)
    }
}
