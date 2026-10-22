package com.sowens.stocked.ui

import org.junit.Assert.*
import org.junit.Test

class TimerAndQuantityTest {
    @Test fun futureDeadlineRearmsAndExpiredDeadlineNotifiesOnce() {
        assertEquals(TimerRules.Action.SCHEDULE,TimerRules.action(2000,0,1000))
        assertEquals(TimerRules.Action.NOTIFY,TimerRules.action(2000,0,2000))
        assertEquals(TimerRules.Action.NONE,TimerRules.action(2000,2000,3000))
    }
    @Test fun cancelledTimerDoesNotNotify() { assertEquals(TimerRules.Action.NONE,TimerRules.action(0,0,90000)) }
    @Test fun absoluteDeadlinePreservesTimeAcrossRestart() { assertEquals(601000L,TimerRules.deadline(1000L,10)) }
    @Test(expected=IllegalArgumentException::class) fun invalidDurationRefused() { TimerRules.deadline(0,0) }
    @Test fun commonFractionsScaleWithoutConvertingUnits() {
        assertEquals("1 cup",RecipeQuantities.scale("1/2 cup",2.0).text)
        assertEquals("3 tbsp",RecipeQuantities.scale("1 1/2 tbsp",2.0).text)
        assertEquals("3 cups",RecipeQuantities.scale("1½ cups",2.0).text)
        assertEquals("0.25 tsp",RecipeQuantities.scale("½ tsp",0.5).text)
        assertEquals("1 g",RecipeQuantities.scale("2 g",0.5).text)
    }
    @Test fun unknownUnitsRangesAndFreeTextAreNotGuessed() {
        listOf("1/0 cup","1-2 cups","1 handful","to taste","1,000 g").forEach { assertFalse(it,RecipeQuantities.scale(it,2.0).scaled); assertEquals(it,RecipeQuantities.scale(it,2.0).text) }
    }
}
