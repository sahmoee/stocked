package com.sowens.stocked.ui

object TimerRules {
    enum class Action { NONE, SCHEDULE, NOTIFY }
    fun action(deadline: Long, notifiedDeadline: Long, now: Long): Action = when {
        deadline <= 0 || notifiedDeadline == deadline -> Action.NONE
        deadline > now -> Action.SCHEDULE
        else -> Action.NOTIFY
    }
    fun deadline(now: Long, minutes: Long): Long {
        require(minutes in 1L..1440L) { "Choose between 1 and 1,440 minutes." }
        return Math.addExact(now, Math.multiplyExact(minutes, 60000L))
    }
}
