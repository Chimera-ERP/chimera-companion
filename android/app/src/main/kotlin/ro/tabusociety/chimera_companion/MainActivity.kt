package ro.tabusociety.chimera_companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        (application as CompanionApplication).customerDisplay.foreground(this)
    }
    override fun onPause() {
        (application as CompanionApplication).customerDisplay.foreground(null)
        super.onPause()
    }
    override fun provideFlutterEngine(context: Context): FlutterEngine = (application as CompanionApplication).engine
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val updates = CompanionUpdates(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chimera/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "versionCode" -> result.success(updates.versionCode())
                        "canInstall" -> result.success(updates.canInstall())
                        "install" -> result.success(updates.install(call.argument<String>("path") ?: "", call.argument<Number>("versionCode")?.toLong() ?: 0))
                        else -> result.notImplemented()
                    }
                } catch (e: IllegalArgumentException) { result.error("INVALID_UPDATE", e.message, null) }
                  catch (_: Exception) { result.error("UPDATE_UNAVAILABLE", "Instalarea nu poate fi pornită pe acest dispozitiv.", null) }
            }
    }
}
