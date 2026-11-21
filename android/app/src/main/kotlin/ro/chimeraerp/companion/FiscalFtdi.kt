package ro.chimeraerp.companion

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import java.io.IOException

/** Single-channel FTDI UARTs used by fiscal registers with the FTDI VCP driver. */
internal object FiscalFtdi {
    private const val FTDI_VENDOR = 0x0403
    private const val FT232 = 0x6001
    private const val FTX = 0x6015
    private const val MAX_TRANSFER = 16 * 1024

    fun supports(device: UsbDevice): Boolean =
        device.vendorId == FTDI_VENDOR && device.productId in setOf(FT232, FTX) &&
            device.interfaceCount == 1 && device.getInterface(0).interfaceClass == UsbConstants.USB_CLASS_VENDOR_SPEC

    // The FT232B/R and FT-X clock is divided by N plus one of eight fractions.
    internal fun baudDivisor(baud: Int): Int {
        require(baud in 1200..230400) { "Viteză FTDI incompatibilă." }
        val eighths = (24_000_000 + baud / 2) / baud
        val encodedFraction = intArrayOf(0, 3, 2, 4, 1, 5, 6, 7)[eighths % 8]
        return (eighths / 8) or (encodedFraction shl 14)
    }

    // Each USB IN packet starts with two modem/line status bytes, including
    // zero-payload notifications. Stripping just the first header corrupts frames.
    internal fun serialPayload(buffer: ByteArray, count: Int, packetSize: Int): ByteArray {
        require(packetSize > 2 && count in 0..buffer.size)
        var source = 0
        var used = 0
        while (source < count) {
            val end = minOf(source + packetSize, count)
            if (end - source < 2) throw IOException("Antet FTDI incomplet.")
            if (buffer[source + 1].toInt() and 0x1e != 0) {
                throw IOException("FTDI a raportat o eroare pe linia serială.")
            }
            buffer.copyInto(buffer, used, source + 2, end)
            used += end - source - 2
            source = end
        }
        return buffer.copyOf(used)
    }

    fun open(usb: UsbManager, device: UsbDevice, baudRate: Int): FiscalStream {
        require(supports(device))
        val divisor = baudDivisor(baudRate)
        val port = device.getInterface(0)
        val endpoints = (0 until port.endpointCount).map(port::getEndpoint)
        fun bulk(direction: Int): UsbEndpoint = endpoints.singleOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == direction
        } ?: throw IOException("Portul FTDI nu are interfața serială necesară.")

        val input = bulk(UsbConstants.USB_DIR_IN)
        val output = bulk(UsbConstants.USB_DIR_OUT)
        require(input.maxPacketSize in 3..MAX_TRANSFER)
        val link = usb.openDevice(device) ?: throw IOException("Android nu poate deschide portul FTDI.")
        var claimed = false
        try {
            val descriptors = link.rawDescriptors
            if (descriptors == null || descriptors.size < 14 || (descriptors[13].toInt() and 0xff) < 4) {
                throw IOException("Versiunea adaptorului FTDI nu este acceptată.")
            }
            claimed = link.claimInterface(port, true)
            if (!claimed) throw IOException("Portul FTDI este ocupat.")
            fun set(request: Int, value: Int, index: Int = port.id + 1) {
                if (link.controlTransfer(UsbConstants.USB_TYPE_VENDOR, request, value, index, null, 0, 1500) != 0) {
                    throw IOException("Configurarea FTDI a eșuat.")
                }
            }
            set(0, 0) // Reset the UART bridge.
            set(2, 0) // No hardware or software flow control.
            set(3, divisor and 0xffff, divisor ushr 16)
            set(4, 8) // 8 data bits, no parity, one stop bit.
            set(1, 0x0303) // Assert DTR and RTS.
            return object : FiscalStream {
                override fun write(bytes: ByteArray, timeoutMs: Int) {
                    require(timeoutMs > 0)
                    var offset = 0
                    val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
                    while (offset < bytes.size) {
                        val size = minOf(MAX_TRANSFER, bytes.size - offset)
                        val remaining = (deadline - android.os.SystemClock.elapsedRealtime()).toInt()
                        if (remaining <= 0 || link.bulkTransfer(output, bytes, offset, size, remaining) != size) {
                            throw IOException("Scrierea FTDI nu a fost confirmată integral.")
                        }
                        offset += size
                    }
                }

                override fun read(timeoutMs: Int): ByteArray {
                    require(timeoutMs > 0)
                    val size = input.maxPacketSize
                    val bytes = ByteArray(minOf(16, MAX_TRANSFER / size) * size)
                    val length = link.bulkTransfer(input, bytes, bytes.size, timeoutMs)
                    return if (length <= 0) byteArrayOf() else serialPayload(bytes, length, size)
                }

                override fun close() {
                    try { link.releaseInterface(port) } finally { link.close() }
                }
            }
        } catch (error: Exception) {
            try { if (claimed) link.releaseInterface(port) } finally { link.close() }
            throw error
        }
    }
}
