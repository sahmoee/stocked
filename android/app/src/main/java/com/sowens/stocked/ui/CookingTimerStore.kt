package com.sowens.stocked.ui

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build

object CookingTimerStore {
    private const val PREFS = "stocked-cooking-timer"
    private const val CHANNEL = "cooking-timers"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS,Context.MODE_PRIVATE)
    fun deadline(context: Context, recipeId: String): Long? { val prefs=prefs(context); return if(prefs.getString("recipe",null)==recipeId) prefs.getLong("deadline",0).takeIf { it>0 } else null }
    fun canScheduleExact(context: Context): Boolean = Build.VERSION.SDK_INT<31 || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    fun exactScheduled(context: Context): Boolean = prefs(context).getBoolean("exactScheduled",false)
    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(context,42,Intent(context,CookingTimerReceiver::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun schedule(context: Context, end: Long) {
        val manager=context.getSystemService(AlarmManager::class.java)
        val intent=pending(context)
        val exact = if(canScheduleExact(context)) {
            try { manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,end,intent); true }
            catch(_: SecurityException) { manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,end,intent); false }
        } else { manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,end,intent); false }
        prefs(context).edit().putBoolean("exactScheduled",exact).apply()
    }
    @Synchronized fun start(context: Context, recipeId: String, title: String, minutes: Long): Long {
        val end=TimerRules.deadline(System.currentTimeMillis(),minutes)
        check(prefs(context).edit().putString("recipe",recipeId).putString("title",title).putLong("deadline",end).putLong("notifiedDeadline",0).commit()) { "Timer could not be saved." }
        schedule(context,end)
        return end
    }
    @Synchronized fun reset(context: Context) {
        context.getSystemService(AlarmManager::class.java).cancel(pending(context))
        check(prefs(context).edit().clear().commit()) { "Timer could not be cleared." }
        context.getSystemService(NotificationManager::class.java).cancel(42)
    }
    /** Re-arm a future deadline after reboot/permission changes; notify an expired deadline once. */
    @Synchronized fun restore(context: Context) {
        val prefs=prefs(context); val end=prefs.getLong("deadline",0)
        when(TimerRules.action(end,prefs.getLong("notifiedDeadline",0),System.currentTimeMillis())) {
            TimerRules.Action.SCHEDULE -> schedule(context,end)
            TimerRules.Action.NOTIFY -> notifyFinished(context)
            TimerRules.Action.NONE -> Unit
        }
    }
    @Synchronized fun notifyFinished(context: Context) {
        val prefs=prefs(context); val end=prefs.getLong("deadline",0)
        if(TimerRules.action(end,prefs.getLong("notifiedDeadline",0),System.currentTimeMillis())!=TimerRules.Action.NOTIFY) return
        if(Build.VERSION.SDK_INT>=33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) return
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,"Cooking timers",NotificationManager.IMPORTANCE_HIGH))
        val launch=context.packageManager.getLaunchIntentForPackage(context.packageName)
        val open=launch?.let { PendingIntent.getActivity(context,42,it,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        manager.notify(42,Notification.Builder(context,CHANNEL).setSmallIcon(android.R.drawable.ic_lock_idle_alarm).setContentTitle("Cooking timer finished").setContentText(prefs.getString("title","Your recipe")).setContentIntent(open).setAutoCancel(true).build())
        prefs.edit().putLong("notifiedDeadline",end).commit()
    }
}

class CookingTimerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if(intent.action==Intent.ACTION_BOOT_COMPLETED || intent.action==AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) CookingTimerStore.restore(context)
        else CookingTimerStore.notifyFinished(context)
    }
}
