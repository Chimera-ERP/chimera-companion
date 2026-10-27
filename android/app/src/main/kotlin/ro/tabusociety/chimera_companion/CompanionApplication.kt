package ro.tabusociety.chimera_companion

import android.app.Application
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** Retain the API isolate when switching from Companion to the POS browser. */
class CompanionApplication : Application() {
    private val hardwareWorker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    val customerDisplay by lazy { CustomerDisplay(this) }
    val engine: FlutterEngine by lazy {
        FlutterEngine(this).also {
            ConsoleUsb(this, it.dartExecutor.binaryMessenger)
            MethodChannel(it.dartExecutor.binaryMessenger, "chimera/settings")
                .setMethodCallHandler { call, result ->
                    if (call.method == "sdkInt") result.success(android.os.Build.VERSION.SDK_INT)
                    else if (call.method != "open") result.notImplemented()
                    else try {
                        CompanionSettings.open(this, call.argument<String>("page") ?: "")
                        result.success(null)
                    } catch (_: Exception) { result.error("SETTINGS_UNAVAILABLE", "Setările Android nu pot fi deschise.", null) }
                }
            MethodChannel(it.dartExecutor.binaryMessenger, "chimera/customer-display")
                .setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "status" -> result.success(customerDisplay.status())
                            "enable" -> { customerDisplay.enable(call.argument<Boolean>("enabled") == true); result.success(null) }
                            "update" -> result.success(customerDisplay.update(call.arguments as Map<*, *>))
                            "bundle" -> { customerDisplay.useBundle(call.argument<String>("directory")); result.success(null) }
                            "permission" -> {
                                CompanionSettings.open(this, "overlay"); result.success(null)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (_: Exception) { result.error("DISPLAY_UNAVAILABLE", "Ecranul clientului nu este disponibil.", null) }
                }
            MethodChannel(it.dartExecutor.binaryMessenger, "chimera/identity")
                .setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "publicKey" -> result.success(CompanionIdentity.publicKey())
                            "sign" -> result.success(CompanionIdentity.sign(call.argument<String>("message") ?: ""))
                            else -> result.notImplemented()
                        }
                    } catch (_: Exception) { result.error("IDENTITY_UNAVAILABLE", "Identitatea dispozitivului nu este disponibilă", null) }
                }
            MethodChannel(it.dartExecutor.binaryMessenger, "chimera/lifecycle")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "start" -> {
                            try {
                                CompanionBootReceiver.startByUser(this)
                                result.success(true)
                            } catch (_: Exception) { result.error("SERVICE_UNAVAILABLE", "Serviciul de fundal nu a pornit", null) }
                        }
                        "stop" -> {
                            try { CompanionBootReceiver.stopByUser(this); result.success(true) }
                            catch (_: Exception) { result.error("SERVICE_UNAVAILABLE", "Serviciul de fundal nu a fost oprit", null) }
                        }
                        else -> result.notImplemented()
                    }
                }
            MethodChannel(it.dartExecutor.binaryMessenger, "chimera/hardware/datecs_rou")
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
                                mainHandler.post { result.success(response) }
                            } catch (_: Exception) {
                                // Never expose operator passwords or SDK wire payloads in errors.
                                mainHandler.post { result.error("DEVICE_UNAVAILABLE", "Datecs communication failed", null) }
                            }
                        }
                    }
                }
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
}
