package ro.tabusociety.chimera_companion

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.content.pm.ServiceInfo
import android.util.Log

class CompanionService : Service() {
    override fun onDestroy() {
        (application as CompanionApplication).customerDisplay.clear()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = "companion_connection"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(channel, "Conexiune POS", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("Chimera Companion activ")
            .setContentText("Conexiune locală pentru POS și dispozitive")
            .setContentIntent(open).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(8765, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(8765, notification)
        } catch (_: RuntimeException) {
            Log.e("ChimeraCompanion", "Foreground service promotion unavailable")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val app = application as CompanionApplication
        Log.i("ChimeraCompanion", "Foreground service started")
        try { app.engine } catch (_: Exception) {
            Log.e("ChimeraCompanion", "Shared runtime initialization unavailable")
        }
        try { app.customerDisplay.status() } catch (_: Exception) {
            Log.e("ChimeraCompanion", "Cached customer display initialization unavailable")
        }
        return if (CompanionBootReceiver.resumeOnBoot(this)) START_STICKY else START_NOT_STICKY
    }
}
