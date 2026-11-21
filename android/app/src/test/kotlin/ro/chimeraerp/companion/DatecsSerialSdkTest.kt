package ro.chimeraerp.companion

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

/** Real DP25ROU SDK and wire frames, through the same transport as checkout. */
class DatecsSerialSdkTest {
    private class Peer(val serial: String = "DTSER0001", val closeFault: String = "") : FiscalStream {
        val sent = mutableListOf<Int>()
        val chunks = ArrayDeque<ByteArray>()
        override fun close() {}
        override fun write(bytes: ByteArray, timeoutMs: Int) {
            val cmd = bytes[3].toInt() and 255
            sent.add(cmd)
            if (cmd == 56 && closeFault == "timeout") return
            if (cmd == 56 && closeFault == "NAK") { chunks.add(byteArrayOf(21)); return }
            val data = when (cmd) {
                90 -> "DP25,1,010124,12:00,1234,0000,$serial"
                74, 49 -> ""
                76 -> "0,0,0,0"
                83 -> "1,2,RON,1100,21.00,11.00,0.00,0.00,0.00,0.00,0.00"
                48 -> "100,101"
                51 -> "5.00,5.00,0,0,0,0,0,0"
                53 -> "R0.00" // SDK: one paidCode byte followed immediately by the amount.
                56 -> "100,101"
                69 -> "1,0,0,0,0,0,0,0,0"
                else -> throw AssertionError("Unexpected SDK command $cmd")
            }.toByteArray(Charsets.US_ASCII)
            val seq = if (cmd == 56 && closeFault == "wrong-sequence") (bytes[2]+1).toByte() else bytes[2]
            val content = byteArrayOf((43+data.size).toByte(), seq, bytes[3]) + data +
                byteArrayOf(4,0,0,0,0,0,0,5)
            val sum = content.sumOf { it.toInt() and 255 }
            val check = intArrayOf(12, 8, 4, 0).map { (48 + ((sum ushr it) and 15)).toByte() }.toByteArray()
            val reply = byteArrayOf(1) + content + check + byteArrayOf(3)
            chunks.add(byteArrayOf(22)) // SYN processing, fragmented reply.
            chunks.add(reply.copyOfRange(0,6))
            chunks.add(reply.copyOfRange(6,reply.size))
        }
        override fun read(timeoutMs: Int) = chunks.removeFirstOrNull() ?: throw IOException("Reply lost")
    }

    private fun args(transport: String = "usb") = mapOf(
        "transport" to transport, "id" to if (transport == "usb") DatecsSdkPort.identity("DTSER0001") else "AA:BB:CC:DD:EE:FF",
        "operatorNumber" to 1, "operatorPassword" to "1234", "tillNumber" to "1", "cashPaymentCode" to "P", "cardPaymentCode" to "D",
        "receipt" to mapOf("currency" to "RON","totalMinor" to 500, "paymentMethod" to "card","confirmedPaymentReference" to "test-bank",
            "lines" to listOf(mapOf("name" to "Cafea", "vatGroup" to "A", "quantity" to "1", "unitPriceMinor" to 500, "grossTotalMinor" to 500))),
    )
    @Test fun verifiesIdentityAndIssuesOneReceiptForEachTransport() {
        for (transport in listOf("usb","bluetooth")) {
            val peer = Peer()
            val result = DatecsRouBridge.executeSerial("receipt", args(transport), peer)
            assertEquals(result.toString(),"succeeded",result["outcome"])
            assertEquals("101",result["reference"])
            assertEquals(listOf(90,74,76,48,49,51,53,56),peer.sent)
            assertEquals(true,DatecsRouBridge.executeSerial("status",args(transport),Peer())["ready"])
            assertEquals("1100",DatecsRouBridge.executeSerial("readVatRates",args(transport),Peer())["enabled"])
            assertEquals("succeeded",DatecsRouBridge.executeSerial("xReport",args(transport),Peer())["outcome"])
        }
    }
    @Test fun replacedUsbDeviceStopsAfterReadingItsSerial() {
        val peer = Peer("OTHER123")
        assertEquals("rejected",DatecsRouBridge.executeSerial("receipt",args(),peer)["outcome"])
        assertEquals(listOf(90), peer.sent)
    }
    @Test fun missingDamagedOrNegativeCloseReplyNeverRetransmits() {
        for (fault in listOf("timeout","wrong-sequence","NAK")) {
            val peer = Peer(closeFault=fault)
            assertEquals(fault, "unknown",DatecsRouBridge.executeSerial("receipt",args(),peer)["outcome"])
            assertEquals(fault, 1, peer.sent.count { it==56 })
        }
    }
}
