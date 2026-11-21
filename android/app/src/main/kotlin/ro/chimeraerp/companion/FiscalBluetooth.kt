package ro.chimeraerp.companion

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Android BluetoothSocket.close interrupts a blocked RFCOMM connect/read/write. */
@SuppressLint("MissingPermission")
internal object FiscalBluetooth {
    private val spp = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")
    private val deadlines = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }

    fun bonded(context: Context): List<BluetoothDevice> {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: throw IOException("Acest terminal nu are Bluetooth.")
        if (!adapter.isEnabled) throw IOException("Activează Bluetooth pe terminal.")
        return adapter.bondedDevices.filter { it.type != BluetoothDevice.DEVICE_TYPE_LE }
    }

    fun open(context: Context, id: String): FiscalStream {
        val device = bonded(context).singleOrNull { it.address == id }
            ?: throw IOException("Casa Bluetooth nu mai este asociată cu acest terminal.")
        val socket = device.createRfcommSocketToServiceRecord(spp)
        try {
            bounded(socket, 8000) { socket.connect() }
            val input = socket.inputStream
            val output = socket.outputStream
            return object : FiscalStream {
                override fun write(bytes: ByteArray, timeoutMs: Int) = bounded(socket, timeoutMs) {
                    output.write(bytes)
                    output.flush()
                }
                override fun read(timeoutMs: Int): ByteArray = bounded(socket, timeoutMs) {
                    val buffer = ByteArray(1024)
                    val count = input.read(buffer)
                    if (count <= 0) throw IOException("Casa Bluetooth s-a deconectat.")
                    buffer.copyOf(count)
                }
                override fun close() = socket.close()
            }
        } catch (e: Exception) {
            runCatching { socket.close() }
            throw e
        }
    }

    private fun <T> bounded(socket: BluetoothSocket, ms: Int, operation: () -> T): T {
        val deadline = deadlines.schedule({ runCatching { socket.close() } }, ms.toLong(), TimeUnit.MILLISECONDS)
        try { return operation() } finally { deadline.cancel(false) }
    }
}
