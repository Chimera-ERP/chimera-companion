package ro.chimeraerp.companion

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Adapts the SDK's reader thread to a single bounded serial exchange. A NAK,
 * missing response or wrong reply terminates this session before the SDK can resend. */
internal class DatecsSdkPort(private val link: FiscalStream, private val timeoutMs: Int) : Closeable {
    private val incoming = LinkedBlockingQueue<Int>(256)
    @Volatile private var closed = false
    private var lastSequence = -1
    val input = object : InputStream() {
        override fun read(): Int = try {
            if (closed) -1 else incoming.take()
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("Citirea Datecs a fost întreruptă.", e)
        }
        override fun close() = this@DatecsSdkPort.close()
    }
    val output = object : OutputStream() {
        override fun write(value: Int) { throw IOException("Cadru Datecs incomplet.") }
        override fun write(bytes: ByteArray, off: Int, len: Int) {
            if (closed || len !in 10..218 || bytes[off].toInt() != 1)
                throw IOException("Sesiune sau cadru Datecs invalid.")
            val sequence = bytes[off + 2].toInt() and 255
            if (sequence == lastSequence) throw IOException("Comanda Datecs nu poate fi retransmisă.")
            lastSequence = sequence
            try {
                val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.toLong())
                link.write(bytes.copyOfRange(off, off + len), timeoutMs)
                val reply = ByteArrayOutputStream()
                var size = -1
                while (size < 0 || reply.size() < size) {
                    val remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).toInt()
                    if (remaining <= 0) throw SocketTimeoutException("Răspuns Datecs expirat.")
                    for (raw in link.read(remaining)) {
                        val b = raw.toInt() and 255
                        if (reply.size() == 0 && b == 0x16) continue // Still processing.
                        if (reply.size() == 0 && b != 1) throw IOException("Comanda Datecs nu a fost confirmată.")
                        if (reply.size() == 1) {
                            size = b - 26 // SOH, LEN, SEQ, CMD, data, 04, 6 status, 05, BCC[4], ETX.
                            if (size !in 17..235) throw IOException("Lungime răspuns Datecs invalidă.")
                        }
                        if (size >= 0 && reply.size() >= size) throw IOException("Date Datecs nesolicitate.")
                        reply.write(b)
                    }
                }
                val response = reply.toByteArray()
                if (response[2] != bytes[off + 2] || response[3] != bytes[off + 3]) {
                    throw IOException("Răspunsul Datecs nu corespunde comenzii.")
                }
                // The official SDK checks status bits, separators, checksum and terminator.
                for (b in response) check(incoming.offer(b.toInt() and 255))
            } catch (e: Exception) {
                this@DatecsSdkPort.close()
                throw e
            }
        }
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        incoming.clear()
        incoming.offer(-1)
        // The owner releases the underlying USB/Bluetooth handle exactly once.
    }

    companion object {
        fun identity(serial: String?): String {
            val value = serial?.trim().orEmpty()
            require(Regex("^[A-Za-z0-9-]{4,32}$").matches(value) && value.any { it != '0' }) {
                "Seria casei Datecs nu a putut fi citită."
            }
            return MessageDigest.getInstance("SHA-256").digest("fiscal/datecsDp25/$value".toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 255) }
        }
    }
}
