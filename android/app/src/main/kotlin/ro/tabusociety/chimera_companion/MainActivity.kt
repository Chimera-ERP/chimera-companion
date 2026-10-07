package ro.tabusociety.chimera_companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import android.content.Context
import android.content.Intent
import android.os.Build

class MainActivity : FlutterActivity() {
    private val hardwareWorker = Executors.newSingleThreadExecutor()
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
                        "install" -> result.success(updates.install(call.argument<String>("path") ?: "", call.argument<Number>("versionCode")?.toLong() ?: 0))
                        else -> result.notImplemented()
                    }
                } catch (e: IllegalArgumentException) { result.error("INVALID_UPDATE", e.message, null) }
                  catch (_: Exception) { result.error("UPDATE_UNAVAILABLE", "Instalarea nu poate fi pornită pe acest dispozitiv.", null) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chimera/identity")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "publicKey" -> result.success(CompanionIdentity.publicKey())
                        "sign" -> result.success(CompanionIdentity.sign(call.argument<String>("message") ?: ""))
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("IDENTITY_UNAVAILABLE", "Identitatea dispozitivului nu este disponibilă", null) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chimera/lifecycle")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent = Intent(applicationContext, CompanionService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            result.success(true)
                        } catch (_: Exception) { result.error("SERVICE_UNAVAILABLE", "Serviciul de fundal nu a pornit", null) }
                    }
                    "stop" -> { stopService(Intent(applicationContext, CompanionService::class.java)); result.success(true) }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chimera/hardware/datecs_rou")
            .setMethodCallHandler { call, result ->
                if (call.method !in listOf("status", "receipt", "discover", "xReport", "zReport", "networkInfo")) {
                    result.notImplemented()
                } else {
                    hardwareWorker.execute {
                        try {
                            val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                            val response: Any? = when (call.method) {
                                "discover" -> DatecsRouBridge.discover(applicationContext)
                                "networkInfo" -> DatecsRouBridge.lanNetworks(applicationContext)
                                else -> DatecsRouBridge.execute(call.method, arguments)
                            }
                            runOnUiThread { result.success(response) }
                        } catch (_: Exception) {
                            // Never expose operator passwords or SDK wire payloads in errors.
                            runOnUiThread { result.error("DEVICE_UNAVAILABLE", "Datecs communication failed", null) }
                        }
                    }
                }
            }
    }
}
