package ro.chimeraerp.companion

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Attachment-scoped CDC ACM port for local FP21 diagnostics. */
internal class Fp21Usb(private val context: Context, messenger: BinaryMessenger) {
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val worker = Handler(HandlerThread("fp21-usb").apply { start() }.looper)
    private val permissionAction = context.packageName + ".FP21_USB_PERMISSION"
    private var nextHandle = 0
    private var port: Port? = null
    private var waiting: PermissionRequest? = null
    private val idleClose = Runnable { closePort() }

    private data class Port(val handle: Int, val device: UsbDevice, val stream: FiscalStream,
                            val commands: Fp21UsbCommands, var qrBytesLogged: Int = 0)
    private data class PermissionRequest(val device: UsbDevice, val token: String, val reply: MethodChannel.Result,
                                         val callback: PendingIntent, val purpose: Fp21UsbPurpose)
    private class Failure(val code: String, message: String) : Exception(message)

    @Suppress("DEPRECATION")
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
                if (port?.device?.deviceName == device.deviceName) closePort()
                val request = waiting ?: return
                if (request.device.deviceName == device.deviceName) {
                    finishWaiting()
                    request.reply.error("USB_MISSING", "Imprimanta a fost deconectată.", null)
                }
            } else if (intent.action == permissionAction) {
                val request = waiting ?: return
                if (request.token != intent.getStringExtra("request")) return
                finishWaiting()
                respond(request.reply) {
                    val device = attached(request.device.deviceName)
                    if (!usb.hasPermission(device)) throw Failure("USB_PERMISSION", "Accesul USB nu a fost acordat.")
                    connect(device, request.purpose)
                }
            }
        }
    }

    init {
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, null, worker, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter, null, worker)
        }
        MethodChannel(messenger, "chimera/fp21-usb").setMethodCallHandler { call, reply ->
            worker.post {
                when (call.method) {
                    "devices" -> respond(reply) {
                        usb.deviceList.values.filter { it.interfaceCount == 2 && FiscalCdc.supports(it) }.sortedBy { it.deviceName }.map {
                            val usbId = "%04X:%04X".format(it.vendorId, it.productId)
                            val product = it.productName?.trim()?.takeIf(String::isNotEmpty) ?: "USB serial"
                            mapOf("id" to it.deviceName, "label" to "$product ($usbId, ${it.deviceName.substringAfterLast('/')})")
                        }
                    }
                    "open" -> try {
                        val purpose = when (call.argument<Any>("purpose")) {
                            null, "status" -> Fp21UsbPurpose.STATUS
                            "nonFiscalTest" -> Fp21UsbPurpose.NON_FISCAL_TEST
                            "finishNonFiscalTest" -> Fp21UsbPurpose.FINISH_TEST
                            "closeNonFiscalTest" -> Fp21UsbPurpose.CLOSE_TEST
                            "cutPaper" -> Fp21UsbPurpose.CUT_PAPER
                            "qrTest" -> Fp21UsbPurpose.QR_TEST
                            else -> throw Failure("USB_PURPOSE", "Testul USB selectat nu este disponibil.")
                        }
                        open(call.argument<String>("id").orEmpty(), purpose, reply)
                    }
                              catch (e: Exception) { error(reply, e) }
                    "write", "read", "close" -> respond(reply) { transfer(call) }
                    else -> reply.notImplemented()
                }
            }
        }
    }

    private fun attached(id: String): UsbDevice =
        usb.deviceList[id]?.takeIf { it.interfaceCount == 2 && FiscalCdc.supports(it) }
            ?: throw Failure("USB_MISSING", "Portul USB selectat nu mai este conectat.")

    private fun open(id: String, purpose: Fp21UsbPurpose, reply: MethodChannel.Result) {
        if (waiting != null || port != null) throw Failure("USB_BUSY", "Un test USB este deja în curs.")
        val device = attached(id)
        if (usb.hasPermission(device)) { reply.success(connect(device, purpose)); return }

        val token = UUID.randomUUID().toString()
        val intent = Intent(permissionAction).setPackage(context.packageName).putExtra("request", token)
        // The immutable callback contains our nonce. Query the grant from UsbManager itself.
        val callback = PendingIntent.getBroadcast(context, ++nextHandle, intent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE)
        val request = PermissionRequest(device, token, reply, callback, purpose)
        waiting = request
        try { usb.requestPermission(device, callback) }
        catch (e: Exception) { finishWaiting(); throw e }
        worker.postDelayed({
            if (waiting === request) {
                finishWaiting()
                reply.error("USB_TIMEOUT", "Confirmarea accesului USB a expirat.", null)
            }
        }, 30_000)
    }

    private fun finishWaiting() {
        waiting?.callback?.cancel()
        waiting = null
    }

    private fun connect(device: UsbDevice, purpose: Fp21UsbPurpose): Int {
        val stream = FiscalUsbStreams.open(usb, device, 115200)
        val handle = ++nextHandle
        port = Port(handle, device, stream, Fp21UsbCommands(purpose))
        renewLease()
        return handle
    }

    private fun transfer(call: MethodCall): Any? {
        val handle = call.argument<Number>("session")?.toInt()
        val active = port
        if (call.method == "close") {
            if (active != null && active.handle == handle) closePort()
            return null
        }
        if (active == null || active.handle != handle) throw Failure("USB_CLOSED", "Sesiunea USB s-a închis.")
        try {
            renewLease()
            if (call.method == "write") {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null || !active.commands.accept(bytes)) throw Failure("USB_COMMAND", "Comanda nu este disponibilă în testul USB.")
                try { active.stream.write(bytes, 2000) }
                catch (_: java.io.IOException) { throw Failure("USB_WRITE", "Trimiterea comenzii USB a eșuat.") }
                if (active.commands.standaloneQrAwaitingReply) Log.i("Fp21Qr", "TX 51h/C bulk write: ${bytes.size} bytes")
                return null
            }
            val timeout = if (active.commands.qrAwaitingReply) 8000 else 3000
            val bytes = try { active.stream.read(timeout) } catch (_: java.io.IOException) {
                throw Failure("USB_READ", "Imprimanta nu a răspuns prin USB.")
            }
            if (active.commands.standaloneQrAwaitingReply && active.qrBytesLogged < 14) {
                val limit = minOf(bytes.size, 14 - active.qrBytesLogged)
                val hex = bytes.take(limit).joinToString(" ") { "%02X".format(it.toInt() and 0xff) }
                active.qrBytesLogged += limit
                Log.i("Fp21Qr", "RX 51h/C ($limit bytes): $hex")
            }
            return bytes.also(active.commands::observe)
        } catch (e: Exception) {
            val recoverableQrRead = e is Failure && e.code == "USB_READ" &&
                active.commands.restrictToCloseAfterQrReadTimeout()
            if (!recoverableQrRead) closePort()
            throw e
        }
    }

    private fun renewLease() {
        worker.removeCallbacks(idleClose)
        worker.postDelayed(idleClose, 30_000)
    }

    private fun closePort() {
        worker.removeCallbacks(idleClose)
        val active = port ?: return
        port = null
        active.stream.close()
    }

    private fun respond(reply: MethodChannel.Result, action: () -> Any?) {
        try { reply.success(action()) } catch (e: Exception) { error(reply, e) }
    }

    private fun error(reply: MethodChannel.Result, cause: Exception) {
        if (cause is Failure) reply.error(cause.code, cause.message, null)
        else reply.error("USB_IO", "Comunicarea cu portul serial USB a eșuat.", null)
    }
}

internal enum class Fp21UsbPurpose { STATUS, NON_FISCAL_TEST, FINISH_TEST, CLOSE_TEST, CUT_PAPER, QR_TEST }

/** A print handle permits one bounded non-fiscal document. A QR read timeout may keep that same
 * handle to confirm and close the open receipt. A failed write is never retried. */
internal class Fp21UsbCommands(private val purpose: Fp21UsbPurpose) {
    private enum class Receipt { INITIAL, OPENING, OPEN, QR_UNCONFIRMED, CLOSED }
    private var receipt = Receipt.INITIAL
    private var cutSent = false
    private enum class Symbols { NONE, EAN_SENT, QR_ALLOWED, QR_SENT }
    private var symbols = Symbols.NONE
    private var documentState: Int? = null
    private var awaiting: Int? = null
    private val response = mutableListOf<Int>()
    private var previousSequence: Int? = null
    val qrAwaitingReply: Boolean get() = awaiting == 0x51 && symbols == Symbols.QR_SENT
    val standaloneQrAwaitingReply: Boolean get() = purpose == Fp21UsbPurpose.QR_TEST && qrAwaitingReply

    fun restrictToCloseAfterQrReadTimeout(): Boolean {
        if (!qrAwaitingReply || receipt != Receipt.OPEN ||
            (purpose != Fp21UsbPurpose.NON_FISCAL_TEST && purpose != Fp21UsbPurpose.FINISH_TEST)) return false
        receipt = Receipt.QR_UNCONFIRMED
        awaiting = null
        response.clear()
        documentState = null
        return true
    }

    fun accept(frame: ByteArray): Boolean {
        if (awaiting != null) return false
        if (frame.size == 1 && frame[0] == 0x09.toByte()) return true
        if (frame.size !in 7..(7 + testQr.length) || frame.first() != 0x02.toByte() || frame.last() != 0x0a.toByte()) return false
        if ((frame[1].toInt() and 0xff) != frame.size - 4 + 0x20) return false
        val sequence = frame[2].toInt() and 0xff
        if (sequence !in 0x20..0x9f) return false
        previousSequence?.let { if (sequence != (if (it == 0x9f) 0x20 else it + 1)) return false }
        var checksum = 0
        for (index in 1 until frame.size - 3) checksum = checksum xor (frame[index].toInt() and 0xff)
        if (frame[frame.size - 3].toInt() != 0x30 + (checksum ushr 4) ||
            frame[frame.size - 2].toInt() != 0x30 + (checksum and 0x0f)) return false
        if ((4 until frame.size - 3).any { frame[it].toInt() !in 0x20..0x7e }) return false
        val command = frame[3].toInt()
        val data = String(frame, 4, frame.size - 7, Charsets.US_ASCII)
        val allowed = when {
            command == 0x20 -> data.isEmpty()
            receipt == Receipt.QR_UNCONFIRMED -> command == 0x2f && data.isEmpty() && documentState == 1
            purpose == Fp21UsbPurpose.STATUS -> command == 0x21 && data.isEmpty() && documentState == 0
            purpose == Fp21UsbPurpose.QR_TEST ->
                command == 0x51 && data == testQr && documentState == 0 && symbols == Symbols.NONE
            purpose == Fp21UsbPurpose.CUT_PAPER ->
                command == 0x29 && data.isEmpty() && !cutSent && (documentState == 0 || documentState == 1)
            purpose == Fp21UsbPurpose.CLOSE_TEST ->
                command == 0x2f && data.isEmpty() && receipt == Receipt.INITIAL && documentState == 1
            else -> allowPrint(command, data)
        }
        if (allowed) {
            if (purpose == Fp21UsbPurpose.QR_TEST && command == 0x51) symbols = Symbols.QR_SENT
            if (command == 0x29) cutSent = true
            if (command == 0x2f) {
                // Consume the one close at dispatch, including when its ACK is lost.
                receipt = Receipt.CLOSED
                documentState = null
            }
            previousSequence = sequence
            if (command in listOf(0x20, 0x29, 0x2e, 0x51, 0x2f)) {
                awaiting = command
                response.clear()
                if (command == 0x20) documentState = null
            }
        }
        return allowed
    }

    // A finish handle can only append to an observed non-fiscal document.
    fun observe(bytes: ByteArray) {
        val command = awaiting ?: return
        // The printer did not execute this 51h packet. Continue with the
        // independent next step, without replaying the symbol on this handle.
        if (command == 0x51 && response.isEmpty() && bytes.size == 1 &&
            (bytes[0] == 0x15.toByte() || bytes[0] == 0x0e.toByte())) {
            if (symbols == Symbols.EAN_SENT) symbols = Symbols.QR_ALLOWED
            awaiting = null
            return
        }
        if (response.size + bytes.size > 14) return
        for (b in bytes) response.add(b.toInt() and 0xff)
        val ack = response.firstOrNull() == 0x06
        val size = if (ack) 7 else 14
        if (response.size != size) return
        if (response.last() != 10) return
        val checksum = response.subList(1, size - 3).fold(0) { sum, b -> sum xor b }
        if (response[size - 3] != 0x30 + (checksum ushr 4) ||
            response[size - 2] != 0x30 + (checksum and 15)) return
        if (response[if (ack) 1 else 2] != previousSequence) return
        if (ack) {
            if (response[2] !in 0x30..0x3f || response[3] !in 0x30..0x3f) return
            val ok = response[2] == 0x30 && response[3] == 0x30
            if (command == 0x2e && ok) receipt = Receipt.OPEN
            if (command == 0x51 && symbols == Symbols.EAN_SENT) {
                // A validated syntax/unsupported refusal permits the independent QR
                // trial. An unconfirmed transfer or a printer fault does not.
                val unsupported = response[2] in listOf(0x30, 0x36, 0x3a) &&
                    response[3] in listOf(0x31, 0x32, 0x34)
                if (ok || unsupported) symbols = Symbols.QR_ALLOWED
            }
        } else {
            if (response[0] != 2 || response[1] != 0x2a || response[3] != 0x20 || command != 0x20) return
            documentState = response[6] and 3
        }
        awaiting = null
    }

    private fun allowPrint(command: Int, data: String): Boolean {
        when (command) {
            0x2e -> {
                if (purpose != Fp21UsbPurpose.NON_FISCAL_TEST || receipt != Receipt.INITIAL ||
                    documentState != 0 || !operatorOpen.matches(data)) return false
                receipt = Receipt.OPENING
            }
            0x37 -> return receipt == Receipt.OPEN && data.length <= 40
            0x51 -> {
                when (data) {
                    testBarcode -> {
                        if (symbols != Symbols.NONE) return false
                        if (purpose == Fp21UsbPurpose.FINISH_TEST && receipt == Receipt.INITIAL && documentState == 1) {
                            receipt = Receipt.OPEN
                        }
                        if (receipt != Receipt.OPEN) return false
                        symbols = Symbols.EAN_SENT
                    }
                    testQr -> {
                        if (receipt != Receipt.OPEN || symbols != Symbols.QR_ALLOWED) return false
                        symbols = Symbols.QR_SENT
                    }
                    else -> return false
                }
            }
            0x2f -> return receipt == Receipt.OPEN && data.isEmpty()
            else -> return false
        }
        return true
    }

    private companion object {
        val testBarcode = "P;2;12;" + "200000000001".padEnd(100)
        val testQr = "C;4;" + "https://chimeraerp.ro".padEnd(200)
        val operatorOpen = Regex("(?:[1-9]|1[0-9]|20);[^;]{4};0;0")
    }
}
