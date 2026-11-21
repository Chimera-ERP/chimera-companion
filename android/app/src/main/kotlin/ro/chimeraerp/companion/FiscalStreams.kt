package ro.chimeraerp.companion

import android.hardware.usb.*
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

internal interface FiscalStream : Closeable {
    fun write(bytes: ByteArray, timeoutMs: Int)
    fun read(timeoutMs: Int): ByteArray
}

/** Diagnostics and checkout share one physical USB lease, including across channels. */
internal object FiscalUsbStreams {
    private val leases = ConcurrentHashMap.newKeySet<String>()
    fun supports(device: UsbDevice) = FiscalCdc.supports(device) || FiscalFtdi.supports(device)

    fun open(usb: UsbManager, device: UsbDevice, baudRate: Int): FiscalStream {
        val path = device.deviceName
        if (!leases.add(path)) throw IOException("Portul USB este deja folosit.")
        try {
            val stream = if (FiscalFtdi.supports(device)) FiscalFtdi.open(usb, device, baudRate)
                         else FiscalCdc.open(usb, device, baudRate)
            return object : FiscalStream by stream {
                private var closed = false
                @Synchronized override fun close() {
                    if (closed) return
                    closed = true
                    try { stream.close() } finally { leases.remove(path) }
                }
            }
        } catch (e: Exception) {
            leases.remove(path)
            throw e
        }
    }
}

internal object FiscalCdc {
    private data class Ports(val control: UsbInterface, val data: UsbInterface,
                             val input: UsbEndpoint, val output: UsbEndpoint)

    fun supports(device: UsbDevice) = ports(device) != null

    private fun ports(device: UsbDevice): Ports? {
        if (device.configurationCount != 1) return null
        val all = (0 until device.interfaceCount).map(device::getInterface)
        val control = all.singleOrNull { it.interfaceClass == UsbConstants.USB_CLASS_COMM &&
            it.interfaceSubclass == 2 && it.alternateSetting == 0 } ?: return null
        val data = all.singleOrNull { it.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA &&
            it.alternateSetting == 0 } ?: return null
        val bulk = (0 until data.endpointCount).map(data::getEndpoint).filter {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.maxPacketSize in 1..1024
        }
        val input = bulk.singleOrNull { it.direction == UsbConstants.USB_DIR_IN } ?: return null
        val output = bulk.singleOrNull { it.direction == UsbConstants.USB_DIR_OUT } ?: return null
        return Ports(control, data, input, output)
    }

    fun open(usb: UsbManager, device: UsbDevice, baudRate: Int): FiscalStream {
        val ports = ports(device) ?: throw IOException("Interfața USB CDC ACM nu este disponibilă.")
        val link = usb.openDevice(device) ?: throw IOException("Portul USB nu poate fi deschis.")
        var controlClaimed = false
        var dataClaimed = false
        try {
            controlClaimed = link.claimInterface(ports.control, true)
            check(controlClaimed)
            dataClaimed = link.claimInterface(ports.data, true)
            check(dataClaimed)
            val coding = byteArrayOf(baudRate.toByte(), (baudRate ushr 8).toByte(),
                (baudRate ushr 16).toByte(), (baudRate ushr 24).toByte(), 0, 0, 8)
            check(link.controlTransfer(0x21, 0x20, 0, ports.control.id, coding, coding.size, 1500) == coding.size)
            check(link.controlTransfer(0x21, 0x22, 3, ports.control.id, null, 0, 1500) == 0)
        } catch (e: Exception) {
            if (dataClaimed) runCatching { link.releaseInterface(ports.data) }
            if (controlClaimed) runCatching { link.releaseInterface(ports.control) }
            link.close()
            throw e
        }
        return object : FiscalStream {
            override fun write(bytes: ByteArray, timeoutMs: Int) {
                if (link.bulkTransfer(ports.output, bytes, bytes.size, timeoutMs) != bytes.size)
                    throw IOException("Trimiterea comenzii USB a eșuat.")
            }
            override fun read(timeoutMs: Int): ByteArray {
                val buffer = ByteArray(ports.input.maxPacketSize)
                val length = link.bulkTransfer(ports.input, buffer, buffer.size, timeoutMs)
                if (length <= 0) throw IOException("Casa nu a răspuns prin USB.")
                return buffer.copyOf(length)
            }
            override fun close() {
                runCatching { link.releaseInterface(ports.data) }
                runCatching { link.releaseInterface(ports.control) }
                link.close()
            }
        }
    }
}
