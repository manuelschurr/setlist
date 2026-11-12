package de.schurr.setlist

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator

object RestAlarm {
    private const val COUNTDOWN_CHANNEL = "rest"
    private const val OVER_CHANNEL = "rest_over"
    private const val COUNTDOWN_ID = 1
    private const val OVER_ID = 2
    internal const val EXTRA_TITLE = "title"

    fun show(context: Context, title: String, endsAtMs: Long) {
        val notifications = notifications(context)
        notifications.cancel(OVER_ID)
        notifications.notify(COUNTDOWN_ID, Notification.Builder(context, COUNTDOWN_CHANNEL)
            .setSmallIcon(R.drawable.ic_rest)
            .setContentTitle(title)
            .setContentText("Rest")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(endsAtMs)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .setContentIntent(openApp(context))
            .build())

        val alarms = context.getSystemService(AlarmManager::class.java)
        val fire = alarmIntent(context, title)
        // Android 12 lets the user revoke exact alarms in Settings; the inexact alarm still fires, only later.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endsAtMs, fire)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endsAtMs, fire)
        }
    }

    fun cancel(context: Context) {
        context.getSystemService(AlarmManager::class.java).cancel(alarmIntent(context, null))
        notifications(context).run {
            cancel(COUNTDOWN_ID)
            cancel(OVER_ID)
        }
    }

    internal fun over(context: Context, title: String?) {
        val notifications = notifications(context)
        notifications.cancel(COUNTDOWN_ID)
        // Background apps may only vibrate with alarm-like usage; a plain vibrate() is dropped once the app is not in front.
        context.getSystemService(Vibrator::class.java).vibrate(
            VibrationEffect.createWaveform(longArrayOf(0, 400, 200, 400, 200, 400), -1),
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
        )
        notifications.notify(OVER_ID, Notification.Builder(context, OVER_CHANNEL)
            .setSmallIcon(R.drawable.ic_rest)
            .setContentTitle("Rest over")
            .setContentText(title)
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .setContentIntent(openApp(context))
            .build())
    }

    private fun notifications(context: Context): NotificationManager {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(COUNTDOWN_CHANNEL, "Rest countdown", NotificationManager.IMPORTANCE_LOW))
        // The receiver vibrates itself with a fixed pattern, so the channel stays silent to avoid a second buzz and a sound.
        manager.createNotificationChannel(NotificationChannel(OVER_CHANNEL, "Rest over", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(null, null)
            enableVibration(false)
        })
        return manager
    }

    private fun openApp(context: Context): PendingIntent =
        PendingIntent.getActivity(context, 0, context.packageManager.getLaunchIntentForPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE)

    private fun alarmIntent(context: Context, title: String?): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, RestOverReceiver::class.java).putExtra(EXTRA_TITLE, title),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}

class RestOverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = RestAlarm.over(context, intent.getStringExtra(RestAlarm.EXTRA_TITLE))
}
