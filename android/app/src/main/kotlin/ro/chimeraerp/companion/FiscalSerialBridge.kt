package ro.chimeraerp.companion

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.*
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/** Application-owned transport. Only foreground selection may prompt a user. */
@SuppressLint("MissingPermission")
internal class FiscalSerialBridge(private val context: Context, messenger: BinaryMessenger) {
    private val usb = context.getSystemService(UsbManager::class.java)
    private val bindings = context.getSharedPreferences("fiscal_usb_identity", Context.MODE_PRIVATE)
    private val worker = Handler(HandlerThread("fiscal-serial").apply { start() }.looper)
    private val permissionAction = context.packageName + ".FISCAL_SERIAL_GRANT"
    private val selectedAttachments = mutableMapOf<String, Int>()
    private var counter = 0
    private var port: Port? = null
    private var permission: Grant? = null
    private val idle = Runnable { closePort() }
    private data class Port(val handle: Int, val stream: FiscalStream, val usbDevice: UsbDevice?)
    private data class Grant(val deviceId: Int, val path: String, val nonce: String,
                             val callback: PendingIntent, val reply: MethodChannel.Result)

    private val receiver = object : BroadcastReceiver() {
        @Suppress("DEPRECATION")
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                val dev = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
                selectedAttachments.entries.removeAll { it.value == dev.deviceId }
                if (port?.usbDevice?.deviceId == dev.deviceId) closePort()
                if (permission?.deviceId == dev.deviceId)
                    finishGrant(false)
            } else if (intent.action == permissionAction && permission?.nonce == intent.getStringExtra("nonce")) {
                finishGrant(true)
            }
        }
    }

    init {
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33)
            context.registerReceiver(receiver, filter, null, worker, Context.RECEIVER_NOT_EXPORTED)
        else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter, null, worker)
        }
        MethodChannel(messenger, "chimera/fiscal-serial").setMethodCallHandler { call, reply ->
            worker.post {
                try {
                    if (call.method == "select" && call.argument<String>("transport") == "usb") {
                        selectUsb(call.argument<String>("id").orEmpty(), reply)
                    } else {
                        reply.success(execute(call))
                    }
                } catch (e: Exception) { fail(reply, e) }
            }
        }
    }

    private fun execute(call: MethodCall): Any? {
        val id = call.argument<String>("id").orEmpty()
        val transport = call.argument<String>("transport")
        return when (call.method) {
            "devices" -> when (transport) {
                "usb" -> attached().sortedBy { it.deviceName }.map {
                    mapOf("id" to it.deviceName, "label" to "${it.productName ?: "USB serial"} (%04X:%04X)".format(it.vendorId, it.productId))
                }
                "bluetooth" -> FiscalBluetooth.bonded(context).sortedBy { it.name ?: it.address }.map {
                    mapOf("id" to it.address, "label" to (it.name ?: "Bluetooth"))
                }
                else -> throw IllegalArgumentException("Transport necunoscut.")
            }
            "select" -> {
                require(transport == "bluetooth")
                FiscalBluetooth.bonded(context).singleOrNull { it.address == id }?.address
                    ?: throw IOException("Dispozitivul Bluetooth nu este asociat.")
            }
            "open" -> {
                openConfigured(transport, id, baud(call))
            }
            "openCandidate" -> {
                require(port == null) { "Portul fiscal este ocupat." }
                val device = attached().singleOrNull { it.deviceName == id }
                if (device == null || !usb.hasPermission(device))
                    throw IOException("Acordă accesul la casa USB selectată în configurare.")
                openUsb(device, baud(call))
            }
            "bindCandidate" -> {
                val device = active(call).usbDevice ?: throw IllegalArgumentException("Sesiune USB necesară.")
                require(validHash(id))
                storeBinding(device, id)
                null
            }
            "legacyBind" -> {
                require(port == null) { "Portul fiscal este ocupat." }
                val dev = attached().singleOrNull { it.deviceName == id && usb.hasPermission(it) }
                    ?: throw IOException("Acordă accesul la casa USB în configurare.")
                openUsb(dev, baud(call))
                try {
                    val result = DatecsRouBridge.executeSerial("identity", emptyMap<Any, Any>(), port!!.stream)
                    val key = result["identity"] as? String ?: throw IOException("Seria casei Datecs nu a putut fi citită.")
                    storeBinding(dev, key)
                    key
                } finally { closePort() }
            }
            "legacyOperation" -> {
                val operation = call.argument<String>("operation")
                require(operation in setOf("status", "readVatRates", "receipt", "xReport", "zReport"))
                // The worker owns this lease through all issue/confirmation commands.
                try { openConfigured(transport, id, baud(call)) }
                catch (e: Exception) {
                    return mapOf("outcome" to "rejected", "message" to "Conectarea la casa Datecs a eșuat.",
                        "description" to "Conectarea la casa Datecs a eșuat.")
                }
                try { DatecsRouBridge.executeSerial(operation!!, call.arguments as Map<*, *>, port!!.stream) }
                finally { closePort() }
            }
            "read", "write" -> {
                val active = active(call)
                val timeout = call.argument<Number>("timeoutMs")?.toInt() ?: 0
                require(timeout in 1..60000)
                try {
                    if (call.method == "read") active.stream.read(timeout)
                    else {
                        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException()
                        require(bytes.size in 1..16384)
                        active.stream.write(bytes, timeout)
                        null
                    }
                } catch (e: Exception) { closePort(); throw e }
            }
            "close" -> {
                if (port?.handle == call.argument<Number>("session")?.toInt()) closePort()
                null
            }
            else -> throw IllegalArgumentException("Operație necunoscută.")
        }
    }

    private fun openConfigured(transport: String?, id: String, baudRate: Int): Int {
        require(port == null) { "Portul fiscal este ocupat." }
        return when (transport) {
            "usb" -> {
                require(validHash(id))
                val hint = bindings.getString(id, null) ?: throw IOException("Selectează casa USB în configurare.")
                // VID/PID and USB serial narrow the search only. On this same
                // handle Dart must verify the fiscal register serial before any checkout command.
                val matches = attached().filter { usb.hasPermission(it) && usbHint(it) == hint }
                val device = matches.singleOrNull() ?: matches.singleOrNull { it.deviceId == selectedAttachments[id] }
                    ?: throw IOException("Reconectează casa și selecteaz-o în configurare pentru a confirma accesul USB.")
                openUsb(device, baudRate)
            }
            "bluetooth" -> lease(FiscalBluetooth.open(context, id), null)
            else -> throw IllegalArgumentException("Transport necunoscut.")
        }
    }

    private fun fail(reply: MethodChannel.Result, e: Exception) {
        if (e is SecurityException) reply.error("FISCAL_PERMISSION", "Acordă permisiunea pentru dispozitiv în configurare.", null)
        else reply.error("FISCAL_TRANSPORT", e.localizedMessage ?: "Conexiunea la casa de marcat a eșuat.", null)
    }

    private fun attached() = usb.deviceList.values.filter(FiscalUsbStreams::supports)
    private fun usbFamily(device: UsbDevice) = "%04X:%04X".format(device.vendorId, device.productId)
    private fun validHash(value: String) = Regex("^[0-9a-f]{64}$").matches(value)

    private fun usbHint(device: UsbDevice): String {
        val serial = device.serialNumber?.trim().orEmpty()
        return MessageDigest.getInstance("SHA-256").digest("usb/${usbFamily(device)}/$serial".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun storeBinding(device: UsbDevice, key: String) {
        check(bindings.edit().putString(key, usbHint(device)).commit())
        selectedAttachments[key] = device.deviceId
    }

    private fun selectUsb(path: String, reply: MethodChannel.Result) {
        check(permission == null) { "O cerere de acces USB este deja deschisă." }
        val device = attached().singleOrNull { it.deviceName == path } ?: throw IOException("Casa USB a fost deconectată.")
        if (usb.hasPermission(device)) { reply.success(""); return }
        val nonce = UUID.randomUUID().toString()
        val intent = Intent(permissionAction).setPackage(context.packageName).putExtra("nonce", nonce)
        val callback = PendingIntent.getBroadcast(context, ++counter, intent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE)
        val grant = Grant(device.deviceId, path, nonce, callback, reply)
        permission = grant
        try { usb.requestPermission(device, callback) } catch (e: Exception) {
            permission = null; callback.cancel(); throw e
        }
        worker.postDelayed({ if (permission === grant) finishGrant(false) }, 30000)
    }

    private fun finishGrant(withReply: Boolean) {
        val grant = permission ?: return
        permission = null
        grant.callback.cancel()
        try {
            val device = usb.deviceList[grant.path]
            if (!withReply || device?.deviceId != grant.deviceId || !usb.hasPermission(device))
                throw IOException("Accesul USB nu a fost acordat sau casa a fost deconectată.")
            grant.reply.success("")
        } catch (e: Exception) { fail(grant.reply, e) }
    }

    private fun baud(call: MethodCall): Int {
        val speed = call.argument<Number>("baudRate")?.toInt() ?: 115200
        require(speed in setOf(9600, 19200, 38400, 57600, 115200))
        return speed
    }
    private fun openUsb(device: UsbDevice, baudRate: Int) = lease(FiscalUsbStreams.open(usb, device, baudRate), device)
    private fun lease(stream: FiscalStream, device: UsbDevice?): Int {
        val handle = ++counter
        port = Port(handle, stream, device)
        renew()
        return handle
    }
    private fun renew() { worker.removeCallbacks(idle); worker.postDelayed(idle, 90000) }
    private fun active(call: MethodCall): Port {
        val active = port ?: throw IOException("Sesiunea fiscală s-a închis.")
        require(active.handle == call.argument<Number>("session")?.toInt()) { "Sesiunea fiscală a expirat." }
        renew()
        return active
    }
    private fun closePort() {
        worker.removeCallbacks(idle)
        val current = port ?: return
        port = null
        runCatching { current.stream.close() }
    }
}
