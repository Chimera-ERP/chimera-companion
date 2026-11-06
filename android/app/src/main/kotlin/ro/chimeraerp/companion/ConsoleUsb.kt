package ro.chimeraerp.companion

import android.app.PendingIntent
import android.content.*
import android.hardware.usb.*
import android.os.*
import io.flutter.plugin.common.*
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Owns only the vendor HID interface. Never claims the boot-keyboard interface. */
class ConsoleUsb(private val context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    @Volatile private var connection: UsbDeviceConnection? = null
    private var claimed: UsbInterface? = null
    private var output: UsbEndpoint? = null
    private var pending: Pair<UsbDevice, MethodChannel.Result>? = null
    private val permission = context.packageName + ".CONSOLE_USB"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                if (device.deviceId == activeId) { close(); sink?.error("USB_REMOVED", "Consola USB a fost deconectată.", null) }
                return
            }
            val waiting = pending ?: return
            if (intent.action != permission || waiting.first.deviceId != device.deviceId) return
            pending = null
            if (!usb.hasPermission(device)) waiting.second.error("USB_PERMISSION", "Permite accesul USB la consolă.", null)
            else connect(device, waiting.second)
        }
    }
    private var activeId: Int? = null
    init {
        val filter = IntentFilter(permission).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(receiver, filter)
        EventChannel(messenger, "chimera/console/reports").setStreamHandler(this)
        MethodChannel(messenger, "chimera/console").setMethodCallHandler { call, result ->
            when(call.method) {
                "devices" -> result.success(usb.deviceList.values.filter(::supported).map { mapOf("id" to it.deviceName, "name" to "Ulanzi USB", "vendorId" to it.vendorId, "productId" to it.productId) })
                "open" -> {
                    val device = usb.deviceList.values.firstOrNull { supported(it) && it.deviceName == call.argument<String>("id") }
                    if (device == null) result.error("USB_MISSING", "Conectează consola prin USB OTG.", null)
                    else if (pending != null) result.error("USB_BUSY", "Confirmă permisiunea USB în Android.", null)
                    else if (usb.hasPermission(device)) connect(device, result)
                    else {
                        pending = device to result
                        usb.requestPermission(device, PendingIntent.getBroadcast(context, 0, Intent(permission).setPackage(context.packageName), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
                        main.postDelayed({ if(pending?.second === result) { pending = null; result.error("USB_TIMEOUT", "Permisiunea USB nu a fost confirmată.", null) } }, 30000)
                    }
                }
                "write" -> {
                    val packets = call.arguments as? List<*>
                    val conn = connection; val ep = output
                    if (packets == null || packets.size > 1033 || packets.any { it !is ByteArray || it.size != 1024 } || conn == null || ep == null)
                        result.error("USB_WRITE", "Consola nu este conectată sau datele sunt invalide.", null)
                    else writer.execute {
                        try {
                            for (packet in packets) {
                                check(connection === conn)
                                val request=UsbRequest()
                                try {
                                    check(request.initialize(conn, ep))
                                    if(Build.VERSION.SDK_INT >= 26) {
                                        check(request.queue(ByteBuffer.wrap(packet as ByteArray)))
                                        check(conn.requestWait(3000) === request)
                                    } else error("Android 8 required for bounded USB I/O")
                                } finally { request.close() }
                            }
                            main.post { result.success(null) }
                        } catch (_: Exception) { main.post { result.error("USB_WRITE", "Scrierea pe consola USB a eșuat.", null) } }
                    }
                }
                "close" -> { close(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun supported(d: UsbDevice) = d.vendorId == 0x2207 && d.productId == 0x19
    private fun connect(device: UsbDevice, result: MethodChannel.Result) {
        close()
        if(Build.VERSION.SDK_INT < 26) {result.error("USB_ANDROID", "Consola USB necesită Android 8 sau mai nou.", null);return}
        try {
            val intf = (0 until device.interfaceCount).map(device::getInterface).first { i ->
                i.interfaceClass == UsbConstants.USB_CLASS_HID && i.interfaceSubclass != 1 &&
                    (0 until i.endpointCount).map(i::getEndpoint).any { it.address == 1 && it.maxPacketSize == 1024 }
            }
            val input = (0 until intf.endpointCount).map(intf::getEndpoint).first { it.address == 0x82 }
            val out = (0 until intf.endpointCount).map(intf::getEndpoint).first { it.address == 1 }
            val conn = usb.openDevice(device) ?: error("open")
            if (!conn.claimInterface(intf, true)) { conn.close(); error("claim") }
            connection = conn; claimed = intf; output = out; activeId = device.deviceId
            // Separate bulkTransfer reads avoid consuming completion events from output UsbRequests.
            Thread({
                val buffer = ByteArray(1024)
                while (connection === conn) {
                    val n = conn.bulkTransfer(input, buffer, buffer.size, 1000)
                    if (n > 0) { val data=buffer.copyOf(n); main.post { if(connection === conn) sink?.success(data) } }
                }
            }, "chimera-console-read").start()
            result.success(null)
        } catch (_: Exception) { close(); result.error("USB_OPEN", "Interfața Ulanzi nu este disponibilă. Închide alte aplicații care folosesc consola.", null) }
    }
    private fun close() {
        val old=connection; connection=null; output=null; activeId=null
        claimed?.let { old?.releaseInterface(it) }; claimed=null; old?.close()
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink=events }
    override fun onCancel(arguments: Any?) { sink=null }
}
