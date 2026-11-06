package ro.chimeraerp.companion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

/** Settings are explicit user actions. OEMs may not implement every settings page. */
object CompanionSettings {
    fun open(context: Context, page: String) {
        val primary = when (page) {
            "wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
            "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
            "install" -> Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            "app" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
            else -> throw IllegalArgumentException("Unknown settings page")
        }
        for (intent in listOf(primary, Intent(Settings.ACTION_SETTINGS))) {
            try { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return }
            catch (_: android.content.ActivityNotFoundException) { }
            catch (_: SecurityException) { }
        }
        throw IllegalStateException("Android settings unavailable")
    }
}
