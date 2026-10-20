package app.deskbar.workbench

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceNameTest {
    @Test fun modelNamesAvoidDuplicateManufacturers() {
        assertEquals("Xiaomi 24030PN60C", deviceName(" Xiaomi ", "24030PN60C"))
        assertEquals("samsung Galaxy Tab", deviceName("Samsung", "samsung Galaxy Tab"))
        assertEquals("Pixel 9", deviceName("unknown", "Pixel 9"))
    }

    @Test fun missingModelsFallBackAndNamesFitPairingLimit() {
        assertEquals("Android 工作台", deviceName("Xiaomi", "unknown"))
        assertEquals("Android 工作台", deviceName(null, " "))
        assertEquals(64, deviceName("Brand", "a".repeat(100)).length)
    }
}
