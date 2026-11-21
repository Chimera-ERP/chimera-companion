package ro.chimeraerp.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Fp21UsbCommandsTest {
    private val barcode = "P;2;12;200000000001" + " ".repeat(88)
    private val qr = "C;4;https://chimeraerp.ro" + " ".repeat(179)
    private val operator = "7;DEMO;0;0"

    private fun wire(start: Int, body: List<Int>): ByteArray {
        val xor = body.fold(0) { x, b -> x xor b }
        return (listOf(start) + body + listOf(0x30 + (xor ushr 4), 0x30 + (xor and 15), 10))
            .map { it.toByte() }.toByteArray()
    }

    private fun request(sequence: Int, command: Int, data: String = "") =
        wire(2, listOf(0x23 + data.length, sequence, command) + data.map(Char::code))

    private fun status(sequence: Int, document: Int) =
        wire(2, listOf(0x2a, sequence, 0x20, 0, 0, document, 0, 0, 0, 0))

    private fun ack(sequence: Int, code: String = "00") =
        wire(6, listOf(sequence) + code.map { 0x30 + it.digitToInt(16) })

    private fun Fp21UsbCommands.readState(seq: Int, document: Int) {
        assertTrue(accept(request(seq, 0x20)))
        observe(status(seq, document))
    }

    @Test fun probeStaysReadOnlyEvenAfterStatusAndSequenceWrap() {
        val probe = Fp21UsbCommands(Fp21UsbPurpose.STATUS)
        assertTrue(probe.accept(byteArrayOf(9)))
        probe.readState(0x9f, 1)
        assertFalse(probe.accept(request(0x21, 0x20)))
        for ((command, data) in listOf(0x2e to operator, 0x37 to "DEMO", 0x2f to "", 0x51 to barcode, 0x51 to qr, 0x30 to "")) {
            assertFalse(probe.accept(request(0x20, command, data)))
        }
        assertFalse(probe.accept(request(0x20, 0x21)))
        probe.readState(0x20, 0)
        assertFalse(probe.accept(request(0x21, 0x2e, operator)))
        assertFalse(probe.accept(request(0x21, 0x21, "x")))
        assertTrue(probe.accept(request(0x21, 0x21)))
        assertFalse(probe.accept(request(0x22, 0x22))) // 22h prints diagnostics.
        for (purpose in Fp21UsbPurpose.values().filter { it != Fp21UsbPurpose.STATUS }) {
            val other = Fp21UsbCommands(purpose)
            other.readState(0x20, 0)
            assertFalse(other.accept(request(0x21, 0x21)))
        }
    }

    @Test fun openingMustBeAcknowledgedBeforeTextOrClose() {
        for (result in listOf("40", "00")) {
            val print = Fp21UsbCommands(Fp21UsbPurpose.NON_FISCAL_TEST)
            assertFalse(print.accept(request(0x20, 0x2e, operator)))
            print.readState(0x20, 0)
            assertTrue(print.accept(request(0x21, 0x2e, operator)))
            val reply = ack(0x21, result)
            print.observe(reply.copyOfRange(0, 4))
            assertFalse(print.accept(request(0x22, 0x37, "DEMO")))
            assertFalse(print.accept(request(0x22, 0x2f)))
            print.observe(reply.copyOfRange(4, reply.size))
            if (result == "00") {
                assertTrue(print.accept(request(0x22, 0x37, "DEMO")))
            } else {
                assertFalse(print.accept(request(0x22, 0x37, "DEMO")))
                assertFalse(print.accept(request(0x22, 0x2f)))
            }
        }
    }

    @Test fun vendorPaddedBarcodeFitsOnlyTheBarcodeCommand() {
        val print = Fp21UsbCommands(Fp21UsbPurpose.NON_FISCAL_TEST)
        print.readState(0x20, 0)
        assertTrue(print.accept(request(0x21, 0x2e, operator)))
        print.observe(ack(0x21))
        for (len in listOf(41, 100, 107)) {
            assertFalse(print.accept(request(0x22, 0x37, "A".repeat(len))))
        }
        assertTrue(print.accept(request(0x22, 0x37, "A".repeat(40))))
        for (bad in listOf(qr, barcode.trimEnd(), barcode.dropLast(1), barcode + " ", barcode.dropLast(1) + "0",
            "P;2;13;2000000000015".padEnd(107))) {
            assertFalse(print.accept(request(0x23, 0x51, bad)))
        }
        val frame = request(0x23, 0x51, barcode)
        assertEquals(114, frame.size)
        assertEquals(0x8e, frame[1].toInt() and 0xff)
        assertTrue(print.accept(frame))
    }

    @Test fun recoveryRequiresVerifiedStatusForAnOpenNonFiscalDocument() {
        for (state in listOf(0, 1, 2, 3)) {
            val finish = Fp21UsbCommands(Fp21UsbPurpose.FINISH_TEST)
            assertTrue(finish.accept(request(0x20, 0x20)))
            val reply = status(0x20, state)
            finish.observe(reply.copyOfRange(0, 6))
            assertFalse(finish.accept(request(0x21, 0x51, barcode)))
            finish.observe(reply.copyOfRange(6, reply.size))
            assertFalse(finish.accept(request(0x21, 0x2e, operator)))
            assertFalse(finish.accept(request(0x21, 0x37, "DEMO")))
            assertFalse(finish.accept(request(0x21, 0x2f)))
            assertFalse(finish.accept(request(0x21, 0x51, "P;2;13;2000000000015")))
            if (state == 1) assertTrue(finish.accept(request(0x21, 0x51, barcode)))
            else assertFalse(finish.accept(request(0x21, 0x51, barcode)))
        }
    }

    @Test fun corruptAndOutOfSequenceRepliesNeverAuthorizePaperCommands() {
        val good = status(0x20, 1)
        val corrupt = good.clone().apply { this[lastIndex - 1] = (this[lastIndex - 1].toInt() xor 1).toByte() }
        for (reply in listOf(status(0x21, 1), corrupt, good.copyOf(6), ack(0x20), good + byteArrayOf(0))) {
            val finish = Fp21UsbCommands(Fp21UsbPurpose.FINISH_TEST)
            assertTrue(finish.accept(request(0x20, 0x20)))
            finish.observe(reply)
            assertFalse(finish.accept(request(0x21, 0x51, barcode)))
        }
    }

    @Test fun closeOnlyRequiresLatestNonFiscalStatusAndNeverPermitsPrinting() {
        val close = Fp21UsbCommands(Fp21UsbPurpose.CLOSE_TEST)
        assertTrue(close.accept(byteArrayOf(9)))
        assertFalse(close.accept(request(0x20, 0x2f)))
        close.readState(0x20, 1)
        assertTrue(close.accept(request(0x21, 0x20)))
        val changed = status(0x21, 2)
        close.observe(changed.copyOfRange(0, 9))
        assertFalse(close.accept(request(0x22, 0x2f)))
        close.observe(changed.copyOfRange(9, changed.size))
        assertFalse(close.accept(request(0x22, 0x2f)))
        close.readState(0x22, 3)
        assertFalse(close.accept(request(0x23, 0x2f)))
        close.readState(0x23, 0)
        assertFalse(close.accept(request(0x24, 0x2f)))
        close.readState(0x24, 1)
        val forbidden = listOf(0x2e to operator, 0x37 to "DEMO", 0x51 to barcode, 0x51 to qr,
            0x30 to "", 0x38 to "", 0x2f to "0")
        for ((cmd, data) in forbidden) assertFalse(close.accept(request(0x25, cmd, data)))
        assertTrue(close.accept(request(0x25, 0x2f)))
    }

    @Test fun closeOnlyNeverResendsWhenAcknowledgementIsLostRefusedOrConfirmed() {
        for (code in listOf(null, "04", "00")) {
            val close = Fp21UsbCommands(Fp21UsbPurpose.CLOSE_TEST)
            close.readState(0x20, 1)
            assertTrue(close.accept(request(0x21, 0x2f)))
            assertFalse(close.accept(request(0x22, 0x2f)))
            if (code != null) {
                close.observe(ack(0x21, code))
                close.readState(0x22, 1)
                assertFalse(close.accept(request(0x23, 0x2f)))
                assertFalse(close.accept(request(0x23, 0x51, barcode)))
            }
        }
    }

    @Test fun cutOnlyRequiresAFreshVerifiedStatusWithoutAnOpenFiscalReceipt() {
        for (state in 0..3) {
            val cutter = Fp21UsbCommands(Fp21UsbPurpose.CUT_PAPER)
            assertTrue(cutter.accept(byteArrayOf(9)))
            assertFalse(cutter.accept(request(0x20, 0x29)))
            cutter.readState(0x20, 0)
            assertTrue(cutter.accept(request(0x21, 0x20)))
            val latest = status(0x21, state)
            cutter.observe(latest.copyOfRange(0, 11))
            assertFalse(cutter.accept(request(0x22, 0x29)))
            cutter.observe(latest.copyOfRange(11, latest.size))
            for ((cmd, data) in listOf(0x29 to "1", 0x2e to operator, 0x37 to "DEMO",
                0x51 to barcode, 0x51 to qr, 0x2f to "", 0x30 to "", 0x38 to "")) {
                assertFalse(cutter.accept(request(0x22, cmd, data)))
            }
            assertEquals(state <= 1, cutter.accept(request(0x22, 0x29)))
        }
    }

    @Test fun cutOnlyConsumesOneAttemptAndOtherHandlesCannotCut() {
        for (code in listOf(null, "00", "04")) {
            val cutter = Fp21UsbCommands(Fp21UsbPurpose.CUT_PAPER)
            cutter.readState(0x20, 1)
            assertTrue(cutter.accept(request(0x21, 0x29)))
            assertFalse(cutter.accept(request(0x22, 0x29)))
            if (code != null) {
                cutter.observe(ack(0x21, code))
                cutter.readState(0x22, 0)
                assertFalse(cutter.accept(request(0x23, 0x29)))
            }
        }
        for (purpose in listOf(Fp21UsbPurpose.STATUS, Fp21UsbPurpose.NON_FISCAL_TEST,
            Fp21UsbPurpose.FINISH_TEST, Fp21UsbPurpose.CLOSE_TEST)) {
            val other = Fp21UsbCommands(purpose)
            other.readState(0x20, 1)
            assertFalse(other.accept(request(0x21, 0x29)))
        }
    }

    @Test fun onlyTheExactQrCanFollowAConfirmedBarcodeResponseAndNeverTwice() {
        for (code in listOf("00", "02", "64", "A4", "10", "40", "A0", "60")) {
            val print = Fp21UsbCommands(Fp21UsbPurpose.NON_FISCAL_TEST)
            print.readState(0x20, 0)
            assertTrue(print.accept(request(0x21, 0x2e, operator)))
            print.observe(ack(0x21))
            assertFalse(print.accept(request(0x22, 0x51, qr)))
            assertTrue(print.accept(request(0x22, 0x51, barcode)))
            val response = ack(0x22, code)
            print.observe(response.copyOfRange(0, 4))
            assertFalse(print.accept(request(0x23, 0x51, qr)))
            print.observe(response.copyOfRange(4, response.size))
            assertFalse(print.accept(request(0x23, 0x51, barcode)))
            for (badQr in listOf("C;4;https://example.org", "C;5;https://chimeraerp.ro", qr + ";")) {
                assertFalse(print.accept(request(0x23, 0x51, badQr)))
            }
            val allowed = code in listOf("00", "02", "64", "A4")
            assertEquals(allowed, print.accept(request(0x23, 0x51, qr)))
            if (allowed) {
                assertFalse(print.accept(request(0x24, 0x51, qr)))
                print.observe(ack(0x23))
                assertFalse(print.accept(request(0x24, 0x51, qr)))
                assertTrue(print.accept(request(0x24, 0x2f)))
            }
        }
    }

    @Test fun standaloneQrRequiresFreshClosedDocumentAndPermitsOnlyTheCapturedFrameOnce() {
        val probe = Fp21UsbCommands(Fp21UsbPurpose.QR_TEST)
        val first = request(0x20, 0x51, qr)
        assertEquals(211, first.size)
        assertEquals(0xef, first[1].toInt() and 0xff)
        assertFalse(probe.accept(first))
        for (state in 1..3) {
            val seq = 0x1f + state
            probe.readState(seq, state)
            assertFalse(probe.accept(request(seq + 1, 0x51, qr)))
        }
        assertTrue(probe.accept(request(0x23, 0x20)))
        val closed = status(0x23, 0)
        probe.observe(closed.copyOfRange(0, 7))
        assertFalse(probe.accept(request(0x24, 0x51, qr)))
        probe.observe(closed.copyOfRange(7, closed.size))
        for ((cmd, data) in listOf(0x2e to operator, 0x37 to "DEMO", 0x2f to "", 0x29 to "",
            0x4d to qr, 0x6c to "9", 0x51 to barcode, 0x51 to qr.trimEnd(),
            0x51 to qr.dropLast(1), 0x51 to qr.replace("chimeraerp", "chimeraBAD"))) {
            assertFalse(probe.accept(request(0x24, cmd, data)))
        }
        assertFalse(probe.standaloneQrAwaitingReply)
        assertTrue(probe.accept(request(0x24, 0x51, qr)))
        assertTrue(probe.standaloneQrAwaitingReply)
        assertFalse(probe.accept(request(0x25, 0x51, qr)))
        val reply = ack(0x24)
        probe.observe(reply.copyOfRange(0, 2))
        assertTrue(probe.standaloneQrAwaitingReply)
        probe.observe(reply.copyOfRange(2, reply.size))
        assertFalse(probe.standaloneQrAwaitingReply)
        probe.readState(0x25, 0)
        assertFalse(probe.accept(request(0x26, 0x51, qr)))
    }

    @Test fun standaloneQrNeverRunsAfterStatusRefusalOrCorruption() {
        val good = status(0x21, 0)
        val corrupt = good.clone().apply { this[lastIndex - 1] = (this[lastIndex - 1].toInt() xor 1).toByte() }
        for (reply in listOf(status(0x22, 0), ack(0x21, "04"), corrupt)) {
            val probe = Fp21UsbCommands(Fp21UsbPurpose.QR_TEST)
            probe.readState(0x20, 0)
            assertTrue(probe.accept(request(0x21, 0x20)))
            probe.observe(reply)
            assertFalse(probe.accept(request(0x22, 0x51, qr)))
            assertFalse(probe.standaloneQrAwaitingReply)
        }
    }

    @Test fun shortNativeRefusalsDoNotReplaySymbolsOrPreventClosingTheOpenedSample() {
        for (control in listOf(0x15.toByte(), 0x0e.toByte())) {
            val probe = Fp21UsbCommands(Fp21UsbPurpose.QR_TEST)
            probe.readState(0x20, 0)
            assertTrue(probe.accept(request(0x21, 0x51, qr)))
            probe.observe(byteArrayOf(control))
            assertFalse(probe.standaloneQrAwaitingReply)
            assertFalse(probe.accept(request(0x22, 0x51, qr)))
            assertTrue(probe.accept(request(0x22, 0x20)))

            val sample = Fp21UsbCommands(Fp21UsbPurpose.NON_FISCAL_TEST)
            sample.readState(0x20, 0)
            assertTrue(sample.accept(request(0x21, 0x2e, operator)))
            sample.observe(ack(0x21))
            assertTrue(sample.accept(request(0x22, 0x51, barcode)))
            sample.observe(byteArrayOf(control))
            assertFalse(sample.accept(request(0x23, 0x51, barcode)))
            assertTrue(sample.accept(request(0x23, 0x51, qr)))
            assertFalse(sample.standaloneQrAwaitingReply)
            sample.observe(byteArrayOf(control))
            assertFalse(sample.accept(request(0x24, 0x51, qr)))
            assertTrue(sample.accept(request(0x24, 0x2f)))
        }
    }

    @Test fun aTimedOutQrInAnOwnedReceiptCanOnlyReadStateAndCloseTheSameDocumentOnce() {
        for (purpose in listOf(Fp21UsbPurpose.NON_FISCAL_TEST, Fp21UsbPurpose.FINISH_TEST)) {
            val print = Fp21UsbCommands(purpose)
            if (purpose == Fp21UsbPurpose.FINISH_TEST) {
                print.readState(0x21, 1)
            } else {
                print.readState(0x20, 0)
                assertTrue(print.accept(request(0x21, 0x2e, operator)))
                print.observe(ack(0x21))
            }
            assertTrue(print.accept(request(0x22, 0x51, barcode)))
            assertFalse(print.restrictToCloseAfterQrReadTimeout())
            print.observe(ack(0x22))
            assertTrue(print.accept(request(0x23, 0x51, qr)))
            print.observe(ack(0x23).copyOf(3))
            assertTrue(print.restrictToCloseAfterQrReadTimeout())
            assertFalse(print.restrictToCloseAfterQrReadTimeout())
            assertFalse(print.accept(request(0x24, 0x2f)))
            print.observe(ack(0x23)) // Late reply cannot establish the receipt state.
            assertTrue(print.accept(byteArrayOf(9)))
            for ((i, state) in listOf(0, 2, 3, 1).withIndex()) {
                val seq = 0x24 + i
                assertTrue(print.accept(request(seq, 0x20)))
                val reply = status(seq, state)
                print.observe(reply.copyOf(8))
                assertFalse(print.accept(request(seq + 1, 0x2f)))
                print.observe(reply.copyOfRange(8, reply.size))
                for ((cmd, data) in listOf(0x37 to "DEMO", 0x2e to operator, 0x51 to qr,
                    0x51 to barcode, 0x29 to "", 0x30 to "", 0x2f to "1")) {
                    assertFalse(print.accept(request(seq + 1, cmd, data)))
                }
                assertEquals(state == 1, print.accept(request(seq + 1, 0x2f)))
            }
            print.observe(ack(0x28, "02"))
            print.readState(0x29, 1)
            assertFalse(print.accept(request(0x2a, 0x2f)))
            assertFalse(print.accept(request(0x2a, 0x51, qr)))
        }
    }

    @Test fun standaloneQrAndOtherTimeoutsCannotKeepTheHandleForAReceiptClose() {
        for (purpose in Fp21UsbPurpose.values()) {
            val commands = Fp21UsbCommands(purpose)
            assertFalse(commands.restrictToCloseAfterQrReadTimeout())
            commands.readState(0x20, 0)
            if (purpose == Fp21UsbPurpose.QR_TEST) {
                assertTrue(commands.accept(request(0x21, 0x51, qr)))
                commands.observe(ack(0x21).copyOf(2))
                assertFalse(commands.restrictToCloseAfterQrReadTimeout())
                assertFalse(commands.accept(request(0x22, 0x2f)))
            }
        }
    }

    @Test fun closedDocumentNeverAllowsAnotherBarcodeEvenAfterExplicitRefusal() {
        for (purpose in listOf(Fp21UsbPurpose.NON_FISCAL_TEST, Fp21UsbPurpose.FINISH_TEST)) {
            for (replyCode in listOf("00", "04", "A4", "A0", "60")) {
                val print = Fp21UsbCommands(purpose)
                var seq = 0x20
                if (purpose == Fp21UsbPurpose.NON_FISCAL_TEST) {
                    print.readState(seq++, 0)
                    assertTrue(print.accept(request(seq, 0x2e, operator)))
                    print.observe(ack(seq++))
                } else {
                    print.readState(seq++, 1)
                }
                assertTrue(print.accept(request(seq, 0x51, barcode)))
                val reply = ack(seq++, replyCode)
                print.observe(reply.copyOfRange(0, 3))
                assertFalse(print.accept(request(seq, 0x2f)))
                print.observe(reply.copyOfRange(3, reply.size))
                assertFalse(print.accept(request(seq, 0x51, barcode)))
                assertTrue(print.accept(request(seq++, 0x37, "Fidelity")))
                assertTrue(print.accept(request(seq, 0x2f)))
                val close = ack(seq++)
                print.observe(close.copyOfRange(0, 4))
                assertFalse(print.accept(request(seq, 0x51, barcode)))
                print.observe(close.copyOfRange(4, close.size))
                print.readState(seq++, 0)
                assertFalse(print.accept(request(seq, 0x51, qr)))
                assertFalse(print.accept(request(seq, 0x51, barcode)))
                assertFalse(print.accept(request(seq, 0x37, "EXTRA")))
                assertFalse(print.accept(request(seq, 0x2e, operator)))
                assertFalse(print.accept(request(seq, 0x2f)))
            }
        }
    }

}
