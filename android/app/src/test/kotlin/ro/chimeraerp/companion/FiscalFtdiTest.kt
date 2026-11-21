package ro.chimeraerp.companion

import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FiscalFtdiTest {
    @Test fun usesSingleChannelDivisorsForFiscalBaudRates() {
        assertEquals(26, FiscalFtdi.baudDivisor(115200))
        assertEquals(0x4138, FiscalFtdi.baudDivisor(9600))
        assertEquals(0xc068, FiscalFtdi.baudDivisor(28800))
        assertThrows(IllegalArgumentException::class.java) { FiscalFtdi.baudDivisor(0) }
    }

    @Test fun preservesTheFrameAcrossPacketsAndStatusOnlyNotifications() {
        val data = ByteArray(75) { (it + 20).toByte() }
        val header = byteArrayOf(0x31, 0x60)
        val read = header + data.take(62).toByteArray() + header + data.drop(62).toByteArray()
        assertArrayEquals(data, FiscalFtdi.serialPayload(read, read.size, 64))
        assertArrayEquals(byteArrayOf(), FiscalFtdi.serialPayload(header, 2, 64))
    }

    @Test fun damagedLineOrShortHeaderDoesNotReachTheFiscalFrameParser() {
        val broken = byteArrayOf(0x31, 0x62, 0x06)
        assertThrows(IOException::class.java) { FiscalFtdi.serialPayload(broken, broken.size, 64) }
        assertThrows(IOException::class.java) { FiscalFtdi.serialPayload(ByteArray(65), 65, 64) }
    }
}
