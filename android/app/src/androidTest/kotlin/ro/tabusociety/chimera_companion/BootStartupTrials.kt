package ro.tabusociety.chimera_companion

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock

/** Disposable emulator only. No enrollment, network provisioning or hardware calls. */
object BootStartupTrials {
    fun run(runner: Instrumentation, serviceOnly: Boolean) {
        val context = runner.targetContext
        val prefs = context.getSharedPreferences("companion_lifecycle", Context.MODE_PRIVATE)
        val hadSetting = prefs.contains("resume_on_boot")
        val previous = prefs.getBoolean("resume_on_boot", false)
        var result = Activity.RESULT_OK
        var message = "Receiver filtering, durable opt-in and explicit stop passed."
        try {
            if (serviceOnly) {
                headless(runner)
                message = "Service foregrounded and initialized the shared Dart engine and cached display without an Activity."
            } else {
                val probe = ServiceProbe(context)
                val receiver = CompanionBootReceiver()
                prefs.edit().remove("resume_on_boot").commit()
                receiver.onReceive(probe, Intent(Intent.ACTION_BOOT_COMPLETED).putExtra("operation", "payment"))
                receiver.onReceive(probe, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
                check(probe.starts == 0)
                CompanionBootReceiver.startByUser(probe)
                check(CompanionBootReceiver.resumeOnBoot(context) && probe.starts == 1)
                listOf(null, "untrusted.action", Intent.ACTION_LOCKED_BOOT_COMPLETED, Intent.ACTION_PACKAGE_REPLACED).forEach {
                    receiver.onReceive(probe, Intent().setAction(it))
                }
                check(probe.starts == 1) { "Untrusted action started the service" }
                receiver.onReceive(probe, Intent(Intent.ACTION_BOOT_COMPLETED))
                receiver.onReceive(probe, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
                check(probe.starts == 3)
                CompanionBootReceiver.stopByUser(probe)
                check(!CompanionBootReceiver.resumeOnBoot(context) && probe.stops == 1)
                receiver.onReceive(probe, Intent(Intent.ACTION_BOOT_COMPLETED))
                receiver.onReceive(probe, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
                check(probe.starts == 3) { "Explicit stop did not disable boot resume" }
            }
        } catch (error: Throwable) {
            result = Activity.RESULT_CANCELED
            message = "FAILED: ${error.message}"
        } finally {
            if (serviceOnly) runner.runOnMainSync { CompanionBootReceiver.stopByUser(context) }
            val edit = prefs.edit()
            if (hadSetting) edit.putBoolean("resume_on_boot", previous) else edit.remove("resume_on_boot")
            edit.commit()
        }
        runner.finish(result, Bundle().apply { putString("stream", "$message\n") })
    }

    private fun headless(runner: Instrumentation) {
        val app = runner.targetContext.applicationContext as CompanionApplication
        // A fresh instrumentation process must not already have created the engine.
        val cached = CompanionApplication::class.java.getDeclaredField("engine\$delegate").apply { isAccessible = true }.get(app) as Lazy<*>
        check(!cached.isInitialized()) { "Run headless mode in a fresh process without launching Companion" }
        var activityCreated = false
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) { activityCreated = true }
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        runner.runOnMainSync { app.registerActivityLifecycleCallbacks(callbacks); CompanionBootReceiver.startByUser(app) }
        try {
            val manager = app.getSystemService(ActivityManager::class.java)
            val deadline = SystemClock.elapsedRealtime() + 10000
            var foreground = false
            while (SystemClock.elapsedRealtime() < deadline) {
                @Suppress("DEPRECATION")
                val service = manager.getRunningServices(100).firstOrNull { it.service.className == CompanionService::class.java.name }
                foreground = service?.foreground == true
                if (foreground) break
                SystemClock.sleep(100)
            }
            check(foreground) { "Service did not enter foreground" }
            runner.runOnMainSync {
                check(cached.isInitialized()) { "Service did not initialize cached engine" }
                check(app.engine.dartExecutor.isExecutingDart)
                val display = CompanionApplication::class.java.getDeclaredField("customerDisplay\$delegate").apply { isAccessible = true }.get(app) as Lazy<*>
                check(display.isInitialized()) { "Cached display was not initialized" }
                check(!activityCreated) { "Headless startup launched an Activity" }
            }
        } finally { runner.runOnMainSync { app.unregisterActivityLifecycleCallbacks(callbacks) } }
    }

    private class ServiceProbe(context: Context) : ContextWrapper(context) {
        var starts = 0
        var stops = 0
        override fun startService(service: Intent): ComponentName = record(service)
        override fun startForegroundService(service: Intent): ComponentName = record(service)
        override fun stopService(service: Intent): Boolean { checkTarget(service); stops++; return true }
        private fun record(service: Intent): ComponentName { checkTarget(service); starts++; return service.component!! }
        private fun checkTarget(service: Intent) {
            check(service.component?.className == CompanionService::class.java.name)
            check(service.action == null && service.extras == null) { "Startup must not forward broadcast payloads" }
        }
    }
}
