package ro.chimeraerp.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/** Credential-protected opt-in; never starts an Activity or dispatches commands. */
class CompanionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!resumeOnBoot(context)) return
        try {
            Log.i("ChimeraCompanion", if (intent.action == Intent.ACTION_BOOT_COMPLETED) "Resuming after boot" else "Resuming after package replacement")
            startService(context)
        } catch (_: Exception) {
            // OEM restrictions may refuse startup. Keep the durable user choice.
            Log.w("ChimeraCompanion", "Background startup unavailable")
        }
    }

    companion object {
        private fun preferences(context: Context) = context.getSharedPreferences("companion_lifecycle", Context.MODE_PRIVATE)
        fun resumeOnBoot(context: Context): Boolean = preferences(context).getBoolean("resume_on_boot", false)

        fun startByUser(context: Context) {
            check(preferences(context).edit().putBoolean("resume_on_boot", true).commit())
            startService(context)
        }

        fun stopByUser(context: Context) {
            check(preferences(context).edit().putBoolean("resume_on_boot", false).commit())
            context.stopService(Intent(context, CompanionService::class.java))
        }

        private fun startService(context: Context) {
            val service = Intent(context, CompanionService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service)
            else context.startService(service)
        }
    }
}
